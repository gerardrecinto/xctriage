import XCTest
@testable import XCTriageKit

final class BuildLogParserTests: XCTestCase {

    var parser: BuildLogParser!

    override func setUp() {
        super.setUp()
        parser = BuildLogParser()
    }

    // MARK: compile failure fixture

    var compileLog: String {
        let url = Bundle.module.url(forResource: "xcodebuild_compile_failure", withExtension: "log",
                                    subdirectory: "Fixtures")!
        return try! String(contentsOf: url, encoding: .utf8)
    }

    var testLog: String {
        let url = Bundle.module.url(forResource: "xcodebuild_test_failure", withExtension: "log",
                                    subdirectory: "Fixtures")!
        return try! String(contentsOf: url, encoding: .utf8)
    }

    func test_parse_returnsAllLines() {
        let entries = parser.parse(compileLog)
        let lineCount = compileLog.components(separatedBy: "\n").count
        XCTAssertEqual(entries.count, lineCount)
    }

    func test_parse_detectsErrorLevel() {
        let entries = parser.parse(compileLog)
        let errors = entries.filter { $0.level == .error }
        XCTAssertGreaterThanOrEqual(errors.count, 3, "Expected at least 3 Swift error lines")
    }

    func test_extractFailureContext_containsOnlyErrorsAndWarnings() {
        let entries = parser.parse(compileLog)
        let context = parser.extractFailureContext(entries)
        XCTAssertFalse(context.isEmpty)
        XCTAssertTrue(context.allSatisfy { $0.level == .error || $0.level == .warning })
    }

    func test_extractFailureSites_compilationErrors() {
        let entries = parser.parse(compileLog)
        let context = parser.extractFailureContext(entries)
        let sites = parser.extractFailureSites(context)
        XCTAssertGreaterThanOrEqual(sites.count, 2)
        let firstSite = sites[0]
        XCTAssertNotNil(firstSite.file)
        XCTAssertNotNil(firstSite.line)
        XCTAssertTrue(firstSite.file!.contains("MediaDecoder.swift"))
        XCTAssertEqual(firstSite.line, 142)
    }

    func test_extractFailureSites_testFailures() {
        let entries = parser.parse(testLog)
        let context = parser.extractFailureContext(entries)
        let sites = parser.extractFailureSites(context)
        let testSites = sites.filter { $0.testName != nil }
        XCTAssertGreaterThanOrEqual(testSites.count, 1)
        XCTAssertTrue(testSites[0].testName!.contains("testAudioDecoderBitIdentical"))
    }

    func test_extractFailureSites_dedupsRepeatedLinkerError() {
        // Unlike the Swift/ObjC compiler-error branch (deduped by file:line),
        // the linker-error branch had no dedup at all — a log where the same
        // `ld:` line appears twice (e.g. echoed to both a file and stdout via
        // `tee`, or repeated by the linker itself) produced two identical
        // FailureSites instead of one.
        let log = """
        ld: symbol(s) not found for architecture arm64
        ld: symbol(s) not found for architecture arm64
        ** BUILD FAILED **
        """
        let entries = parser.parse(log)
        let context = parser.extractFailureContext(entries)
        let sites = parser.extractFailureSites(context)
        let linkerSites = sites.filter { $0.errorMessage.hasPrefix("linker:") }
        XCTAssertEqual(linkerSites.count, 1)
    }

    func test_parse_emptyLog() {
        let entries = parser.parse("")
        XCTAssertEqual(entries.count, 1, "Empty string yields one empty entry")
        XCTAssertNil(entries[0].level)
    }

    func test_logEntry_immutable() {
        let entry = LogEntry(lineNumber: 1, level: .error, message: "test", raw: "test")
        XCTAssertEqual(entry.lineNumber, 1)
        XCTAssertEqual(entry.level, .error)
    }
}
