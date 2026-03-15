import Foundation
import XCTest
@testable import overheard

final class CLITests: XCTestCase {
    func testParseLoveShortFlag() throws {
        let command = try parseCLICommand(arguments: ["-l"])
        XCTAssertEqual(command, .loveLastScrobbledTrack)
    }

    func testParseLoveLongFlag() throws {
        let command = try parseCLICommand(arguments: ["--love"])
        XCTAssertEqual(command, .loveLastScrobbledTrack)
    }

    func testParseManualScrobbleTrimsValues() throws {
        let command = try parseCLICommand(arguments: ["-a", "  Artist  ", "-s", " Song "])
        XCTAssertEqual(
            command,
            .manualScrobble(ManualScrobbleRequest(artist: "Artist", track: "Song"))
        )
    }

    func testLoveRejectsExtraArguments() {
        XCTAssertThrowsError(try parseCLICommand(arguments: ["-l", "extra"])) { error in
            XCTAssertEqual((error as? ManualCLIError)?.message, "Love command only supports -l or --love")
        }
    }

    func testControlRequestEncodesLoveCommand() throws {
        let data = try JSONEncoder().encode(ControlRequest.loveLastScrobbledTrack)
        let decoded = try JSONDecoder().decode(ControlRequest.self, from: data)

        XCTAssertEqual(decoded, .loveLastScrobbledTrack)
    }

    func testControlRequestEncodesManualScrobble() throws {
        let request = ControlRequest.manualScrobble(ManualScrobbleRequest(artist: "Artist", track: "Song"))
        let data = try JSONEncoder().encode(request)
        let decoded = try JSONDecoder().decode(ControlRequest.self, from: data)

        XCTAssertEqual(decoded, request)
    }
}
