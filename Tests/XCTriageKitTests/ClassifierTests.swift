import XCTest
@testable import XCTriageKit

final class ClassifierTests: XCTestCase {

    var classifier: RuleClassifier!
    var parser: BuildLogParser!

    override func setUp() {
        super.setUp()
        classifier = RuleClassifier()
        parser = BuildLogParser()
    }

    private func fixture(_ name: String) -> String {
        let url = Bundle.module.url(forResource: name, withExtension: "log", subdirectory: "Fixtures")!
        return try! String(contentsOf: url, encoding: .utf8)
    }

    // MARK: compilation errors

    func test_classify_swiftCompilationError() {
        let entries = parser.parse(fixture("xcodebuild_compile_failure"))
        let context = parser.extractFailureContext(entries)
        let result = classifier.classify(context)
        XCTAssertEqual(result.category, .compilationError)
        XCTAssertGreaterThanOrEqual(result.confidence, 0.85)
        XCTAssertFalse(result.llmUsed)
        XCTAssertNotNil(result.suggestedFix)
    }

    func test_classify_xcTestFailure() {
        let entries = parser.parse(fixture("xcodebuild_test_failure"))
        let context = parser.extractFailureContext(entries)
        let result = classifier.classify(context)
        XCTAssertEqual(result.category, .testFailure)
        XCTAssertGreaterThanOrEqual(result.confidence, 0.85)
    }

    func test_classify_oom() {
        let entry = LogEntry(lineNumber: 1, level: .error,
                             message: "Killed: 9 (out of memory)", raw: "")
        let result = classifier.classify([entry])
        XCTAssertEqual(result.category, .resourceExhaustion)
    }

    func test_classify_diskFull() {
        let entry = LogEntry(lineNumber: 1, level: .error,
                             message: "error: No space left on device", raw: "")
        let result = classifier.classify([entry])
        XCTAssertEqual(result.category, .resourceExhaustion)
    }

    func test_classify_simulatorFailure() {
        let entry = LogEntry(lineNumber: 1, level: .error,
                             message: "error: simctl boot failed: timeout", raw: "")
        let result = classifier.classify([entry])
        XCTAssertEqual(result.category, .infraFailure)
    }

    func test_classify_spmDependencyFailure() {
        let entry = LogEntry(lineNumber: 1, level: .error,
                             message: "error: swift package resolve failed: package not found", raw: "")
        let result = classifier.classify([entry])
        XCTAssertEqual(result.category, .dependencyFailure)
    }

    func test_classify_timeout() {
        let entry = LogEntry(lineNumber: 1, level: .error,
                             message: "Build timed out after 3600 seconds", raw: "")
        let result = classifier.classify([entry])
        XCTAssertEqual(result.category, .timeout)
    }

    func test_classify_linkerError() {
        let entry = LogEntry(lineNumber: 1, level: .error,
                             message: "ld: framework not found AVFoundation", raw: "")
        let result = classifier.classify([entry])
        XCTAssertEqual(result.category, .compilationError)
    }

    func test_classify_unknownForEmpty() {
        let result = classifier.classify([])
        XCTAssertEqual(result.category, .unknown)
        XCTAssertEqual(result.confidence, 0.0)
    }

    func test_classify_suggestedFixAlwaysPresent() {
        let entry = LogEntry(lineNumber: 1, level: .error,
                             message: "Killed: 9 (out of memory)", raw: "")
        let result = classifier.classify([entry])
        XCTAssertNotNil(result.suggestedFix)
        XCTAssertFalse(result.suggestedFix!.isEmpty)
    }
}
