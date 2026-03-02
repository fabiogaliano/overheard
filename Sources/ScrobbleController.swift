import Foundation

@MainActor
final class ScrobbleController {

    nonisolated(unsafe) let lastFm: LastFmClient
    let capture: AudioCapture
    let analyzer: AudioAnalyzer
    nonisolated(unsafe) let recognizer: MusicRecognizer
    let queue: ScrobbleQueue

    private var activeSession: TrackSession?
    private var recognitionInFlight = false
    private var lastRecognitionTime: ContinuousClock.Instant = .now - .seconds(60)
    private let cooldownInterval: Duration = .seconds(10)

    private var periodicTimer: DispatchSourceTimer?
    private var eligibilityTimer: DispatchSourceTimer?
    private var shutdownTask: Task<Void, Never>?

    init(session: Session) {
        lastFm = LastFmClient()
        capture = AudioCapture()
        analyzer = AudioAnalyzer()
        recognizer = MusicRecognizer()
        queue = ScrobbleQueue()

        lastFm.sessionKey = session.sessionKey

        nonisolated(unsafe) let analyzerRef = analyzer
        nonisolated(unsafe) let recognizerRef = recognizer
        capture.onAudioBuffer = { buffer, _ in
            analyzerRef.process(buffer)
            recognizerRef.addBuffer(buffer)
        }

        analyzer.onTransitionDetected = { @Sendable [weak self] in
            Task { @MainActor [weak self] in
                self?.requestRecognition(reason: "transition")
            }
        }

        analyzer.onSilenceTimeout = { @Sendable [weak self] in
            Task { @MainActor [weak self] in
                guard let self else { return }
                print("\u{23F8} silence detected, exiting...")
                await self.shutdown()
                exit(0)
            }
        }
    }

    func start() async throws {
        await flushQueue()
        try await capture.start()
        startPeriodicTimer()
        print("Listening for music...")
    }

    func requestRecognition(reason: String) {
        guard !recognitionInFlight else {
            logDebug("controller: skipping recognition (\(reason)) — already in flight")
            return
        }

        let elapsed = lastRecognitionTime.duration(to: .now)
        guard elapsed >= cooldownInterval else {
            logDebug("controller: skipping recognition (\(reason)) — cooldown (\(elapsed) < \(cooldownInterval))")
            return
        }

        recognitionInFlight = true
        lastRecognitionTime = .now
        logDebug("controller: starting recognition (\(reason))")

        Task { [weak self] in
            guard let self else { return }

            let track = await self.recognizer.recognize()

            self.recognitionInFlight = false

            guard let track else {
                logDebug("controller: recognition returned no match")
                return
            }

            if let current = self.activeSession, current.matchesTrack(track) {
                logDebug("controller: same track still playing — \(track.artist) - \(track.title)")
                return
            }

            if let current = self.activeSession {
                if current.isEligible() {
                    await self.scrobbleCurrentTrack()
                }
                self.cancelEligibilityTimer()
            }

            self.activeSession = TrackSession(track: track)
            print("\u{266B} \(track.artist) - \(track.title)")
            self.sendNowPlaying(track)
            self.scheduleEligibilityTimer()
        }
    }

    func scrobbleCurrentTrack() async {
        guard var session = activeSession,
              !session.scrobbled,
              session.isEligible() else {
            return
        }

        session.markScrobbled()
        activeSession = session

        let timestamp = min(session.startTimestamp, Int(Date().timeIntervalSince1970))
        let scrobble = QueuedScrobble(
            artist: session.track.artist,
            track: session.track.title,
            album: session.track.album,
            duration: session.track.duration.map { Int($0) },
            timestamp: timestamp
        )

        do {
            try await lastFm.scrobble(
                artist: scrobble.artist,
                track: scrobble.track,
                album: scrobble.album,
                duration: scrobble.duration,
                timestamp: scrobble.timestamp
            )
            print("\u{2713} scrobbled")
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
            cancelPeriodicTimer()
            cancelEligibilityTimer()
            await scrobbleCurrentTrack()
            capture.stop()
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
            } catch {
                await handleAuthError(error)
                queue.abortFlush(Array(entries[index...]))
                logError("Failed to flush queued scrobble: \(error)")
                return
            }
        }

        queue.completeFlush()
    }

    // MARK: - Timers

    private func startPeriodicTimer() {
        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now() + 50, repeating: 50)
        timer.setEventHandler { [weak self] in
            Task { @MainActor [weak self] in
                logDebug("controller: periodic timer fired")
                self?.requestRecognition(reason: "periodic")
            }
        }
        timer.resume()
        periodicTimer = timer
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

    private func cancelEligibilityTimer() {
        eligibilityTimer?.cancel()
        eligibilityTimer = nil
    }

    private func handleAuthError(_ error: Error) async {
        guard let lfmError = error as? LastFmError, lfmError.code == 9 else { return }
        print("Last.fm session expired. Run 'radio-scrobbler login' to re-authenticate.")
        await shutdown()
        exit(1)
    }
}
