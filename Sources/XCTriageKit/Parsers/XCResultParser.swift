import Foundation

// Accumulates pipe output across readabilityHandler callbacks. Access is
// externally serialized on a single DispatchQueue (see PipeReader below),
// so @unchecked Sendable is safe here: the queue is the only synchronization
// primitive touching this buffer, matching the DBHandle pattern used by
// FlakyTestTracker for other non-Sendable system handles.
private final class PipeBuffer: @unchecked Sendable {
    var data = Data()
}

// Wraps `xcrun xcresulttool` to extract structured data from .xcresult bundles.
// Falls back gracefully if xcresulttool is unavailable (non-macOS CI agents).
public actor XCResultParser {

    private let xcrunPath: String

    public init(xcrunPath: String = "/usr/bin/xcrun") {
        self.xcrunPath = xcrunPath
    }

    // Returns the top-level JSON summary from an xcresult bundle
    public func summary(bundlePath: String) async throws -> XCResultSummary {
        // --legacy is required as of Xcode 16's xcresulttool (verified against
        // tool version 24514, Xcode 26.2): without it, `get` exits 64
        // unconditionally with "This command is deprecated... --legacy flag
        // is required to use it", before even checking whether bundlePath
        // exists.
        let json = try await run(
            arguments: ["xcresulttool", "get", "--legacy", "--format", "json", "--path", bundlePath]
        )
        let data = Data(json.utf8)
        guard let raw = try? JSONSerialization.jsonObject(with: data) else {
            throw TriageError.parseError("xcresulttool returned non-JSON output")
        }
        // --legacy's JSON wraps every value in a {"_type": {...}, "_value": ...}
        // or {"_type": {...}, "_values": [...]} envelope (verified against
        // real bundles from `xcodebuild test -resultBundlePath`, both a build
        // failure and a genuine XCTest assertion failure) — unwrap it into
        // plain JSON once, up front, rather than writing a custom decode
        // path for every field.
        let unwrapped = Self.unwrapLegacyEnvelope(raw)
        let cleanData = try JSONSerialization.data(withJSONObject: unwrapped)
        return try JSONDecoder().decode(XCResultSummary.self, from: cleanData)
    }

    // Returns all test failure sites extracted from the bundle: genuine
    // XCTest assertion failures (testFailureSummaries, which carry the test
    // name and a document location) plus any generic build-blocking issues
    // (errorSummaries) reported alongside them. Verified against a real
    // xcodebuild test run with a deliberately-failing assertion that
    // errorSummaries entries for a build failure don't carry a reliable
    // document location the way testFailureSummaries entries do — parseFileURL
    // degrades to (nil, nil, nil) for a nil/missing url either way.
    public func testFailures(bundlePath: String) async throws -> [FailureSite] {
        let summary = try await summary(bundlePath: bundlePath)
        var sites: [FailureSite] = []

        for action in summary.actions ?? [] {
            guard let issues = action.actionResult?.issues else { continue }

            for failure in issues.testFailureSummaries ?? [] {
                let (file, line, col) = parseFileURL(failure.documentLocationInCreatingWorkspace?.url)
                sites.append(FailureSite(
                    file: file, line: line, column: col,
                    testName: failure.testCaseName, errorMessage: failure.message ?? "unknown error"
                ))
            }
            for error in issues.errorSummaries ?? [] {
                let (file, line, col) = parseFileURL(error.documentLocation?.url)
                sites.append(FailureSite(
                    file: file, line: line, column: col,
                    testName: nil, errorMessage: error.message ?? "unknown error"
                ))
            }
        }
        return sites
    }

    // See the comment on `summary(bundlePath:)`: recursively strips
    // xcresulttool --legacy's {"_type", "_value"/"_values"} envelope down to
    // plain JSON values, so the Codable types below can be ordinary structs
    // instead of a custom decoder for every field.
    private static func unwrapLegacyEnvelope(_ value: Any) -> Any {
        if let array = value as? [Any] {
            return array.map(unwrapLegacyEnvelope)
        }
        guard let dict = value as? [String: Any] else { return value }
        if let values = dict["_values"] as? [Any] {
            return values.map(unwrapLegacyEnvelope)
        }
        if let scalar = dict["_value"] {
            return scalar
        }
        var result: [String: Any] = [:]
        for (key, nested) in dict where key != "_type" {
            result[key] = unwrapLegacyEnvelope(nested)
        }
        return result
    }

    // MARK: Private

    // xcresulttool JSON output for a bundle with many issues can exceed the pipe's
    // kernel buffer (64KB on macOS). Reading only in terminationHandler deadlocks:
    // the child blocks writing to a full pipe while the parent waits for a
    // termination that can't happen. Drain both pipes continuously via
    // readabilityHandler instead, with a final drain on exit to catch anything
    // buffered between the last readability callback and process termination.
    private func run(arguments: [String]) async throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: xcrunPath)
        process.arguments = arguments

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError  = stderrPipe

        return try await withCheckedThrowingContinuation { continuation in
            let outHandle = stdoutPipe.fileHandleForReading
            let errHandle = stderrPipe.fileHandleForReading
            let bufferQueue = DispatchQueue(label: "xctriage.xcresulttool.output")
            let stdoutBuffer = PipeBuffer()
            let stderrBuffer = PipeBuffer()

            outHandle.readabilityHandler = { handle in
                let chunk = handle.availableData
                guard !chunk.isEmpty else { return }
                bufferQueue.sync { stdoutBuffer.data.append(chunk) }
            }
            errHandle.readabilityHandler = { handle in
                let chunk = handle.availableData
                guard !chunk.isEmpty else { return }
                bufferQueue.sync { stderrBuffer.data.append(chunk) }
            }

            process.terminationHandler = { p in
                let trailingOut = outHandle.readDataToEndOfFile()
                let trailingErr = errHandle.readDataToEndOfFile()
                outHandle.readabilityHandler = nil
                errHandle.readabilityHandler = nil

                let (out, err): (String, String) = bufferQueue.sync {
                    stdoutBuffer.data.append(trailingOut)
                    stderrBuffer.data.append(trailingErr)
                    return (String(data: stdoutBuffer.data, encoding: .utf8) ?? "",
                            String(data: stderrBuffer.data, encoding: .utf8) ?? "")
                }

                if p.terminationStatus == 0 {
                    continuation.resume(returning: out)
                } else {
                    continuation.resume(throwing: TriageError.xcresultToolFailed(p.terminationStatus, err))
                }
            }
            do {
                try process.run()
            } catch {
                continuation.resume(throwing: error)
            }
        }
    }

    // xcresulttool's DocumentLocation URLs encode line/column as a fragment,
    // not a query string: file:///path/File.swift#StartingLineNumber=10&StartingColumnNumber=5
    // URLComponents.queryItems only parses the `?query` half of a URL, so it
    // silently returns nil for these: every failure site's file/line/column
    // was previously lost. Parse the fragment's key=value pairs directly.
    private func parseFileURL(_ urlString: String?) -> (String?, Int?, Int?) {
        guard let str = urlString,
              let url = URL(string: str) else { return (nil, nil, nil) }
        let file = url.path
        let params = (url.fragment ?? "")
            .split(separator: "&")
            .reduce(into: [String: String]()) { dict, pair in
                let parts = pair.split(separator: "=", maxSplits: 1)
                guard parts.count == 2 else { return }
                dict[String(parts[0])] = String(parts[1])
            }
        let line = params["StartingLineNumber"].flatMap { Int($0) }
        let col  = params["StartingColumnNumber"].flatMap { Int($0) }
        return (file, line, col)
    }
}

// MARK: Codable types for xcresulttool --legacy JSON output
//
// Shaped to match the JSON *after* unwrapLegacyEnvelope strips xcresulttool's
// {"_type", "_value"/"_values"} wrapper — every field below is the plain
// value it looks like, not a nested wrapper struct. Verified against three
// real `xcodebuild test -resultBundlePath` bundles: a scheme-level build
// failure, a real compile error in application code, and a genuine XCTest
// assertion failure. All three land errorSummaries directly under
// actionResult.issues (not nested inside a separate buildResult, which
// doesn't exist at that path in real output); only testFailureSummaries
// entries carry testCaseName and a document location
// (documentLocationInCreatingWorkspace, not documentLocation — that key
// name is specific to the plain IssueSummary/errorSummaries case).

public struct XCResultSummary: Codable, Sendable {
    public let actions: [XCResultAction]?
}

public struct XCResultAction: Codable, Sendable {
    public let actionResult: XCResultActionResult?
}

public struct XCResultActionResult: Codable, Sendable {
    public let issues: XCResultIssues?
}

public struct XCResultIssues: Codable, Sendable {
    public let errorSummaries: [XCResultIssueSummary]?
    public let testFailureSummaries: [XCResultTestFailureSummary]?
}

public struct XCResultIssueSummary: Codable, Sendable {
    public let message: String?
    public let documentLocation: XCResultDocumentLocation?
}

public struct XCResultTestFailureSummary: Codable, Sendable {
    public let message: String?
    public let testCaseName: String?
    public let documentLocationInCreatingWorkspace: XCResultDocumentLocation?
}

public struct XCResultDocumentLocation: Codable, Sendable {
    public let url: String?
}
