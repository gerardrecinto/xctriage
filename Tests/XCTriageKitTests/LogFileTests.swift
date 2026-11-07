import XCTest
@testable import XCTriageKit

final class LogFileTests: XCTestCase {
    private func tempFile(_ bytes: [UInt8]) throws -> String {
        let path = NSTemporaryDirectory() + "xctriage-\(UUID().uuidString).log"
        try Data(bytes).write(to: URL(fileURLWithPath: path))
        addTeardownBlock { try? FileManager.default.removeItem(atPath: path) }
        return path
    }

    func testMissingFileSaysFileNotFound() {
        XCTAssertThrowsError(try LogFile.read("/nonexistent/build.log")) { error in
            XCTAssertEqual(error.localizedDescription, "File not found: /nonexistent/build.log")
        }
    }

    func testDirectoryIsNamedAsADirectory() {
        XCTAssertThrowsError(try LogFile.read(NSTemporaryDirectory())) { error in
            XCTAssertTrue(error.localizedDescription.contains("is a directory"), "\(error)")
        }
    }

    func testInvalidUTF8StillReadsTheValidPart() throws {
        let path = try tempFile(Array("error: bad thing\n".utf8) + [0xFF, 0xFE] + Array("\nnext line\n".utf8))
        let text = try LogFile.read(path)
        XCTAssertTrue(text.contains("error: bad thing"))
        XCTAssertTrue(text.contains("next line"))
    }

    func testEveryErrorHasAPlainDescription() {
        let all: [TriageError] = [
            .fileNotFound("a"), .notAFile("a"), .unreadable("a"), .xcresultToolFailed(1, "x"),
            .parseError("x"), .claudeAPIError(500, "x"), .slackWebhookFailed(500, "x"),
            .missingAPIKey, .remediationCommandFailed("c", "x"), .sandboxTimedOut(command: "c", seconds: 5),
        ]
        for error in all {
            let text = error.localizedDescription
            XCTAssertFalse(text.contains("TriageError"), text)
            XCTAssertFalse(text.contains("("), text)
        }
    }
}
