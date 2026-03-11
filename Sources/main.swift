import Foundation
import Darwin

var args = Array(CommandLine.arguments.dropFirst())

if args.contains("--debug") {
    debugMode = true
    args.removeAll { $0 == "--debug" }
}

if args.contains("--ampm") {
    useAmPm = true
    args.removeAll { $0 == "--ampm" }
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

        try sendManualScrobbleRequest(request)
        print("Sent manual scrobble: \(request.artist) - \(request.track)")
        exit(0)
    } catch let error as ManualCLIError {
        logError(error.message)
        exit(1)
    } catch {
        logError("Failed to send manual scrobble: \(error.localizedDescription)")
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

if args.contains("-a") || args.contains("-s") {
    runManualScrobble(arguments: args)
}

switch args[0].lowercased() {
case "login":
    runLogin()

case "start":
    runStart()

case "-h", "--help", "help":
    printUsage()

default:
    printUsage()
    exit(1)
}

func printUsage() {
    print("""
    overheard \u{2014} auto-scrobble system audio to Last.fm

      (no args)              Login if needed, then start scrobbling
      login                  Authenticate with Last.fm
      -a <artist> -s <song>  Send immediate manual scrobble to running instance
      --debug                Show verbose pipeline diagnostics
      --ampm                 Use 12-hour AM/PM time format
      --no-auto-exit         Disable silence auto-exit
      --auto-exit <minutes>  Set silence timeout (default: 4.65)
    """)
}

struct ManualCLIError: Error {
    let message: String
}

func parseManualScrobbleArguments(_ arguments: [String]) throws -> ManualScrobbleRequest {
    var artist: String?
    var track: String?
    var index = 0

    while index < arguments.count {
        let argument = arguments[index]
        switch argument {
        case "-a":
            guard artist == nil else {
                throw ManualCLIError(message: "Artist flag provided more than once")
            }
            guard index + 1 < arguments.count else {
                throw ManualCLIError(message: "Missing value for -a")
            }
            artist = arguments[index + 1]
            index += 2

        case "-s":
            guard track == nil else {
                throw ManualCLIError(message: "Song flag provided more than once")
            }
            guard index + 1 < arguments.count else {
                throw ManualCLIError(message: "Missing value for -s")
            }
            track = arguments[index + 1]
            index += 2

        default:
            throw ManualCLIError(message: "Unknown argument for manual scrobble: \(argument)")
        }
    }

    guard let artist else {
        throw ManualCLIError(message: "Manual scrobble requires -a <artist>")
    }

    guard let track else {
        throw ManualCLIError(message: "Manual scrobble requires -s <song>")
    }

    let trimmedArtist = artist.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmedArtist.isEmpty else {
        throw ManualCLIError(message: "Artist cannot be empty")
    }

    let trimmedTrack = track.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmedTrack.isEmpty else {
        throw ManualCLIError(message: "Song cannot be empty")
    }

    return ManualScrobbleRequest(artist: trimmedArtist, track: trimmedTrack)
}
