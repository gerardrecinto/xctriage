import XCTest
@testable import XCTriageKit

final class FailureFingerprintTests: XCTestCase {

    private func site(file: String? = "Foo.swift", line: Int? = 10, testName: String? = "FooTests.test_a", message: String) -> FailureSite {
        FailureSite(file: file, line: line, column: nil, testName: testName, errorMessage: message)
    }

    func test_init_isDeterministicForSameInput() {
        let a = FailureFingerprint(category: .compilationError, failureSites: [site(message: "unresolved identifier 'Foo'")])
        let b = FailureFingerprint(category: .compilationError, failureSites: [site(message: "unresolved identifier 'Foo'")])
        XCTAssertEqual(a.value, b.value)
    }

    func test_init_differsByCategory() {
        let a = FailureFingerprint(category: .compilationError, failureSites: [site(message: "boom")])
        let b = FailureFingerprint(category: .testFailure, failureSites: [site(message: "boom")])
        XCTAssertNotEqual(a.value, b.value)
    }

    func test_init_differsBySubstantiveMessageChange() {
        let a = FailureFingerprint(category: .compilationError, failureSites: [site(message: "unresolved identifier 'Foo'")])
        let b = FailureFingerprint(category: .compilationError, failureSites: [site(message: "unresolved identifier 'Bar'")])
        XCTAssertNotEqual(a.value, b.value)
    }

    func test_init_ignoresUUIDsInMessage() {
        let a = FailureFingerprint(
            category: .testFailure,
            failureSites: [site(message: "session 4F3C1A9E-1B2C-4D5E-8F6A-9B0C1D2E3F4A timed out")]
        )
        let b = FailureFingerprint(
            category: .testFailure,
            failureSites: [site(message: "session AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE timed out")]
        )
        XCTAssertEqual(a.value, b.value)
    }

    func test_init_ignoresMemoryAddresses() {
        let a = FailureFingerprint(category: .testFailure, failureSites: [site(message: "crash at 0x00007ffee3a1b2c0")])
        let b = FailureFingerprint(category: .testFailure, failureSites: [site(message: "crash at 0x00001234abcd5678")])
        XCTAssertEqual(a.value, b.value)
    }

    func test_init_ignoresTempPaths() {
        let a = FailureFingerprint(category: .infraFailure, failureSites: [site(message: "missing file /var/folders/ab/xyz123/T/fixture.json")])
        let b = FailureFingerprint(category: .infraFailure, failureSites: [site(message: "missing file /var/folders/zz/other456/T/fixture.json")])
        XCTAssertEqual(a.value, b.value)
    }

    func test_init_ignoresLongDigitRuns() {
        // Covers the `\d{6,}` volatile pattern in FailureFingerprint.normalize
        // (a PID, a timestamp, a build number) — implemented but previously
        // untested directly, unlike the UUID/address/temp-path patterns above.
        let a = FailureFingerprint(category: .infraFailure, failureSites: [site(message: "worker pid 482913 died unexpectedly")])
        let b = FailureFingerprint(category: .infraFailure, failureSites: [site(message: "worker pid 9917305 died unexpectedly")])
        XCTAssertEqual(a.value, b.value)
    }

    func test_init_shortDigitRunsStillDistinguishMessages() {
        // The volatile-digit-run pattern only strips runs of 6+ digits, so a
        // genuinely different short number (e.g. a line number embedded in
        // the message, or an exit code) must still change the fingerprint.
        let a = FailureFingerprint(category: .testFailure, failureSites: [site(message: "exit code 42")])
        let b = FailureFingerprint(category: .testFailure, failureSites: [site(message: "exit code 137")])
        XCTAssertNotEqual(a.value, b.value)
    }

    func test_init_usesOnlyFilenameNotFullDirectoryPath() {
        // normalizedSignature takes URL(fileURLWithPath:).lastPathComponent,
        // so the same file failing under two different checkout roots (a
        // local path vs. a CI runner's workspace path) still fingerprints
        // identically — previously implemented but untested directly.
        let a = FailureFingerprint(
            category: .compilationError,
            failureSites: [site(file: "/Users/dev/xctriage/Foo.swift", message: "unresolved identifier 'Foo'")]
        )
        let b = FailureFingerprint(
            category: .compilationError,
            failureSites: [site(file: "/Users/runner/work/xctriage/xctriage/Foo.swift", message: "unresolved identifier 'Foo'")]
        )
        XCTAssertEqual(a.value, b.value)
    }

    func test_init_handlesEmptyFailureSitesWithoutCrashing() {
        let fp = FailureFingerprint(category: .unknown, failureSites: [])
        XCTAssertFalse(fp.value.isEmpty)
    }

    func test_value_isSixteenHexCharacters() {
        let fp = FailureFingerprint(category: .compilationError, failureSites: [site(message: "boom")])
        XCTAssertEqual(fp.value.count, 16)
        XCTAssertTrue(fp.value.allSatisfy { $0.isHexDigit })
    }
}
