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
                sh '''
                    swift test --enable-code-coverage 2>&1 | tee test.log
                    # Export JUnit XML for Jenkins test reporter
                    xcrun xcresulttool get \
                        --format json \
                        --path .build/debug/*.xcresult \
                        > xcresult_summary.json 2>/dev/null || true
                '''
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
                failure {
                    sh '''
                        .build/release/xctriage analyze test.log \
                            --source xcodebuild \
                            --build-id "${BUILD_TAG}" \
                            --llm \
                            --output slack
                    '''
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
