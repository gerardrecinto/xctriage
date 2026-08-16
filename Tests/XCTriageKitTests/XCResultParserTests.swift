import XCTest
@testable import XCTriageKit

final class XCResultParserTests: XCTestCase {

    // Writes a throwaway shell script standing in for `xcrun`, so I can drive
    // XCResultParser's Process/Pipe handling without a real .xcresult bundle
    // or Xcode toolchain dependency in CI.
    private func makeFakeXcrun(stdout: String, exitCode: Int32 = 0) throws -> String {
        let path = NSTemporaryDirectory() + "fake-xcrun-\(UUID().uuidString).sh"
        let script = """
        #!/bin/sh
        cat <<'XCTRIAGE_EOF'
        \(stdout)
        XCTRIAGE_EOF
        exit \(exitCode)
        """
        try script.write(toFile: path, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: path)
        return path
    }

    func test_summary_decodesWellFormedXcresultJSON() async throws {
        let json = """
        {"actions":[{"actionResult":{"buildResult":{"issues":{"errors":[
            {"message":{"_value":"unresolved identifier 'Bar'"},
             "documentLocation":{"url":{"_value":"file:///repo/Foo.swift#StartingLineNumber=10&StartingColumnNumber=5"}}}
        ]}}}}]}
        """
        let xcrunPath = try makeFakeXcrun(stdout: json)
        let parser = XCResultParser(xcrunPath: xcrunPath)

        let sites = try await parser.testFailures(bundlePath: "/tmp/fake.xcresult")
        XCTAssertEqual(sites.count, 1)
        XCTAssertEqual(sites.first?.errorMessage, "unresolved identifier 'Bar'")
        XCTAssertEqual(sites.first?.file, "/repo/Foo.swift")
        XCTAssertEqual(sites.first?.line, 10)
        XCTAssertEqual(sites.first?.column, 5)
    }

    func test_summary_missingOptionalFieldsProduceEmptyResults() async throws {
        let xcrunPath = try makeFakeXcrun(stdout: "{}")
        let parser = XCResultParser(xcrunPath: xcrunPath)
        let sites = try await parser.testFailures(bundlePath: "/tmp/fake.xcresult")
        XCTAssertTrue(sites.isEmpty)
    }

    func test_run_throwsXcresultToolFailedOnNonZeroExit() async {
        do {
            let xcrunPath = try makeFakeXcrun(stdout: "boom", exitCode: 1)
            let parser = XCResultParser(xcrunPath: xcrunPath)
            _ = try await parser.summary(bundlePath: "/tmp/fake.xcresult")
            XCTFail("expected xcresultToolFailed for non-zero exit")
        } catch TriageError.xcresultToolFailed(let code, _) {
            XCTAssertEqual(code, 1)
        } catch {
            XCTFail("expected TriageError.xcresultToolFailed, got \(error)")
        }
    }

    // Regression test: the pipe-draining fix. Reading stdout only in
    // terminationHandler deadlocks once output exceeds the ~64KB pipe buffer,
    // because the child blocks on write() and never reaches exit. This
    // generates a payload well past that threshold; if the deadlock regresses,
    // this test hangs until the harness's own timeout instead of finishing.
    func test_summary_handlesOutputLargerThanPipeBuffer() async throws {
        let padding = String(repeating: "x", count: 200_000)
        let json = """
        {"actions":[{"actionResult":{"buildResult":{"issues":{"errors":[
            {"message":{"_value":"\(padding)"},
             "documentLocation":{"url":{"_value":"file:///repo/Foo.swift#StartingLineNumber=1"}}}
        ]}}}}]}
        """
        let xcrunPath = try makeFakeXcrun(stdout: json)
        let parser = XCResultParser(xcrunPath: xcrunPath)

        let sites = try await parser.testFailures(bundlePath: "/tmp/fake.xcresult")
        XCTAssertEqual(sites.first?.errorMessage.count, padding.count)
    }
}
