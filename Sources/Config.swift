import Foundation
import Darwin

let configDir = FileManager.default.homeDirectoryForCurrentUser
    .appendingPathComponent(".config/radio-scrobbler")
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

func logError(_ message: String) {
    FileHandle.standardError.write(Data("[radio-scrobbler] \(message)\n".utf8))
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
