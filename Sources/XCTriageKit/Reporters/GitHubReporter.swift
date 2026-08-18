import Foundation

// GitHub Actions workflow-command annotations
// (https://docs.github.com/actions/using-workflows/workflow-commands-for-github-actions#setting-an-error-message),
// one `::error file=...,line=...,col=...::message` / `::warning ...::` line
// per failure site. Zero network access, zero LLM -- pure formatting over
// TriageReport/FailureSite, same contract as JSONReporter.
public struct GitHubReporter: Sendable {

    private let write: @Sendable (String) -> Void

    public init(write: @escaping @Sendable (String) -> Void = { print($0) }) {
        self.write = write
    }

    public func report(_ triage: TriageReport) {
        let c = triage.classification
        for site in c.failureSites {
            write(annotation(for: site, category: c.category, confidence: c.confidence))
        }
    }

    private func annotation(for site: FailureSite, category: FailureCategory, confidence: Double) -> String {
        let command = FailureCategoryMapping.severity(for: category, confidence: confidence).githubCommand

        var params: [String] = []
        if let file = site.file { params.append("file=\(escapeProperty(file))") }
        if let line = site.line { params.append("line=\(line)") }
        if let column = site.column { params.append("col=\(column)") }

        let message = escapeData(site.errorMessage)
        guard !params.isEmpty else {
            return "::\(command)::\(message)"
        }
        return "::\(command) \(params.joined(separator: ","))::\(message)"
    }

    // GitHub's documented workflow-command escaping for the message body.
    private func escapeData(_ text: String) -> String {
        text
            .replacingOccurrences(of: "%", with: "%25")
            .replacingOccurrences(of: "\r", with: "%0D")
            .replacingOccurrences(of: "\n", with: "%0A")
    }

    // Same as escapeData, plus `:`/`,` since those delimit property=value
    // pairs in the command itself.
    private func escapeProperty(_ text: String) -> String {
        escapeData(text)
            .replacingOccurrences(of: ":", with: "%3A")
            .replacingOccurrences(of: ",", with: "%2C")
    }
}
