import Foundation

enum CLICommand: Equatable {
    case login
    case start
    case help
    case manualScrobble(ManualScrobbleRequest)
    case love
    case toggleScrobbling
}

struct ManualCLIError: Error {
    let message: String
}

func parseCLICommand(arguments: [String]) throws -> CLICommand {
    let hasLoveFlag = arguments.contains("-l") || arguments.contains("--love")
    let hasToggleFlag = arguments.contains("-t") || arguments.contains("--toggle")
    let hasManualScrobbleFlag = arguments.contains("-a") || arguments.contains("-s")

    let controlFlags = [hasLoveFlag, hasToggleFlag, hasManualScrobbleFlag].filter { $0 }.count
    if controlFlags > 1 {
        throw ManualCLIError(message: "Cannot combine control flags")
    }

    if hasLoveFlag {
        return try parseLoveArguments(arguments)
    }

    if hasToggleFlag {
        return try parseToggleArguments(arguments)
    }

    if hasManualScrobbleFlag {
        return .manualScrobble(try parseManualScrobbleArguments(arguments))
    }

    guard let firstArgument = arguments.first else {
        return .start
    }

    switch firstArgument.lowercased() {
    case "login":
        return .login
    case "start":
        return .start
    case "-h", "--help", "help":
        return .help
    default:
        throw ManualCLIError(message: "Unknown command: \(firstArgument)")
    }
}

func parseManualScrobbleArguments(_ arguments: [String]) throws -> ManualScrobbleRequest {
    var artist: String?
    var song: String?
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
            guard song == nil else {
                throw ManualCLIError(message: "Song flag provided more than once")
            }
            guard index + 1 < arguments.count else {
                throw ManualCLIError(message: "Missing value for -s")
            }
            song = arguments[index + 1]
            index += 2

        default:
            throw ManualCLIError(message: "Unknown argument: \(argument)")
        }
    }

    guard let artist else {
        throw ManualCLIError(message: "Manual scrobble requires -a <artist>")
    }

    guard let song else {
        throw ManualCLIError(message: "Manual scrobble requires -s <song>")
    }

    let trimmedArtist = artist.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmedArtist.isEmpty else {
        throw ManualCLIError(message: "Artist cannot be empty")
    }

    let trimmedSong = song.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmedSong.isEmpty else {
        throw ManualCLIError(message: "Song cannot be empty")
    }

    return ManualScrobbleRequest(artist: trimmedArtist, song: trimmedSong)
}

func parseLoveArguments(_ arguments: [String]) throws -> CLICommand {
    guard arguments.count == 1 else {
        throw ManualCLIError(message: "Love command only supports -l or --love")
    }

    guard arguments[0] == "-l" || arguments[0] == "--love" else {
        throw ManualCLIError(message: "Love command only supports -l or --love")
    }

    return .love
}

func parseToggleArguments(_ arguments: [String]) throws -> CLICommand {
    guard arguments.count == 1 else {
        throw ManualCLIError(message: "Toggle command only supports -t or --toggle")
    }

    guard arguments[0] == "-t" || arguments[0] == "--toggle" else {
        throw ManualCLIError(message: "Toggle command only supports -t or --toggle")
    }

    return .toggleScrobbling
}
