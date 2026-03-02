import Foundation

struct QueuedScrobble: Codable, Sendable {
    let artist: String
    let track: String
    let album: String?
    let duration: Int?
    let timestamp: Int
}

final class ScrobbleQueue {

    private let filePath: URL
    private var processingPath: URL { filePath.appendingPathExtension("processing") }
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()
    private static let maxEntries = 5000

    init(filePath: URL = queueFile) {
        self.filePath = filePath
    }

    func enqueue(_ scrobble: QueuedScrobble) {
        ensureConfigDir()

        guard let data = try? encoder.encode(scrobble) else {
            logError("Failed to encode scrobble for queue")
            return
        }

        guard var line = String(data: data, encoding: .utf8) else { return }
        line += "\n"

        let fm = FileManager.default
        if fm.fileExists(atPath: filePath.path) {
            guard let handle = try? FileHandle(forWritingTo: filePath) else {
                logError("Failed to open queue file for writing")
                return
            }
            defer { try? handle.close() }
            handle.seekToEndOfFile()
            handle.write(Data(line.utf8))
        } else {
            do {
                try Data(line.utf8).write(to: filePath, options: .atomic)
            } catch {
                logError("Failed to create queue file: \(error.localizedDescription)")
            }
        }
    }

    func flush() -> [QueuedScrobble] {
        let fm = FileManager.default

        let source: URL
        if fm.fileExists(atPath: processingPath.path) {
            source = processingPath
        } else if fm.fileExists(atPath: filePath.path) {
            do {
                try fm.moveItem(at: filePath, to: processingPath)
            } catch {
                logError("Failed to move queue to processing: \(error.localizedDescription)")
                return []
            }
            source = processingPath
        } else {
            return []
        }

        guard let contents = try? String(contentsOf: source, encoding: .utf8) else {
            logError("Failed to read processing queue file")
            return []
        }

        let lines = contents.components(separatedBy: "\n")
        var entries: [QueuedScrobble] = []

        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            guard let data = trimmed.data(using: .utf8) else { continue }
            do {
                let scrobble = try decoder.decode(QueuedScrobble.self, from: data)
                entries.append(scrobble)
            } catch {
                logError("Skipping malformed queue entry")
            }
        }

        if entries.count > Self.maxEntries {
            entries = Array(entries.suffix(Self.maxEntries))
        }

        return entries
    }

    func completeFlush() {
        try? FileManager.default.removeItem(at: processingPath)
    }

    func abortFlush(_ remaining: [QueuedScrobble]) {
        var lines: [String] = []

        for entry in remaining {
            if let data = try? encoder.encode(entry),
               let line = String(data: data, encoding: .utf8) {
                lines.append(line)
            }
        }

        if FileManager.default.fileExists(atPath: filePath.path),
           let current = try? String(contentsOf: filePath, encoding: .utf8) {
            let currentLines = current.components(separatedBy: "\n")
                .filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            lines.append(contentsOf: currentLines)
        }

        if !lines.isEmpty {
            let content = lines.joined(separator: "\n") + "\n"
            try? Data(content.utf8).write(to: filePath, options: .atomic)
        }

        try? FileManager.default.removeItem(at: processingPath)
    }

    var count: Int {
        let fm = FileManager.default
        guard fm.fileExists(atPath: filePath.path) else { return 0 }
        guard let contents = try? String(contentsOf: filePath, encoding: .utf8) else { return 0 }
        return contents.components(separatedBy: "\n")
            .filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            .count
    }
}
