import Foundation
import Darwin

let configDir = FileManager.default.homeDirectoryForCurrentUser
    .appendingPathComponent(".config/overheard")
let sessionFile = configDir.appendingPathComponent("session.json")
let queueFile = configDir.appendingPathComponent("queue.jsonl")
let lockFile = configDir.appendingPathComponent("lock")

struct Session: Codable, Sendable {
    let sessionKey: String
    let username: String
}

func loadSession() -> Session? {
    guard FileManager.default.fileExists(atPath: sessionFile.path) else { return nil }
    do {
        let data = try Data(contentsOf: sessionFile)
        return try JSONDecoder().decode(Session.self, from: data)
    } catch {
        logError("Failed to load session: \(error)")
        return nil
    }
}

func saveSession(_ session: Session) {
    guard ensureConfigDir() else { return }
    let encoder = JSONEncoder()
    encoder.outputFormatting = .prettyPrinted
    do {
        let data = try encoder.encode(session)
        try data.write(to: sessionFile, options: .atomic)
    } catch {
        logError("Failed to save session: \(error)")
    }
}

func acquireLock() -> Bool {
    guard ensureConfigDir() else { return false }

    if let existingPid = readLockPid() {
        if kill(existingPid, 0) == 0 {
            return false
        }
        // Stale lock — previous process crashed
        clearLock()
    }

    do {
        try "\(ProcessInfo.processInfo.processIdentifier)"
            .write(to: lockFile, atomically: true, encoding: .utf8)
        return true
    } catch {
        logError("Failed to write lock file: \(error)")
        return false
    }
}

func clearLock() {
    try? FileManager.default.removeItem(at: lockFile)
}

func readLockPid() -> Int32? {
    guard FileManager.default.fileExists(atPath: lockFile.path) else { return nil }
    guard let content = try? String(contentsOf: lockFile, encoding: .utf8) else { return nil }
    return Int32(content.trimmingCharacters(in: .whitespacesAndNewlines))
}

nonisolated(unsafe) var debugMode = false
nonisolated(unsafe) var autoExitMinutes: Double? = 4.65

private func timestamp() -> String {
    let f = DateFormatter()
    f.dateFormat = "HH:mm:ss.SSS"
    return f.string(from: Date())
}

func logError(_ message: String) {
    FileHandle.standardError.write(Data("[\(timestamp())] [overheard] \(message)\n".utf8))
}

func logInfo(_ message: String) {
    FileHandle.standardError.write(Data("[\(timestamp())] \(message)\n".utf8))
}

func logDebug(_ message: String) {
    guard debugMode else { return }
    FileHandle.standardError.write(Data("[\(timestamp())] [debug] \(message)\n".utf8))
}

@discardableResult
func ensureConfigDir() -> Bool {
    do {
        try FileManager.default.createDirectory(at: configDir, withIntermediateDirectories: true)
        return true
    } catch {
        logError("Failed to create config dir: \(error)")
        return false
    }
}
