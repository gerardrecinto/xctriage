import Foundation

// Parses xcodebuild console output (not xcresult: use XCResultParser for bundles)
public struct BuildLogParser: Sendable {

    // Swift/ObjC compiler errors: /path/File.swift:42:17: error: message
    // Using NSRegularExpression for multiline + case-insensitive support
    private static let swiftErrorRE = try! NSRegularExpression(
        pattern: #"^(.+\.(?:swift|m|mm|c|cpp|h)):(\d+):(\d+):\s+(error|warning|note):\s+(.+)$"#)

    private static let testPassRE = try! NSRegularExpression(
        pattern: #"Test Case '(.+?)' passed \([0-9.]+ seconds\)"#)

    private static let testFailRE = try! NSRegularExpression(
        pattern: #"Test Case '(.+?)' failed \(([0-9.]+) seconds\)"#)

    private static let buildResultRE = try! NSRegularExpression(
        pattern: #"\*\* (BUILD|TEST) (SUCCEEDED|FAILED) \*\*"#)

    private static let linkerErrorRE = try! NSRegularExpression(
        pattern: #"^ld: (.+)"#)

    private static let genericErrorRE = try! NSRegularExpression(
        pattern: #"(?i)^error:\s+(.+)"#)

    // Swift runtime trap, printed by the stdlib as `file:line: Fatal error: message`
    // (also covers `Precondition failed:` / `Assertion failed:`, same shape).
    private static let fatalErrorRE = try! NSRegularExpression(
        pattern: #"^(.+\.swift):(\d+): (?:Fatal error|Precondition failed|Assertion failed):\s*(.+)$"#)

    // Fatal OS signal / sanitizer report with no file:line to key on — this
    // is what actually appears on the console when a process dies mid-test,
    // often with no "Test Case ... failed" line at all.
    private static let crashSignalRE = try! NSRegularExpression(
        pattern: #"(?i)(EXC_BAD_ACCESS|EXC_BREAKPOINT|EXC_CRASH|signal SIGABRT|signal SIGSEGV|signal SIGILL"#
            + #"|libc\+\+abi|AddressSanitizer:|ThreadSanitizer:|UndefinedBehaviorSanitizer:)"#)

    public init() {}

    public func parse(_ logText: String) -> [LogEntry] {
        var entries: [LogEntry] = []
        let lines = logText.components(separatedBy: "\n")
        for (i, raw) in lines.enumerated() {
            let level = detectLevel(raw)
            let message = raw.trimmingCharacters(in: .whitespaces)
            entries.append(LogEntry(lineNumber: i + 1, level: level, message: message, raw: raw))
        }
        return entries
    }

    private func detectLevel(_ line: String) -> LogLevel? {
        let range = NSRange(line.startIndex..., in: line)
        if let m = Self.swiftErrorRE.firstMatch(in: line, range: range) {
            let severityRange = Range(m.range(at: 4), in: line)
            let severity = severityRange.map { String(line[$0]) } ?? ""
            switch severity {
            case "error":   return .error
            case "warning": return .warning
            case "note":    return .note
            default:        break
            }
        }
        if let m = Self.buildResultRE.firstMatch(in: line, range: range) {
            let resultRange = Range(m.range(at: 2), in: line)
            let result = resultRange.map { String(line[$0]) } ?? ""
            return result == "FAILED" ? .error : .info
        }
        if Self.linkerErrorRE.firstMatch(in: line, range: range) != nil { return .error }
        if Self.genericErrorRE.firstMatch(in: line, range: range) != nil { return .error }
        if Self.testFailRE.firstMatch(in: line, range: range) != nil { return .error }
        if Self.fatalErrorRE.firstMatch(in: line, range: range) != nil { return .error }
        if Self.crashSignalRE.firstMatch(in: line, range: range) != nil { return .error }
        return nil
    }

    public func extractFailureContext(_ entries: [LogEntry]) -> [LogEntry] {
        let failIdx = entries.firstIndex { entry in
            let r = NSRange(entry.message.startIndex..., in: entry.message)
            guard let m = Self.buildResultRE.firstMatch(in: entry.message, range: r) else { return false }
            let resultRange = Range(m.range(at: 2), in: entry.message)
            return resultRange.map { entry.message[$0] == "FAILED" } ?? false
        }
        guard let idx = failIdx else {
            return entries.filter { $0.level == .error }
        }
        return entries[..<idx].filter { $0.level == .error || $0.level == .warning }
    }

    public func extractFailureSites(_ entries: [LogEntry]) -> [FailureSite] {
        var sites: [FailureSite] = []
        var seen: Set<String> = []

        for entry in entries {
            let raw = entry.raw
            let rawRange = NSRange(raw.startIndex..., in: raw)
            let msgRange = NSRange(entry.message.startIndex..., in: entry.message)

            // Swift/ObjC compiler error
            if let m = Self.swiftErrorRE.firstMatch(in: raw, range: rawRange) {
                let sev = strAt(raw, m.range(at: 4))
                guard sev == "error" else { continue }
                let file = strAt(raw, m.range(at: 1))
                let line = intAt(raw, m.range(at: 2))
                let col  = intAt(raw, m.range(at: 3))
                let msg  = strAt(raw, m.range(at: 5))
                let key  = "\(file ?? ""):\(line ?? 0)"
                if seen.insert(key).inserted {
                    sites.append(FailureSite(file: file, line: line, column: col,
                                             testName: nil, errorMessage: msg ?? ""))
                }
                continue
            }
            // XCTest failure. Dedup on test name, not the full line: a test
            // retried via `xcodebuild -retry-tests-on-failure` logs its own
            // "Test Case '...' failed" line once per attempt, each with a
            // different duration, for what's still one failure to triage.
            if let m = Self.testFailRE.firstMatch(in: entry.message, range: msgRange) {
                let name = strAt(entry.message, m.range(at: 1))
                let dur  = strAt(entry.message, m.range(at: 2))
                let key  = "test:\(name ?? "")"
                if seen.insert(key).inserted {
                    sites.append(FailureSite(file: nil, line: nil, column: nil,
                                             testName: name, errorMessage: "failed in \(dur ?? "?")s"))
                }
                continue
            }
            // Linker error. No file/line to key on, so dedup on the message
            // itself — a repeated identical `ld:` line (echoed via `tee`, or
            // the linker itself repeating a summary line) would otherwise
            // produce one duplicate FailureSite per repetition.
            if let m = Self.linkerErrorRE.firstMatch(in: entry.message, range: msgRange) {
                let msg = strAt(entry.message, m.range(at: 1))
                let key = "linker:\(msg ?? "")"
                if seen.insert(key).inserted {
                    sites.append(FailureSite(file: nil, line: nil, column: nil,
                                             testName: nil, errorMessage: "linker: \(msg ?? "")"))
                }
                continue
            }
            // Swift runtime trap with a file:line the stdlib printed itself
            // (`file.swift:N: Fatal error: message`) — dedup on file:line,
            // same as the compiler-error branch above.
            if let m = Self.fatalErrorRE.firstMatch(in: raw, range: rawRange) {
                let file = strAt(raw, m.range(at: 1))
                let line = intAt(raw, m.range(at: 2))
                let msg  = strAt(raw, m.range(at: 3))
                let key  = "crash:\(file ?? ""):\(line ?? 0)"
                if seen.insert(key).inserted {
                    sites.append(FailureSite(file: file, line: line, column: nil,
                                             testName: nil, errorMessage: msg ?? ""))
                }
                continue
            }
            // Fatal OS signal / sanitizer line with no file:line available.
            // Dedup on the message itself, same reasoning as the linker branch.
            if let m = Self.crashSignalRE.firstMatch(in: entry.message, range: msgRange) {
                let msg = strAt(entry.message, m.range(at: 0))
                let key = "signal:\(entry.message)"
                if seen.insert(key).inserted {
                    sites.append(FailureSite(file: nil, line: nil, column: nil,
                                             testName: nil, errorMessage: msg ?? entry.message))
                }
            }
        }
        return sites
    }

    // MARK: Helpers

    private func strAt(_ s: String, _ range: NSRange) -> String? {
        guard let r = Range(range, in: s) else { return nil }
        return String(s[r])
    }

    private func intAt(_ s: String, _ range: NSRange) -> Int? {
        guard let str = strAt(s, range) else { return nil }
        return Int(str)
    }
}
