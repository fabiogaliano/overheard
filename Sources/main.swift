import Foundation
import Darwin

var args = Array(CommandLine.arguments.dropFirst())

if args.contains("--debug") || args.contains("-d") {
    debugMode = true
    args.removeAll { $0 == "--debug" || $0 == "-d" }
}

if let idx = args.firstIndex(of: "--time-format"), idx + 1 < args.count {
    switch args[idx + 1] {
    case "12h":
        useAmPm = true
    case "24h":
        useAmPm = false
    default:
        logError("--time-format requires '12h' or '24h'")
        exit(1)
    }
    args.removeSubrange(idx...idx + 1)
}

if args.contains("--no-scrobble") || args.contains("-n") {
    noScrobble = true
    args.removeAll { $0 == "--no-scrobble" || $0 == "-n" }
}

if let idx = args.firstIndex(of: "--auto-exit"), idx + 1 < args.count {
    let value = args[idx + 1]
    if value == "off" {
        autoExitMinutes = nil
    } else if let minutes = Double(value), minutes > 0 {
        autoExitMinutes = minutes
    } else {
        logError("--auto-exit requires a positive number or 'off'")
        exit(1)
    }
    args.removeSubrange(idx...idx + 1)
}

@MainActor func runStart() {
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
}

func runLogin() {
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
}

func runManualScrobble(arguments: [String]) {
    do {
        let request = try parseManualScrobbleArguments(arguments)

        guard runningLockPid() != nil else {
            logError("No running overheard instance found. Start overheard first.")
            exit(1)
        }

        let response = try sendControlRequest(.manualScrobble(request))
        print(response.message)
        exit(response.success ? 0 : 1)
    } catch let error as ManualCLIError {
        logError(error.message)
        exit(1)
    } catch {
        logError("Failed to send scrobble: \(error.localizedDescription)")
        exit(1)
    }
}

func runLove() {
    guard runningLockPid() != nil else {
        logError("No running overheard instance found. Start overheard first.")
        exit(1)
    }

    do {
        let response = try sendControlRequest(.love)
        print(response.message)
        exit(response.success ? 0 : 1)
    } catch {
        logError("Failed to send love request: \(error.localizedDescription)")
        exit(1)
    }
}

func runToggleScrobbling() {
    guard runningLockPid() != nil else {
        logError("No running overheard instance found. Start overheard first.")
        exit(1)
    }

    do {
        let response = try sendControlRequest(.toggleScrobbling)
        print(response.message)
        exit(response.success ? 0 : 1)
    } catch {
        logError("Failed to send toggle request: \(error.localizedDescription)")
        exit(1)
    }
}

if args.isEmpty {
    if loadSession() == nil {
        runLogin()
    } else {
        runStart()
    }
    exit(0)
}

do {
    switch try parseCLICommand(arguments: args) {
    case .login:
        runLogin()

    case .start:
        runStart()

    case .help:
        printUsage()

    case .manualScrobble:
        runManualScrobble(arguments: args)

    case .love:
        runLove()

    case .toggleScrobbling:
        runToggleScrobbling()
    }
} catch let error as ManualCLIError {
    logError(error.message)
    printUsage()
    exit(1)
} catch {
    logError("Failed to parse arguments: \(error.localizedDescription)")
    exit(1)
}

func printUsage() {
    print("""
    overheard \u{2014} auto-scrobble system audio to Last.fm

      (no args)              Login if needed, then start scrobbling
      login                  Authenticate with Last.fm
      start                  Start scrobbling explicitly

    Runtime commands (send to running instance):
      -a <artist> -s <song>  Send immediate manual scrobble
      -l, --love             Love the last recognized song
      -t, --toggle           Toggle scrobbling on/off

    Options:
      -n, --no-scrobble          Listen-only mode (no scrobbling)
      -d, --debug                Show verbose pipeline diagnostics
      --auto-exit <min|off>      Silence timeout (default: 5)
      --time-format <12h|24h>    Time display format (default: 24h)
    """)
}
