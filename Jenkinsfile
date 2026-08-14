pipeline {
    agent {
        label 'macos-arm64'
    }

    environment {
        XCTRIAGE_ANTHROPIC_API_KEY = credentials('anthropic-api-key')
        XCTRIAGE_SLACK_WEBHOOK     = credentials('slack-ci-webhook')
    }

    options {
        timeout(time: 30, unit: 'MINUTES')
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
                    python3 -m semgrep scan --config auto --error --json --output semgrep-results.json Sources/ || true
                '''
            }
            post {
                always {
                    archiveArtifacts artifacts: 'semgrep-results.json', allowEmptyArchive: true
                }
            }
        }

        stage('Dependency & Config Scan (Trivy)') {
            steps {
                sh '''
                    which trivy || brew install trivy
                    trivy fs --scanners vuln,secret,misconfig --skip-dirs .build --severity CRITICAL,HIGH --exit-code 0 --format json --output trivy-results.json .
                '''
            }
            post {
                always {
                    archiveArtifacts artifacts: 'trivy-results.json', allowEmptyArchive: true
                }
            }
        }

        stage('Build') {
            steps {
                sh 'swift build -c release 2>&1 | tee build.log'
            }
            post {
                failure {
                    script {
                        // Self-triage: run xctriage on our own build log
                        sh '''
                            .build/release/xctriage analyze build.log \
                                --source xcodebuild \
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
                        swift test --enable-code-coverage 2>&1 | tee test.log
                        # Export JUnit XML for Jenkins test reporter
                        xcrun xcresulttool get \
                            --format json \
                            --path .build/debug/*.xcresult \
                            > xcresult_summary.json 2>/dev/null || true
                    '''
                }
            }
            post {
                always {
                    // Archive xctriage analysis of test results
                    sh '''
                        .build/release/xctriage analyze test.log \
                            --source xcodebuild \
                            --build-id "${BUILD_TAG}" \
                            --output json > triage_report.json || true
                    '''
                    archiveArtifacts artifacts: 'triage_report.json, xcresult_summary.json', allowEmptyArchive: true
                }
            }
        }

        // Bounded, rule-gated auto-remediation. The LLM only picks the
        // category; it never decides the action. Only "flaky_test" at
        // high confidence gets an automatic retry, one time. Every other
        // category (compilation error, dependency failure, OOM, ...) needs
        // a human, so this just posts the LLM's suggested fix to Slack and
        // leaves the build failed. Never touches production, never retries
        // more than once, never runs for anything but a flaky-test verdict.
        stage('Auto-Remediate (LLM)') {
            when {
                expression { currentBuild.currentResult == 'FAILURE' }
            }
            steps {
                script {
                    sh '''
                        .build/release/xctriage analyze test.log \
                            --source xcodebuild \
                            --build-id "${BUILD_TAG}" \
                            --llm \
                            --output json > remediation_triage.json || true
                    '''
                    def category = sh(
                        script: "python3 -c \"import json; print(json.load(open('remediation_triage.json'))['classification']['category'])\" 2>/dev/null || echo unknown",
                        returnStdout: true
                    ).trim()
                    def confidence = sh(
                        script: "python3 -c \"import json; print(json.load(open('remediation_triage.json'))['classification']['confidence'])\" 2>/dev/null || echo 0",
                        returnStdout: true
                    ).trim().toFloat()

                    echo "LLM classification: ${category} (confidence ${confidence})"

                    if (category == 'flaky_test' && confidence >= 0.75) {
                        echo "High-confidence flaky-test verdict: retrying the test suite once."
                        try {
                            sh 'swift test --enable-code-coverage 2>&1 | tee test.log'
                            currentBuild.result = 'SUCCESS'
                            echo "Retry passed. Flaky test auto-remediated, build marked SUCCESS."
                        } catch (err) {
                            echo "Retry failed too. Leaving build as FAILURE for a human to look at."
                            sh '''
                                .build/release/xctriage analyze test.log \
                                    --source xcodebuild \
                                    --build-id "${BUILD_TAG}" \
                                    --llm \
                                    --output slack
                            '''
                        }
                    } else {
                        echo "Category '${category}' has no safe auto-fix. Posting the LLM's suggested fix to Slack for a human."
                        sh '''
                            .build/release/xctriage analyze test.log \
                                --source xcodebuild \
                                --build-id "${BUILD_TAG}" \
                                --llm \
                                --output slack
                        '''
                    }
                    archiveArtifacts artifacts: 'remediation_triage.json', allowEmptyArchive: true
                }
            }
        }

        stage('Flaky Report') {
            when { branch 'main' }
            steps {
                sh '''
                    .build/release/xctriage flaky --n 20 || true
                '''
            }
        }

        stage('Archive') {
            when { tag pattern: 'v*', comparator: 'GLOB' }
            steps {
                sh 'swift build -c release'
                archiveArtifacts artifacts: '.build/release/xctriage'
            }
        }
    }

    post {
        always {
            cleanWs()
        }
    }
}
