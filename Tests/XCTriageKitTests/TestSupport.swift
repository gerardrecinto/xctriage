import Foundation

func makeTempDBPath() -> String {
    NSTemporaryDirectory() + "xctriage-test-\(UUID().uuidString).db"
}

// Thread-safe string accumulator for reporters' injectable `write` closure.
// Deliberately not OS-level stdout redirection: a prior version of this file
// used dup2(STDOUT_FILENO) to capture print() output, which raced with
// swift-test's own stdout-based test reporting for concurrently-scheduled
// async tests and intermittently hung the whole suite. Dependency-injecting
// the sink is both safer and simpler.
final class OutputCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var lines: [String] = []

    func write(_ line: String) {
        lock.lock()
        lines.append(line)
        lock.unlock()
    }

    var joined: String {
        lock.lock()
        defer { lock.unlock() }
        return lines.joined(separator: "\n")
    }
}
