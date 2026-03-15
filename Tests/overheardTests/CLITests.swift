import Foundation
import XCTest
@testable import overheard

final class CLITests: XCTestCase {
    func testParseLoveShortFlag() throws {
        let command = try parseCLICommand(arguments: ["-l"])
        XCTAssertEqual(command, .love)
    }

    func testParseLoveLongFlag() throws {
        let command = try parseCLICommand(arguments: ["--love"])
        XCTAssertEqual(command, .love)
    }

    func testParseManualScrobbleTrimsValues() throws {
        let command = try parseCLICommand(arguments: ["-a", "  Artist  ", "-s", " Song "])
        XCTAssertEqual(
            command,
            .manualScrobble(ManualScrobbleRequest(artist: "Artist", song: "Song"))
        )
    }

    func testLoveRejectsExtraArguments() {
        XCTAssertThrowsError(try parseCLICommand(arguments: ["-l", "extra"])) { error in
            XCTAssertEqual((error as? ManualCLIError)?.message, "Love command only supports -l or --love")
        }
    }

    func testControlRequestEncodesLoveCommand() throws {
        let data = try JSONEncoder().encode(ControlRequest.love)
        let decoded = try JSONDecoder().decode(ControlRequest.self, from: data)

        XCTAssertEqual(decoded, .love)
    }

    func testControlRequestEncodesManualScrobble() throws {
        let request = ControlRequest.manualScrobble(ManualScrobbleRequest(artist: "Artist", song: "Song"))
        let data = try JSONEncoder().encode(request)
        let decoded = try JSONDecoder().decode(ControlRequest.self, from: data)

        XCTAssertEqual(decoded, request)
    }

    func testParseToggleShortFlag() throws {
        let command = try parseCLICommand(arguments: ["-t"])
        XCTAssertEqual(command, .toggleScrobbling)
    }

    func testParseToggleLongFlag() throws {
        let command = try parseCLICommand(arguments: ["--toggle"])
        XCTAssertEqual(command, .toggleScrobbling)
    }

    func testToggleRejectsExtraArguments() {
        XCTAssertThrowsError(try parseCLICommand(arguments: ["--toggle", "extra"])) { error in
            XCTAssertEqual((error as? ManualCLIError)?.message, "Toggle command only supports -t or --toggle")
        }
    }

    func testToggleAndLoveCannotCombine() {
        XCTAssertThrowsError(try parseCLICommand(arguments: ["--toggle", "-l"])) { error in
            XCTAssertEqual((error as? ManualCLIError)?.message, "Cannot combine control flags")
        }
    }

    func testControlRequestEncodesToggle() throws {
        let data = try JSONEncoder().encode(ControlRequest.toggleScrobbling)
        let decoded = try JSONDecoder().decode(ControlRequest.self, from: data)

        XCTAssertEqual(decoded, .toggleScrobbling)
    }

    func testControlResponseEncoding() throws {
        let response = ControlResponse(success: true, message: "Loved: Artist - Song")
        let data = try JSONEncoder().encode(response)
        let decoded = try JSONDecoder().decode(ControlResponse.self, from: data)

        XCTAssertEqual(decoded.success, true)
        XCTAssertEqual(decoded.message, "Loved: Artist - Song")
    }
}
