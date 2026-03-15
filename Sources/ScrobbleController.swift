import Foundation

@MainActor
final class ScrobbleController {
    nonisolated(unsafe) let lastFm: LastFmClient
    let capture: AudioCapture
    let analyzer: AudioAnalyzer
    nonisolated(unsafe) let recognizer: MusicRecognizer
    let queue: ScrobbleQueue
    let controlServer: ControlRequestServer

    private var activeSession: TrackSession?
    private var lastKnownSong: ManualScrobbleRequest?
    private var scrobblingEnabled: Bool
    private var recognitionInFlight = false
    private var lastRecognitionTime: ContinuousClock.Instant = .now - .seconds(60)
    private let cooldownInterval: Duration = .seconds(10)
    private let acceleratedPeriodicDelaySeconds: TimeInterval = 25

    private var periodicTimer: DispatchSourceTimer?
    private var acceleratedPeriodicTimer: DispatchSourceTimer?
    private var eligibilityTimer: DispatchSourceTimer?
    private var shutdownTask: Task<Void, Never>?
    private var startupTask: Task<Void, Never>?

    init(session: Session) {
        lastFm = LastFmClient()
        capture = AudioCapture()
        let timeoutSeconds = autoExitMinutes.map { $0 * 60 }
        analyzer = AudioAnalyzer(silenceTimeoutSeconds: timeoutSeconds)
        recognizer = MusicRecognizer()
        queue = ScrobbleQueue()
        controlServer = ControlRequestServer()
        scrobblingEnabled = !noScrobble

        lastFm.sessionKey = session.sessionKey

        nonisolated(unsafe) let analyzerRef = analyzer
        nonisolated(unsafe) let recognizerRef = recognizer
        capture.onAudioBuffer = { buffer, _ in
            analyzerRef.process(buffer)
            recognizerRef.addBuffer(buffer)
        }

        analyzer.onTransitionDetected = { @Sendable [weak self] in
            Task { @MainActor [weak self] in
                self?.requestRecognition(reason: .transition)
            }
        }

        analyzer.onSuspicionDetected = { @Sendable [weak self] in
            Task { @MainActor [weak self] in
                self?.scheduleAcceleratedPeriodicRecognition(trigger: "suspicion")
                self?.requestRecognition(reason: .suspicion)
            }
        }

        if autoExitMinutes != nil {
            analyzer.onSilenceTimeout = { @Sendable [weak self] in
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    print("\u{23F8} silence detected, exiting...")
                    await self.shutdown()
                    exit(0)
                }
            }
        }
    }

    func start() async throws {
        try controlServer.start { [weak self] request in
            guard let self else { return ControlResponse(success: false, message: "Controller unavailable") }
            return await self.handleControlRequest(request)
        }
        await flushQueue()
        try await capture.start()
        startPeriodicTimer()
        scheduleStartupRecognition()
        print("Listening for music\(scrobblingEnabled ? "" : " (not scrobbling)")...")
    }

    func requestRecognition(reason: RecognitionReason) {
        guard !recognitionInFlight else {
            logDebug("controller: skipping recognition (\(reason.rawValue)) — already in flight")
            return
        }

        let elapsed = lastRecognitionTime.duration(to: .now)
        guard elapsed >= cooldownInterval else {
            logDebug("controller: skipping recognition (\(reason.rawValue)) — cooldown (\(elapsed) < \(cooldownInterval))")
            return
        }

        recognitionInFlight = true
        lastRecognitionTime = .now
        logDebug("controller: starting recognition (\(reason.rawValue))")

        Task { [weak self] in
            guard let self else { return }

            let track = await self.recognizer.recognize(reason: reason)

            self.recognitionInFlight = false

            guard let track else {
                logNoMatch()
                if reason == .transition {
                    self.scheduleAcceleratedPeriodicRecognition(trigger: "transition-no-match")
                }
                return
            }

            await self.handleRecognizedTrack(track, reason: reason)
        }
    }

    private func handleRecognizedTrack(_ track: RecognizedTrack, reason: RecognitionReason) async {
        resetNoMatchStreak()

        if let current = self.activeSession, current.matchesTrack(track) {
            logDebug("controller: same track still playing — \(track.artist) - \(track.title) (\(reason.rawValue))")
            if reason == .transition || reason == .suspicion {
                self.scheduleAcceleratedPeriodicRecognition(trigger: "\(reason.rawValue)-same-track")
            }
            return
        }

        self.cancelAcceleratedPeriodicTimer()

        if let current = self.activeSession {
            if current.isEligible() {
                await self.scrobbleCurrentTrack()
            }
            self.cancelEligibilityTimer()
        }

        self.activeSession = TrackSession(track: track)

        if scrobblingEnabled {
            self.sendNowPlaying(track)
            self.scheduleEligibilityTimer()
        } else {
            rememberLastKnownSong(artist: track.artist, song: track.title)
            print("[\(timestamp())] \u{25CB} \(track.artist) - \(track.title)")
        }
    }

    private func handleControlRequest(_ request: ControlRequest) async -> ControlResponse {
        switch request {
        case let .manualScrobble(request):
            return await handleManualScrobbleRequest(request)
        case .love:
            return await loveLastSong()
        case .toggleScrobbling:
            return toggleScrobbling()
        }
    }

    private func toggleScrobbling() -> ControlResponse {
        scrobblingEnabled.toggle()
        let now = timestamp()
        if scrobblingEnabled {
            print("[\(now)] ~ Scrobbling resumed")
        } else {
            print("[\(now)] ~ Scrobbling paused")
        }
        return ControlResponse(
            success: true,
            message: "Scrobbling: \(scrobblingEnabled ? "on" : "off")"
        )
    }

    private func handleManualScrobbleRequest(_ request: ManualScrobbleRequest) async -> ControlResponse {
        let trimmedArtist = request.artist.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedSong = request.song.trimmingCharacters(in: .whitespacesAndNewlines)

        guard !trimmedArtist.isEmpty, !trimmedSong.isEmpty else {
            return ControlResponse(success: false, message: "Artist and song cannot be empty")
        }

        let now = timestamp()
        let scrobble = QueuedScrobble(
            artist: trimmedArtist,
            track: trimmedSong,
            album: nil,
            duration: nil,
            timestamp: Int(Date().timeIntervalSince1970)
        )

        do {
            try await lastFm.scrobble(
                artist: scrobble.artist,
                track: scrobble.track,
                album: scrobble.album,
                duration: scrobble.duration,
                timestamp: scrobble.timestamp
            )
            rememberLastKnownSong(artist: scrobble.artist, song: scrobble.track)
            print("[\(now)] \u{266B} \(scrobble.artist) - \(scrobble.track)")
            return ControlResponse(success: true, message: "Scrobbled: \(scrobble.artist) - \(scrobble.track)")
        } catch {
            queue.enqueue(scrobble)
            logError("Manual scrobble failed, queued for retry: \(error)")
            await handleAuthError(error)
            return ControlResponse(success: false, message: "Scrobble failed, queued for retry")
        }
    }

    private func loveLastSong() async -> ControlResponse {
        guard let lastKnownSong else {
            return ControlResponse(success: false, message: "No song to love yet")
        }

        let now = timestamp()

        do {
            try await lastFm.loveTrack(artist: lastKnownSong.artist, track: lastKnownSong.song)
            print("[\(now)] \u{2665} \(lastKnownSong.artist) - \(lastKnownSong.song)")
            return ControlResponse(success: true, message: "Loved: \(lastKnownSong.artist) - \(lastKnownSong.song)")
        } catch {
            logError("Love failed: \(error)")
            await handleAuthError(error)
            return ControlResponse(success: false, message: "Love failed: \(error.localizedDescription)")
        }
    }

    func scrobbleCurrentTrack() async {
        guard scrobblingEnabled,
              var session = activeSession,
              !session.scrobbled,
              session.isEligible() else {
            return
        }

        session.markScrobbled()
        activeSession = session

        let now = timestamp()
        let scrobbleTimestamp = min(session.startTimestamp, Int(Date().timeIntervalSince1970))
        let scrobble = QueuedScrobble(
            artist: session.track.artist,
            track: session.track.title,
            album: session.track.album,
            duration: session.track.duration.map { Int($0) },
            timestamp: scrobbleTimestamp
        )

        do {
            try await lastFm.scrobble(
                artist: scrobble.artist,
                track: scrobble.track,
                album: scrobble.album,
                duration: scrobble.duration,
                timestamp: scrobble.timestamp
            )
            rememberLastKnownSong(artist: scrobble.artist, song: scrobble.track)
            print("[\(now)] \u{266B} \(scrobble.artist) - \(scrobble.track)")
        } catch {
            queue.enqueue(scrobble)
            logError("Scrobble failed, queued for retry: \(error)")
            await handleAuthError(error)
        }
    }

    func shutdown() async {
        if let existing = shutdownTask {
            await existing.value
            return
        }

        let task = Task { @MainActor in
            startupTask?.cancel()
            cancelPeriodicTimer()
            cancelAcceleratedPeriodicTimer()
            cancelEligibilityTimer()
            await scrobbleCurrentTrack()
            capture.stop()
            lastKnownSong = nil
            controlServer.stop()
            clearLock()
        }
        shutdownTask = task
        await task.value
    }

    private func sendNowPlaying(_ track: RecognizedTrack) {
        Task { [weak self] in
            guard let self else { return }
            do {
                try await self.lastFm.updateNowPlaying(
                    artist: track.artist,
                    track: track.title,
                    album: track.album,
                    duration: track.duration.map { Int($0) }
                )
            } catch {
                await self.handleAuthError(error)
                logError("Now playing update failed: \(error)")
            }
        }
    }

    private func flushQueue() async {
        let entries = queue.flush()
        guard !entries.isEmpty else { return }

        print("Flushing \(entries.count) queued scrobble(s)...")

        for (index, entry) in entries.enumerated() {
            do {
                try await lastFm.scrobble(
                    artist: entry.artist,
                    track: entry.track,
                    album: entry.album,
                    duration: entry.duration,
                    timestamp: entry.timestamp
                )
                rememberLastKnownSong(artist: entry.artist, song: entry.track)
            } catch {
                await handleAuthError(error)
                queue.abortFlush(Array(entries[index...]))
                logError("Failed to flush queued scrobble: \(error)")
                return
            }
        }

        queue.completeFlush()
    }

    private func rememberLastKnownSong(artist: String, song: String) {
        lastKnownSong = ManualScrobbleRequest(artist: artist, song: song)
    }

    // MARK: - Startup

    private func scheduleStartupRecognition() {
        startupTask = Task {
            try? await Task.sleep(for: .seconds(10))
            guard !Task.isCancelled else { return }
            requestRecognition(reason: .startup)

            try? await Task.sleep(for: .seconds(10))
            guard !Task.isCancelled else { return }
            if activeSession == nil {
                requestRecognition(reason: .startupRetry)
            }
        }
    }

    // MARK: - Timers

    private func startPeriodicTimer() {
        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now() + 50, repeating: 50)
        timer.setEventHandler { [weak self] in
            Task { @MainActor [weak self] in
                logDebug("controller: periodic timer fired")
                self?.requestRecognition(reason: .periodic)
            }
        }
        timer.resume()
        periodicTimer = timer
    }

    private func scheduleAcceleratedPeriodicRecognition(
        trigger: String,
        delaySeconds: TimeInterval? = nil,
        canRetryOnCooldown: Bool = true
    ) {
        guard acceleratedPeriodicTimer == nil else {
            logDebug("controller: accelerated periodic already scheduled (\(trigger))")
            return
        }

        let delay = max(0.1, delaySeconds ?? acceleratedPeriodicDelaySeconds)
        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now() + delay)
        timer.setEventHandler { [weak self] in
            Task { @MainActor [weak self] in
                guard let self else { return }

                let elapsed = self.lastRecognitionTime.duration(to: .now)
                if elapsed < self.cooldownInterval {
                    self.cancelAcceleratedPeriodicTimer()

                    guard canRetryOnCooldown else {
                        logDebug("controller: accelerated periodic dropped after cooldown retry (\(elapsed) < \(self.cooldownInterval))")
                        return
                    }

                    let remaining = self.cooldownInterval - elapsed
                    let retryDelay = max(0.5, self.durationSeconds(remaining) + 0.5)
                    logDebug("controller: accelerated periodic deferred by cooldown (\(elapsed) < \(self.cooldownInterval)); retry in \(String(format: "%.1f", retryDelay))s")
                    self.scheduleAcceleratedPeriodicRecognition(
                        trigger: "cooldown-reschedule",
                        delaySeconds: retryDelay,
                        canRetryOnCooldown: false
                    )
                    return
                }

                self.cancelAcceleratedPeriodicTimer()
                logDebug("controller: accelerated periodic timer fired")
                self.requestRecognition(reason: .acceleratedPeriodic)
            }
        }
        timer.resume()
        acceleratedPeriodicTimer = timer
        logDebug("controller: scheduled accelerated periodic in \(String(format: "%.1f", delay))s (\(trigger))")
    }

    private func scheduleEligibilityTimer() {
        cancelEligibilityTimer()

        guard let session = activeSession else { return }
        let interval = session.eligibilityInterval
        guard interval != .infinity else { return }

        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now() + interval)
        timer.setEventHandler { [weak self] in
            Task { @MainActor [weak self] in
                await self?.scrobbleCurrentTrack()
            }
        }
        timer.resume()
        eligibilityTimer = timer
    }

    private func cancelPeriodicTimer() {
        periodicTimer?.cancel()
        periodicTimer = nil
    }

    private func cancelAcceleratedPeriodicTimer() {
        acceleratedPeriodicTimer?.cancel()
        acceleratedPeriodicTimer = nil
    }

    private func durationSeconds(_ duration: Duration) -> TimeInterval {
        Double(duration.components.seconds) + Double(duration.components.attoseconds) / 1e18
    }

    private func cancelEligibilityTimer() {
        eligibilityTimer?.cancel()
        eligibilityTimer = nil
    }

    private func handleAuthError(_ error: Error) async {
        guard let lfmError = error as? LastFmError, lfmError.code == 9 else { return }
        print("Last.fm session expired. Run 'overheard login' to re-authenticate.")
        await shutdown()
        exit(1)
    }
}
