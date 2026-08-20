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

    func test_classify_swiftFatalError() {
        let entry = LogEntry(lineNumber: 1, level: .error,
                             message: "Fatal error: Unexpectedly found nil while unwrapping an Optional value", raw: "")
        let result = classifier.classify([entry])
        XCTAssertEqual(result.category, .runtimeCrash)
        XCTAssertGreaterThanOrEqual(result.confidence, 0.85)
    }

    func test_classify_execBadAccessCrash() {
        let entry = LogEntry(lineNumber: 1, level: .error,
                             message: "Thread 1: EXC_BAD_ACCESS (code=1, address=0x0)", raw: "")
        let result = classifier.classify([entry])
        XCTAssertEqual(result.category, .runtimeCrash)
    }

    func test_classify_addressSanitizerReport() {
        let entry = LogEntry(lineNumber: 1, level: .error,
                             message: "AddressSanitizer: heap-buffer-overflow on address 0x602000000010", raw: "")
        let result = classifier.classify([entry])
        XCTAssertEqual(result.category, .runtimeCrash)
        // Sanitizer reports are the most certain diagnosis of the three
        // runtime-crash rules — a real memory bug, not a symptom to guess at.
        XCTAssertGreaterThanOrEqual(result.confidence, 0.90)
    }

    // A crashed process rarely gets the chance to log "Test Case '...' failed"
    // before it dies, so this must classify correctly from the crash text
    // alone, with no test-failure line anywhere in the log.
    func test_classify_crashWithoutTestFailedLine() {
        let log = """
        Test Case '-[MediaTests testDecodeFrame]' started.
        /Users/ci/repo/Sources/MediaDecoder.swift:142: Fatal error: Unexpectedly found nil while unwrapping an Optional value
        """
        let entries = parser.parse(log)
        let context = parser.extractFailureContext(entries)
        let result = classifier.classify(context)
        XCTAssertEqual(result.category, .runtimeCrash)
    }

    // "Test Case '...' failed" (testFailure, weight 0.95) and "no space left
    // on device" (resourceExhaustion, weight 0.95) tie for the top weight.
    // Regression: the reported category and the reported summary must come
    // from the same rule. Verified empirically that a prior version could
    // report .resourceExhaustion paired with the testFailure rule's summary
    // text, because the category was picked via a Dictionary's unordered
    // max(by:) separately from the rule the summary text came from.
    func test_classify_tiedWeightRulesAcrossCategoriesStayConsistent() {
        let entry = LogEntry(lineNumber: 1, level: .error,
                             message: "Test Case 'FooTests.test_a' failed (0.10 seconds)\nerror: no space left on device", raw: "")
        let result = classifier.classify([entry])

        XCTAssertEqual(result.category, .testFailure)
        XCTAssertEqual(result.summary, "XCTest case failed")
    }
}
