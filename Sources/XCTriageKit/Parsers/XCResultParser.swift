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
        let json = try await run(
            arguments: ["xcresulttool", "get", "--format", "json", "--path", bundlePath]
        )
        let data = Data(json.utf8)
        return try JSONDecoder().decode(XCResultSummary.self, from: data)
    }

    // Returns all test failure sites extracted from the bundle
    public func testFailures(bundlePath: String) async throws -> [FailureSite] {
        let summary = try await summary(bundlePath: bundlePath)
        var sites: [FailureSite] = []

        for action in summary.actions ?? [] {
            guard let issues = action.actionResult?.buildResult?.issues else { continue }
            for error in issues.errors ?? [] {
                let msg = error.message?.value ?? "unknown error"
                let url = error.documentLocation?.url?.value
                let (file, line, col) = parseFileURL(url)
                sites.append(FailureSite(file: file, line: line, column: col, testName: nil, errorMessage: msg))
            }
        }
        return sites
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
    // silently returns nil for these — every failure site's file/line/column
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

// MARK: Codable types for xcresulttool JSON output

public struct XCResultSummary: Codable, Sendable {
    public let actions: [XCResultAction]?

    enum CodingKeys: String, CodingKey { case actions }
}

public struct XCResultAction: Codable, Sendable {
    public let actionResult: XCResultActionResult?
    enum CodingKeys: String, CodingKey { case actionResult }
}

public struct XCResultActionResult: Codable, Sendable {
    public let buildResult: XCResultBuildResult?
    enum CodingKeys: String, CodingKey { case buildResult }
}

public struct XCResultBuildResult: Codable, Sendable {
    public let issues: XCResultIssues?
    enum CodingKeys: String, CodingKey { case issues }
}

public struct XCResultIssues: Codable, Sendable {
    public let errors: [XCResultIssueSummary]?
    enum CodingKeys: String, CodingKey { case errors }
}

public struct XCResultIssueSummary: Codable, Sendable {
    public let message: XCResultValue?
    public let documentLocation: XCResultDocumentLocation?
    enum CodingKeys: String, CodingKey { case message, documentLocation }
}

public struct XCResultDocumentLocation: Codable, Sendable {
    public let url: XCResultValue?
    enum CodingKeys: String, CodingKey { case url }
}

public struct XCResultValue: Codable, Sendable {
    public let value: String?
    enum CodingKeys: String, CodingKey { case value = "_value" }
}
