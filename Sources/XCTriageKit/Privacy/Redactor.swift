import Foundation

// Deterministic secret/PII redaction, applied at the boundary between local
// processing and anything leaving the machine (the Claude API call in
// ClaudeClassifier). Never used to sanitize PatchGenerator's file contents:
// a patch has to match the real source byte-for-byte or `git apply` in
// SandboxValidator rejects it, so that path stays out of scope here — see
// the `xctriage redact` / `--redact` docs in the README for that boundary.
public struct RedactionRule: Sendable {
    public let category: String
    public let pattern: String
    public let template: String   // NSRegularExpression replacement template ($1, $2, ...)
    public let options: NSRegularExpression.Options

    public init(category: String, pattern: String, template: String, options: NSRegularExpression.Options = []) {
        self.category = category
        self.pattern = pattern
        self.template = template
        self.options = options
    }
}

public struct RedactionMatch: Sendable, Equatable {
    public let category: String
    public let count: Int
}

public struct RedactionResult: Sendable {
    public let redactedText: String
    public let matches: [RedactionMatch]   // only categories that actually fired, in rule order

    public var totalRedactions: Int { matches.reduce(0) { $0 + $1.count } }

    public var reportLines: [String] {
        matches.map { "\($0.category): \($0.count)" }
    }
}

public struct Redactor: Sendable {

    // Order matters: specific/high-signal patterns run before broader ones
    // so a token gets tagged with its real category instead of falling
    // through to a generic catch-all further down the list.
    public static let defaultRules: [RedactionRule] = [
        RedactionRule(
            category: "private-key",
            pattern: #"-----BEGIN [A-Z ]*PRIVATE KEY-----[\s\S]+?-----END [A-Z ]*PRIVATE KEY-----"#,
            template: "[REDACTED:private-key]"
        ),
        RedactionRule(
            category: "jwt",
            pattern: #"eyJ[A-Za-z0-9_-]{10,}\.[A-Za-z0-9_-]{10,}\.[A-Za-z0-9_-]{10,}"#,
            template: "[REDACTED:jwt]"
        ),
        RedactionRule(
            category: "github-token",
            pattern: #"(?:ghp|gho|ghu|ghs|ghr)_[A-Za-z0-9]{20,255}|github_pat_[A-Za-z0-9_]{20,255}"#,
            template: "[REDACTED:github-token]"
        ),
        RedactionRule(
            category: "anthropic-key",
            pattern: #"sk-ant-[A-Za-z0-9\-_]{10,}"#,
            template: "[REDACTED:anthropic-key]"
        ),
        RedactionRule(
            category: "openai-key",
            pattern: #"sk-[A-Za-z0-9]{20,}"#,
            template: "[REDACTED:openai-key]"
        ),
        RedactionRule(
            category: "slack-token",
            pattern: #"xox[baprs]-[A-Za-z0-9\-]{10,}"#,
            template: "[REDACTED:slack-token]"
        ),
        RedactionRule(
            category: "aws-access-key",
            pattern: #"AKIA[0-9A-Z]{16}"#,
            template: "[REDACTED:aws-access-key]"
        ),
        RedactionRule(
            category: "bearer-token",
            pattern: #"(?i)bearer\s+[A-Za-z0-9\-._~+/]{8,}=*"#,
            template: "Bearer [REDACTED:bearer-token]"
        ),
        RedactionRule(
            category: "credentials-in-url",
            pattern: #"://[^/\s:@]+:[^/\s@]+@"#,
            template: "://[REDACTED:credentials]@"
        ),
        // CI logs regularly dump environment blocks (`-showBuildSettings`, `env`,
        // Jenkins `printenv`) with arbitrarily-named secrets that don't match any
        // known vendor format above. Catch KEY=value / KEY: value pairs where the
        // key name itself signals a secret, regardless of the value's shape.
        RedactionRule(
            category: "credential-assignment",
            pattern: #"(?i)([A-Z0-9_]*(?:API|SECRET|TOKEN|PASSWORD|PASSWD|PWD|CREDENTIAL)[A-Z0-9_]*)\s*[:=]\s*['"]?[A-Za-z0-9\-_/+.=]{8,}['"]?"#,
            template: "$1=[REDACTED:credential]"
        ),
        RedactionRule(
            category: "home-path",
            pattern: #"/Users/[^/\s"']+|/home/[^/\s"']+"#,
            template: "[REDACTED:home-path]"
        ),
        RedactionRule(
            category: "email",
            pattern: #"[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}"#,
            template: "[REDACTED:email]"
        ),
    ]

    private let rules: [RedactionRule]

    public init(rules: [RedactionRule]? = nil, redactEmails: Bool = true) {
        let resolved = rules ?? Self.defaultRules
        self.rules = redactEmails ? resolved : resolved.filter { $0.category != "email" }
    }

    public func redact(_ text: String) -> RedactionResult {
        var current = text
        var matches: [RedactionMatch] = []

        for rule in rules {
            guard let regex = try? NSRegularExpression(pattern: rule.pattern, options: rule.options) else { continue }
            let range = NSRange(current.startIndex..., in: current)
            let count = regex.numberOfMatches(in: current, range: range)
            guard count > 0 else { continue }
            current = regex.stringByReplacingMatches(in: current, range: range, withTemplate: rule.template)
            matches.append(RedactionMatch(category: rule.category, count: count))
        }

        return RedactionResult(redactedText: current, matches: matches)
    }
}
