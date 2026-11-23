import Foundation

public struct BatchEntry: Sendable, Codable, Equatable {
    public let name: String
    public let category: String
    public let confidence: Double
    public let classified: Bool
}

public struct BatchSummary: Sendable, Codable, Equatable {
    public let logs: Int
    public let classified: Int
    public let unreadable: [String]
    public let byCategory: [String: Int]
    public let unclassified: [String]

    /// Share of readable logs the rules classified with enough confidence, 0 to 1.
    public var coverage: Double {
        let readable = logs - unreadable.count
        return readable == 0 ? 0 : Double(classified) / Double(readable)
    }
}

/// Runs the rule classifier over a folder of logs so a team can see how much of
/// its own failure history the rules cover before it relies on them. It never
/// calls Claude and never writes the flaky database.
public enum BatchTriage {
    public static func listLogs(in directory: String) throws -> [String] {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: directory, isDirectory: &isDirectory) else {
            throw TriageError.fileNotFound(directory)
        }
        guard isDirectory.boolValue else { throw TriageError.notAFile(directory) }
        let names = try FileManager.default.contentsOfDirectory(atPath: directory)
        return names
            .filter { $0.hasSuffix(".log") || $0.hasSuffix(".txt") }
            .sorted()
            .map { (directory as NSString).appendingPathComponent($0) }
    }

    public static func classify(name: String, text: String, threshold: Double) -> BatchEntry {
        let parser = BuildLogParser()
        let context = parser.extractFailureContext(parser.parse(text))
        let result = RuleClassifier().classify(context)
        let ok = result.category != .unknown && result.confidence >= threshold
        return BatchEntry(name: name, category: result.category.rawValue, confidence: result.confidence, classified: ok)
    }

    public static func run(paths: [String], threshold: Double) -> BatchSummary {
        var entries: [BatchEntry] = []
        var unreadable: [String] = []
        for path in paths {
            let name = (path as NSString).lastPathComponent
            do {
                entries.append(classify(name: name, text: try LogFile.read(path), threshold: threshold))
            } catch {
                unreadable.append(name)
            }
        }
        var counts: [String: Int] = [:]
        for e in entries where e.classified { counts[e.category, default: 0] += 1 }
        return BatchSummary(
            logs: paths.count,
            classified: entries.filter(\.classified).count,
            unreadable: unreadable,
            byCategory: counts,
            unclassified: entries.filter { !$0.classified }.map(\.name)
        )
    }

    public static func render(_ s: BatchSummary, threshold: Double) -> String {
        var out = [String(format: "Logs: %d   classified: %d (%.0f%%) at confidence %.2f or more   unclassified: %d   unreadable: %d",
                          s.logs, s.classified, s.coverage * 100, threshold, s.unclassified.count, s.unreadable.count)]
        for (category, n) in s.byCategory.sorted(by: { $0.value != $1.value ? $0.value > $1.value : $0.key < $1.key }) {
            out.append("  \(category.padding(toLength: 20, withPad: " ", startingAt: 0)) \(n)")
        }
        if !s.unclassified.isEmpty {
            out.append("\nNot classified (no rule matched. A passing build belongs here; a real failure means a rule is missing):")
            out += s.unclassified.map { "  \($0)" }
        }
        if !s.unreadable.isEmpty {
            out.append("\nCould not read:")
            out += s.unreadable.map { "  \($0)" }
        }
        return out.joined(separator: "\n")
    }

    public static func json(_ s: BatchSummary) throws -> String {
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        return String(decoding: try enc.encode(s), as: UTF8.self)
    }
}
