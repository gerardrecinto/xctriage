import XCTest
@testable import XCTriageKit

final class BatchTriageTests: XCTestCase {
    private func fixtures() -> String {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Fixtures").path
    }

    private func tempDir(_ files: [String: String]) throws -> String {
        let dir = NSTemporaryDirectory() + "xctriage-batch-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        for (name, body) in files { try body.write(toFile: dir + "/" + name, atomically: true, encoding: .utf8) }
        addTeardownBlock { try? FileManager.default.removeItem(atPath: dir) }
        return dir
    }

    func testBundledFixturesAreBothClassified() throws {
        let paths = try BatchTriage.listLogs(in: fixtures())
        let s = BatchTriage.run(paths: paths, threshold: 0.60)
        XCTAssertEqual(s.logs, 2)
        XCTAssertEqual(s.classified, 2, "\(s)")
        XCTAssertEqual(s.byCategory["compilation_error"], 1)
        XCTAssertEqual(s.coverage, 1.0)
    }

    func testLogWithNoKnownPatternIsListedAsNotClassified() throws {
        let dir = try tempDir(["quiet.log": "Build succeeded\nnothing to see\n", "notes.md": "ignored"])
        let paths = try BatchTriage.listLogs(in: dir)
        XCTAssertEqual(paths.count, 1, "only .log and .txt count")
        let s = BatchTriage.run(paths: paths, threshold: 0.60)
        XCTAssertEqual(s.unclassified, ["quiet.log"])
        XCTAssertEqual(s.coverage, 0)
        XCTAssertTrue(BatchTriage.render(s, threshold: 0.60).contains("Not classified"))
    }

    func testHigherThresholdMovesLogsToNotClassified() throws {
        let paths = try BatchTriage.listLogs(in: fixtures())
        XCTAssertEqual(BatchTriage.run(paths: paths, threshold: 1.01).classified, 0)
    }

    func testMissingAndNonDirectoryInputsAreNamed() {
        XCTAssertThrowsError(try BatchTriage.listLogs(in: "/nonexistent/logs")) {
            XCTAssertEqual($0.localizedDescription, "File not found: /nonexistent/logs")
        }
        XCTAssertThrowsError(try BatchTriage.listLogs(in: fixtures() + "/xcodebuild_compile_failure.log"))
    }

    func testJSONRoundTrips() throws {
        let s = BatchTriage.run(paths: try BatchTriage.listLogs(in: fixtures()), threshold: 0.60)
        let decoded = try JSONDecoder().decode(BatchSummary.self, from: Data(try BatchTriage.json(s).utf8))
        XCTAssertEqual(decoded, s)
    }
}
