import XCTest
@testable import XCTriageKit

final class RedactorTests: XCTestCase {

    var redactor: Redactor!

    override func setUp() {
        super.setUp()
        redactor = Redactor()
    }

    func test_redact_leavesCleanTextUntouched() {
        let text = "** BUILD SUCCEEDED **\nAll 12 tests passed."
        let result = redactor.redact(text)
        XCTAssertEqual(result.redactedText, text)
        XCTAssertTrue(result.matches.isEmpty)
        XCTAssertEqual(result.totalRedactions, 0)
    }

    func test_redact_githubToken() {
        let result = redactor.redact("Authorization: token ghp_ABCDEFGHIJ0123456789abcdefghij0123")
        XCTAssertTrue(result.redactedText.contains("[REDACTED:github-token]"))
        XCTAssertFalse(result.redactedText.contains("ghp_ABCDEFGHIJ0123456789abcdefghij0123"))
    }

    func test_redact_anthropicKeyNotCaughtByGenericOpenAIPattern() {
        let result = redactor.redact("XCTRIAGE_ANTHROPIC_API_KEY=sk-ant-api03-abcdefghijklmnopqrstuvwxyz")
        let categories = Set(result.matches.map(\.category))
        XCTAssertTrue(categories.contains("anthropic-key"))
        XCTAssertFalse(categories.contains("openai-key"))
        XCTAssertFalse(result.redactedText.contains("sk-ant-"))
    }

    func test_redact_openAIStyleKey() {
        let result = redactor.redact("OPENAI_API_KEY=sk-abcdefghijklmnopqrstuvwxyz0123456789")
        XCTAssertTrue(result.matches.contains { $0.category == "openai-key" })
    }

    func test_redact_awsAccessKey() {
        let result = redactor.redact("aws_access_key_id = AKIAABCDEFGHIJKLMNOP")
        XCTAssertTrue(result.redactedText.contains("[REDACTED:aws-access-key]"))
        XCTAssertFalse(result.redactedText.contains("AKIAABCDEFGHIJKLMNOP"))
    }

    func test_redact_slackToken() {
        let result = redactor.redact("XCTRIAGE_SLACK_WEBHOOK token: xoxb-1234567890-abcdefghij")
        XCTAssertTrue(result.redactedText.contains("[REDACTED:slack-token]"))
    }

    func test_redact_bearerToken() {
        let result = redactor.redact("curl -H \"Authorization: Bearer abcXYZ123.token-value_here\" https://api.example.com")
        XCTAssertTrue(result.redactedText.contains("Bearer [REDACTED:bearer-token]"))
    }

    func test_redact_credentialsInURL() {
        let result = redactor.redact("Cloning https://ci-bot:ghp_supersecrettoken123456789012345@github.com/org/repo.git")
        XCTAssertTrue(result.redactedText.contains("https://[REDACTED:credentials]@github.com"))
        XCTAssertFalse(result.redactedText.contains("ci-bot:ghp_"))
    }

    func test_redact_privateKeyBlock() {
        let key = """
        -----BEGIN RSA PRIVATE KEY-----
        MIIEowIBAAKCAQEAsomeBase64EncodedKeyMaterialGoesRightHere1234567
        -----END RSA PRIVATE KEY-----
        """
        let result = redactor.redact("deploy key:\n\(key)\ndone")
        XCTAssertTrue(result.redactedText.contains("[REDACTED:private-key]"))
        XCTAssertFalse(result.redactedText.contains("MIIEowIBAAKCAQEA"))
    }

    func test_redact_jwt() {
        let jwt = "eyJhbGciOiJIUzI1NiJ9.eyJzdWIiOiIxMjM0NTY3ODkwIn0.dGhpc2lzbm90YXJlYWxzaWc"
        let result = redactor.redact("session=\(jwt)")
        XCTAssertTrue(result.redactedText.contains("[REDACTED:jwt]"))
    }

    func test_redact_genericCredentialAssignment() {
        let result = redactor.redact("DATABASE_PASSWORD=Sup3rSecretValue!!")
        XCTAssertTrue(result.matches.contains { $0.category == "credential-assignment" })
        XCTAssertTrue(result.redactedText.contains("DATABASE_PASSWORD=[REDACTED:credential]"))
    }

    func test_redact_homePath() {
        let result = redactor.redact("Build agent home: /Users/ci-runner-42/Library/Developer/Xcode/DerivedData")
        XCTAssertTrue(result.redactedText.contains("[REDACTED:home-path]"))
        XCTAssertFalse(result.redactedText.contains("ci-runner-42"))
    }

    func test_redact_email() {
        let result = redactor.redact("Reported by jane.doe@example.com in the failure comment")
        XCTAssertTrue(result.redactedText.contains("[REDACTED:email]"))
    }

    func test_redact_canDisableEmailRedaction() {
        let noEmailRedactor = Redactor(redactEmails: false)
        let result = noEmailRedactor.redact("Reported by jane.doe@example.com")
        XCTAssertTrue(result.redactedText.contains("jane.doe@example.com"))
        XCTAssertFalse(result.matches.contains { $0.category == "email" })
    }

    func test_redact_countsMultipleOccurrencesOfSameCategory() {
        let result = redactor.redact("a@example.com and b@example.com and c@example.com")
        let emailMatch = result.matches.first { $0.category == "email" }
        XCTAssertEqual(emailMatch?.count, 3)
        XCTAssertEqual(result.totalRedactions, 3)
    }

    func test_redact_multipleCategoriesInOneLog() {
        let log = """
        error: simulator boot failed
        AWS_SECRET_ACCESS_KEY=wJalrXUtnFEMIK7MDENGbPxRfiCYEXAMPLEKEY
        contact devops@example.com
        home dir: /Users/buildbot/project
        """
        let result = redactor.redact(log)
        let categories = Set(result.matches.map(\.category))
        XCTAssertTrue(categories.isSuperset(of: ["credential-assignment", "email", "home-path"]))
    }
}
