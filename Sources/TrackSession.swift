import Foundation

struct TrackSession {
    let track: RecognizedTrack
    let startMonotonic: ContinuousClock.Instant
    let startTimestamp: Int
    private(set) var scrobbled: Bool = false

    init(track: RecognizedTrack) {
        self.track = track
        self.startMonotonic = ContinuousClock.now
        self.startTimestamp = Int(Date().timeIntervalSince1970)
    }

    var eligibilityInterval: TimeInterval {
        guard let duration = track.duration, duration > 30 else {
            if track.duration != nil { return .infinity }
            return 30
        }
        return min(duration / 2, 240)
    }

    func elapsed() -> TimeInterval {
        let dur = startMonotonic.duration(to: .now)
        return Double(dur.components.seconds) + Double(dur.components.attoseconds) / 1e18
    }

    func isEligible() -> Bool {
        eligibilityInterval != .infinity && elapsed() >= eligibilityInterval
    }

    mutating func markScrobbled() {
        scrobbled = true
    }

    func matchesTrack(_ other: RecognizedTrack) -> Bool {
        track.artist.lowercased() == other.artist.lowercased() &&
        track.title.lowercased() == other.title.lowercased()
    }
}
