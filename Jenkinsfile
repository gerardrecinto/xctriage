// Controller-level overrides (Jenkins global/folder/job env vars), not build
// parameters: these pick *where* and *as whom* the pipeline runs, so they
// must not be settable by whoever triggers a build. Build parameters below
// are for values that are safe for a build submitter to choose.
def AGENT_LABEL              = env.XCTRIAGE_AGENT_LABEL ?: 'macos-arm64'
def BUILD_TIMEOUT_MINUTES    = (env.XCTRIAGE_BUILD_TIMEOUT_MINUTES ?: '30').toInteger()
def ANTHROPIC_CREDENTIAL_ID  = env.XCTRIAGE_ANTHROPIC_CREDENTIAL_ID ?: 'anthropic-api-key'
def SLACK_CREDENTIAL_ID      = env.XCTRIAGE_SLACK_CREDENTIAL_ID ?: 'slack-ci-webhook'

pipeline {
    agent {
        label AGENT_LABEL
    }

    parameters {
        string(name: 'FLAKY_CONFIDENCE_THRESHOLD', defaultValue: '0.75',
               description: 'Minimum LLM confidence to auto-retry a flaky_test verdict once')
        string(name: 'FLAKY_REPORT_COUNT', defaultValue: '20',
               description: 'Top-N flaky tests to show in the Flaky Report stage')
        string(name: 'TRIVY_SEVERITY', defaultValue: 'CRITICAL,HIGH',
               description: 'Comma-separated severities Trivy scans for')
    }

    environment {
        XCTRIAGE_ANTHROPIC_API_KEY = credentials(ANTHROPIC_CREDENTIAL_ID)
        XCTRIAGE_SLACK_WEBHOOK     = credentials(SLACK_CREDENTIAL_ID)

        XCTRIAGE_BIN           = '.build/release/xctriage'
        CI_SOURCE              = 'xcodebuild'
        BUILD_LOG              = 'build.log'
        TEST_LOG               = 'test.log'
        XCRESULT_SUMMARY_JSON  = 'xcresult_summary.json'
        TRIAGE_REPORT_JSON     = 'triage_report.json'
        REMEDIATION_JSON       = 'remediation_triage.json'
        SEMGREP_RESULTS_JSON   = 'semgrep-results.json'
        TRIVY_RESULTS_JSON     = 'trivy-results.json'

        FLAKY_CONFIDENCE_THRESHOLD = "${params.FLAKY_CONFIDENCE_THRESHOLD}"
        FLAKY_REPORT_COUNT         = "${params.FLAKY_REPORT_COUNT}"
        TRIVY_SEVERITY              = "${params.TRIVY_SEVERITY}"
    }

    options {
        timeout(time: BUILD_TIMEOUT_MINUTES, unit: 'MINUTES')
        timestamps()
    }

    stages {
        stage('Resolve') {
            steps {
                sh 'swift package resolve'
            }
        }

        stage('Lint') {
            steps {
                sh '''
                    which swiftlint || brew install swiftlint
                    swiftlint lint --quiet
                '''
            }
        }

        // SAST. GitHub Actions runs CodeQL (requires GHAS/GH-hosted); Jenkins
        // runs Semgrep instead since it needs no GitHub-side license to
        // self-host in a pipeline. Both cover the same "catch it before merge"
        // goal for the two CI systems this repo demonstrates.
        stage('SAST (Semgrep)') {
            steps {
                sh '''
                    python3 -m pip install --quiet --user semgrep || true
                    python3 -m semgrep scan --config auto --error --json --output "${SEMGREP_RESULTS_JSON}" Sources/ || true
                '''
            }
            post {
                always {
                    archiveArtifacts artifacts: "${SEMGREP_RESULTS_JSON}", allowEmptyArchive: true
                }
            }
        }

        stage('Dependency & Config Scan (Trivy)') {
            steps {
                sh '''
                    which trivy || brew install trivy
                    trivy fs --scanners vuln,secret,misconfig --skip-dirs .build \
                        --severity "${TRIVY_SEVERITY}" --exit-code 0 \
                        --format json --output "${TRIVY_RESULTS_JSON}" .
                '''
            }
            post {
                always {
                    archiveArtifacts artifacts: "${TRIVY_RESULTS_JSON}", allowEmptyArchive: true
                }
            }
        }

        stage('Build') {
            steps {
                sh 'swift build -c release 2>&1 | tee "${BUILD_LOG}"'
            }
            post {
                failure {
                    script {
                        // Self-triage: run xctriage on our own build log
                        sh '''
                            "${XCTRIAGE_BIN}" analyze "${BUILD_LOG}" \
                                --source "${CI_SOURCE}" \
                                --build-id "${BUILD_TAG}" \
                                --llm \
                                --output slack
                        '''
                    }
                }
            }
        }

        stage('Test') {
            steps {
                // catchError lets the pipeline reach Auto-Remediate instead of
                // aborting outright on failure; the stage/build still report
                // FAILURE unless Auto-Remediate clears it after a successful retry.
                catchError(buildResult: 'FAILURE', stageResult: 'FAILURE') {
                    sh '''
                        swift test --enable-code-coverage 2>&1 | tee "${TEST_LOG}"
                        # Export JUnit XML for Jenkins test reporter
                        xcrun xcresulttool get \
                            --format json \
                            --path .build/debug/*.xcresult \
                            > "${XCRESULT_SUMMARY_JSON}" 2>/dev/null || true
                    '''
                }
            }
            post {
                always {
                    // Archive xctriage analysis of test results
                    sh '''
                        "${XCTRIAGE_BIN}" analyze "${TEST_LOG}" \
                            --source "${CI_SOURCE}" \
                            --build-id "${BUILD_TAG}" \
                            --output json > "${TRIAGE_REPORT_JSON}" || true
                    '''
                    archiveArtifacts artifacts: "${TRIAGE_REPORT_JSON}, ${XCRESULT_SUMMARY_JSON}", allowEmptyArchive: true
                }
            }
        }

        // Bounded, rule-gated auto-remediation. The LLM only picks the
        // category; it never decides the action. Only "flaky_test" at
        // FLAKY_CONFIDENCE_THRESHOLD or higher gets an automatic retry, one
        // time. Every other category (compilation error, dependency failure,
        // OOM, ...) needs a human, so this just posts the LLM's suggested
        // fix to Slack and leaves the build failed. Never touches
        // production, never retries more than once, never runs for anything
        // but a flaky-test verdict.
        stage('Auto-Remediate (LLM)') {
            when {
                expression { currentBuild.currentResult == 'FAILURE' }
            }
            steps {
                script {
                    sh '''
                        "${XCTRIAGE_BIN}" analyze "${TEST_LOG}" \
                            --source "${CI_SOURCE}" \
                            --build-id "${BUILD_TAG}" \
                            --llm \
                            --output json > "${REMEDIATION_JSON}" || true
                    '''
                    def category = sh(
                        script: "python3 -c \"import json,os; print(json.load(open(os.environ['REMEDIATION_JSON']))['classification']['category'])\" 2>/dev/null || echo unknown",
                        returnStdout: true
                    ).trim()
                    def confidence = sh(
                        script: "python3 -c \"import json,os; print(json.load(open(os.environ['REMEDIATION_JSON']))['classification']['confidence'])\" 2>/dev/null || echo 0",
                        returnStdout: true
                    ).trim().toFloat()
                    def threshold = env.FLAKY_CONFIDENCE_THRESHOLD.toFloat()

                    echo "LLM classification: ${category} (confidence ${confidence}, threshold ${threshold})"

                    if (category == 'flaky_test' && confidence >= threshold) {
                        echo "High-confidence flaky-test verdict: retrying the test suite once."
                        try {
                            sh 'swift test --enable-code-coverage 2>&1 | tee "${TEST_LOG}"'
                            currentBuild.result = 'SUCCESS'
                            echo "Retry passed. Flaky test auto-remediated, build marked SUCCESS."
                        } catch (err) {
                            echo "Retry failed too. Leaving build as FAILURE for a human to look at."
                            sh '''
                                "${XCTRIAGE_BIN}" analyze "${TEST_LOG}" \
                                    --source "${CI_SOURCE}" \
                                    --build-id "${BUILD_TAG}" \
                                    --llm \
                                    --output slack
                            '''
                        }
                    } else {
                        echo "Category '${category}' has no safe auto-fix. Posting the LLM's suggested fix to Slack for a human."
                        sh '''
                            "${XCTRIAGE_BIN}" analyze "${TEST_LOG}" \
                                --source "${CI_SOURCE}" \
                                --build-id "${BUILD_TAG}" \
                                --llm \
                                --output slack
                        '''
                    }
                    archiveArtifacts artifacts: "${REMEDIATION_JSON}", allowEmptyArchive: true
                }
            }
        }

        stage('Flaky Report') {
            when { branch 'main' }
            steps {
                sh '''
                    "${XCTRIAGE_BIN}" flaky --n "${FLAKY_REPORT_COUNT}" || true
                '''
            }
        }

        stage('Archive') {
            when { tag pattern: 'v*', comparator: 'GLOB' }
            steps {
                sh 'swift build -c release'
                archiveArtifacts artifacts: "${XCTRIAGE_BIN}"
            }
        }
    }

    post {
        always {
            cleanWs()
        }
    }
}
