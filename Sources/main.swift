import Foundation
import Darwin

var args = Array(CommandLine.arguments.dropFirst())

if args.contains("--debug") {
    debugMode = true
    args.removeAll { $0 == "--debug" }
}

if args.contains("--no-auto-exit") {
    autoExitMinutes = nil
    args.removeAll { $0 == "--no-auto-exit" }
}

if let idx = args.firstIndex(of: "--auto-exit"), idx + 1 < args.count {
    guard let minutes = Double(args[idx + 1]), minutes > 0 else {
        logError("--auto-exit requires a positive number (minutes)")
        exit(1)
    }
    autoExitMinutes = minutes
    args.removeSubrange(idx...idx + 1)
}

if args.isEmpty {
    printUsage()
    exit(0)
}

switch args[0].lowercased() {
case "login":
    print("Last.fm username: ", terminator: "")
    guard let username = readLine()?.trimmingCharacters(in: .whitespacesAndNewlines),
          !username.isEmpty else {
        logError("No username provided")
        exit(1)
    }

    guard let rawPassword = getpass("Password: ") else {
        logError("Failed to read password")
        exit(1)
    }
    let password = String(cString: rawPassword)

    let client = LastFmClient()
    Task {
        do {
            let session = try await client.authenticate(username: username, password: password)
            saveSession(session)
            print("\u{2713} Logged in as \(session.username)")
            exit(0)
        } catch {
            logError("Login failed: \(error)")
            exit(1)
        }
    }
    RunLoop.main.run()

case "start":
    guard acquireLock() else {
        logError("Already running (another instance holds the lock)")
        exit(1)
    }

    guard let session = loadSession() else {
        logError("Not logged in. Run 'overheard login' first.")
        clearLock()
        exit(1)
    }

    let controller = ScrobbleController(session: session)

    signal(SIGINT, SIG_IGN)
    signal(SIGTERM, SIG_IGN)

    let sigintSource = DispatchSource.makeSignalSource(signal: SIGINT, queue: .main)
    let sigtermSource = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)

    sigintSource.setEventHandler {
        Task { @MainActor in
            await controller.shutdown()
            exit(0)
        }
    }
    sigtermSource.setEventHandler {
        Task { @MainActor in
            await controller.shutdown()
            exit(0)
        }
    }

    sigintSource.resume()
    sigtermSource.resume()

    Task {
        do {
            try await controller.start()
        } catch {
            logError("Failed to start: \(error)")
            await controller.shutdown()
            exit(1)
        }
    }
    RunLoop.main.run()

case "-h", "--help", "help":
    printUsage()

default:
    printUsage()
    exit(1)
}

func printUsage() {
    print("""
    overheard \u{2014} auto-scrobble system audio to Last.fm

      login                  Authenticate with Last.fm
      start                  Start listening and scrobbling
      --debug                Show verbose pipeline diagnostics
      --no-auto-exit         Disable silence auto-exit
      --auto-exit <minutes>  Set silence timeout (default: 4.65)
    """)
}
