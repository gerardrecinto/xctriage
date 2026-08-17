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

    // Same fake-xcrun idea, but also dumps its received argv to a sidecar
    // file, since the plain stub above ignores its arguments entirely and so
    // gives zero signal about what was actually invoked.
    private func makeFakeXcrunCapturingArgs(stdout: String, argsCapturePath: String, exitCode: Int32 = 0) throws -> String {
        let path = NSTemporaryDirectory() + "fake-xcrun-\(UUID().uuidString).sh"
        let script = """
        #!/bin/sh
        printf '%s\\n' "$@" > "\(argsCapturePath)"
        cat <<'XCTRIAGE_EOF'
        \(stdout)
        XCTRIAGE_EOF
        exit \(exitCode)
        """
        try script.write(toFile: path, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: path)
        return path
    }

    // Verified empirically against a real xcresulttool (Xcode 26.2, tool
    // version 24514): the exact command this type used to run —
    // `xcresulttool get --format json --path <bundle>`, no --legacy — exits
    // 64 unconditionally with "This command is deprecated... --legacy flag
    // is required to use it", regardless of whether the target bundle even
    // exists.
    func test_summary_invokesXcresulttoolWithLegacyFlag() async throws {
        let argsCapturePath = NSTemporaryDirectory() + "xcrun-args-\(UUID().uuidString).txt"
        let xcrunPath = try makeFakeXcrunCapturingArgs(stdout: "{}", argsCapturePath: argsCapturePath)
        let parser = XCResultParser(xcrunPath: xcrunPath)

        _ = try await parser.summary(bundlePath: "/tmp/fake.xcresult")

        let capturedArgs = try String(contentsOfFile: argsCapturePath, encoding: .utf8)
        XCTAssertTrue(capturedArgs.contains("--legacy"), "xcresulttool invocation missing --legacy: \(capturedArgs)")
    }

    // A trimmed but structurally real fixture: captured from
    // `xcodebuild test -resultBundlePath` on a package with one deliberately
    // failing XCTAssertEqual, then reduced to the fields this parser reads.
    // Every wrapper below (_type/_value/_values) is exactly what real
    // xcresulttool --legacy output uses — this is not a guessed shape.
    private static let realTestFailureJSON = """
    {
      "_type": {"_name": "ActionsInvocationRecord"},
      "actions": {
        "_type": {"_name": "Array"},
        "_values": [
          {
            "_type": {"_name": "ActionRecord"},
            "actionResult": {
              "_type": {"_name": "ActionResult"},
              "issues": {
                "_type": {"_name": "ResultIssueSummaries"},
                "testFailureSummaries": {
                  "_type": {"_name": "Array"},
                  "_values": [
                    {
                      "_type": {"_name": "TestFailureIssueSummary", "_supertype": {"_name": "IssueSummary"}},
                      "testCaseName": {"_type": {"_name": "String"}, "_value": "SchemaProbeTests.test_addition_deliberatelyWrongToProduceARealFailure()"},
                      "issueType": {"_type": {"_name": "String"}, "_value": "Uncategorized"},
                      "message": {"_type": {"_name": "String"}, "_value": "XCTAssertEqual failed: (\\"4\\") is not equal to (\\"5\\")"},
                      "documentLocationInCreatingWorkspace": {
                        "_type": {"_name": "DocumentLocation"},
                        "url": {"_type": {"_name": "String"}, "_value": "file:///repo/Tests/SchemaProbeTests.swift#EndingLineNumber=5&StartingLineNumber=5"}
                      }
                    }
                  ]
                }
              }
            }
          }
        ]
      }
    }
    """

    func test_testFailures_decodesRealTestFailureSummaryShape() async throws {
        let xcrunPath = try makeFakeXcrun(stdout: Self.realTestFailureJSON)
        let parser = XCResultParser(xcrunPath: xcrunPath)

        let sites = try await parser.testFailures(bundlePath: "/tmp/fake.xcresult")

        XCTAssertEqual(sites.count, 1)
        let site = try XCTUnwrap(sites.first)
        XCTAssertEqual(site.testName, "SchemaProbeTests.test_addition_deliberatelyWrongToProduceARealFailure()")
        XCTAssertEqual(site.errorMessage, "XCTAssertEqual failed: (\"4\") is not equal to (\"5\")")
        XCTAssertEqual(site.file, "/repo/Tests/SchemaProbeTests.swift")
        XCTAssertEqual(site.line, 5)
    }

    // A trimmed but structurally real fixture for the OTHER shape actionResult.issues
    // can take: errorSummaries for a build failure, captured from a real
    // scheme-level build failure. No document location field is present in
    // real output for this case — verified against two separate real
    // build-failure bundles, not assumed.
    private static let realBuildFailureJSON = """
    {
      "_type": {"_name": "ActionsInvocationRecord"},
      "actions": {
        "_type": {"_name": "Array"},
        "_values": [
          {
            "_type": {"_name": "ActionRecord"},
            "actionResult": {
              "_type": {"_name": "ActionResult"},
              "issues": {
                "_type": {"_name": "ResultIssueSummaries"},
                "errorSummaries": {
                  "_type": {"_name": "Array"},
                  "_values": [
                    {
                      "_type": {"_name": "IssueSummary"},
                      "issueType": {"_type": {"_name": "String"}, "_value": "Uncategorized"},
                      "message": {"_type": {"_name": "String"}, "_value": "Testing cancelled because the build failed."}
                    }
                  ]
                }
              }
            }
          }
        ]
      }
    }
    """

    func test_testFailures_decodesRealBuildFailureErrorSummaryShape() async throws {
        let xcrunPath = try makeFakeXcrun(stdout: Self.realBuildFailureJSON)
        let parser = XCResultParser(xcrunPath: xcrunPath)

        let sites = try await parser.testFailures(bundlePath: "/tmp/fake.xcresult")

        XCTAssertEqual(sites.count, 1)
        let site = try XCTUnwrap(sites.first)
        XCTAssertNil(site.testName)
        XCTAssertNil(site.file)
        XCTAssertEqual(site.errorMessage, "Testing cancelled because the build failed.")
    }

    func test_testFailures_combinesTestFailuresAndErrorSummariesFromTheSameAction() async throws {
        // Both keys can appear as siblings under the same actionResult.issues;
        // both should surface as FailureSites.
        let json = """
        {"actions":{"_values":[{"actionResult":{"issues":{
            "testFailureSummaries":{"_values":[
                {"testCaseName":{"_value":"Foo.test_a"},"message":{"_value":"assertion failed"}}
            ]},
            "errorSummaries":{"_values":[
                {"message":{"_value":"a separate build issue"}}
            ]}
        }}}]}}
        """
        let xcrunPath = try makeFakeXcrun(stdout: json)
        let parser = XCResultParser(xcrunPath: xcrunPath)

        let sites = try await parser.testFailures(bundlePath: "/tmp/fake.xcresult")
        XCTAssertEqual(sites.count, 2)
        XCTAssertTrue(sites.contains { $0.testName == "Foo.test_a" })
        XCTAssertTrue(sites.contains { $0.errorMessage == "a separate build issue" })
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
        {"actions":{"_values":[{"actionResult":{"issues":{"errorSummaries":{"_values":[
            {"message":{"_value":"\(padding)"}}
        ]}}}}]}}
        """
        let xcrunPath = try makeFakeXcrun(stdout: json)
        let parser = XCResultParser(xcrunPath: xcrunPath)

        let sites = try await parser.testFailures(bundlePath: "/tmp/fake.xcresult")
        XCTAssertEqual(sites.first?.errorMessage.count, padding.count)
    }
}
