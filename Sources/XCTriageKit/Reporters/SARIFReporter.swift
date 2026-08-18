import Foundation

// SARIF 2.1.0 output (https://docs.oasis-open.org/sarif/sarif/v2.1.0/),
// so a failure can be uploaded as a native code-scanning result (GitHub's
// Security tab, or any other SARIF consumer) instead of only living in
// xctriage's own terminal/JSON/Slack output.
public struct SARIFReporter: Sendable {

    // Mirrors XCTriage.configuration.version in Sources/xctriage/main.swift --
    // keep the two in sync when the CLI version changes.
    private static let toolVersion = "1.4.1"
    private static let informationUri = "https://github.com/gerardrecinto/xctriage"
    private static let fingerprintKey = "xctriageFingerprint/v1"

    private let write: @Sendable (String) -> Void

    public init(write: @escaping @Sendable (String) -> Void = { print($0) }) {
        self.write = write
    }

    public func report(_ triage: TriageReport) throws {
        let c = triage.classification

        let results = c.failureSites.map {
            result(for: $0, category: c.category, confidence: c.confidence)
        }

        let driver: [String: Any] = [
            "name": "xctriage",
            "version": Self.toolVersion,
            "informationUri": Self.informationUri,
        ]

        let run: [String: Any] = [
            "tool": ["driver": driver] as [String: Any],
            "results": results,
        ]

        let sarif: [String: Any] = [
            "$schema": "https://raw.githubusercontent.com/oasis-tcs/sarif-spec/main/Schemata/sarif-schema-2.1.0.json",
            "version": "2.1.0",
            "runs": [run],
        ]

        let data = try JSONSerialization.data(withJSONObject: sarif, options: [.prettyPrinted, .sortedKeys])
        write(String(data: data, encoding: .utf8) ?? "{}")
    }

    private func result(for site: FailureSite, category: FailureCategory, confidence: Double) -> [String: Any] {
        // A per-site fingerprint (not one shared across the whole report) so
        // two distinct failures in the same run don't collide under a
        // single identity -- FailureFingerprint only looks at its first
        // failure site, so it's fed exactly one here.
        let fingerprint = FailureFingerprint(category: category, failureSites: [site])

        var obj: [String: Any] = [
            "ruleId": FailureCategoryMapping.ruleID(for: category),
            "level": FailureCategoryMapping.severity(for: category, confidence: confidence).rawValue,
            "message": ["text": site.errorMessage] as [String: Any],
            "partialFingerprints": [Self.fingerprintKey: fingerprint.value],
            "properties": ["confidence": confidence] as [String: Any],
        ]

        if let location = physicalLocation(for: site) {
            obj["locations"] = [["physicalLocation": location]]
        }

        return obj
    }

    // Never fabricates line 1 / col 1 -- omits the whole `locations` array
    // when there's no real file, and omits `region` when there's a file but
    // no known line/column for it.
    private func physicalLocation(for site: FailureSite) -> [String: Any]? {
        guard let file = site.file else { return nil }

        var location: [String: Any] = [
            "artifactLocation": ["uri": file] as [String: Any],
        ]

        var region: [String: Any] = [:]
        if let line = site.line { region["startLine"] = line }
        if let column = site.column { region["startColumn"] = column }
        if !region.isEmpty { location["region"] = region }

        return location
    }
}
