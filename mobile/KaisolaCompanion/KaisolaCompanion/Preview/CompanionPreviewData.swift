import Foundation

enum CompanionPreviewData {
    @MainActor
    static func store(now: Date) -> CompanionStore {
        let nowMs = Int64(now.timeIntervalSince1970 * 1_000)
        let minute: Int64 = 60_000
        let projects = [
            CompanionProject(
                id: "project-kaisola",
                name: "Kaisola",
                repo: "Kaisola",
                branch: "feature/mobile-companion",
                connection: "live",
                lastContactAt: nowMs,
                counts: nil
            ),
            CompanionProject(
                id: "project-programbench",
                name: "ProgramBench",
                repo: "ProgramBench",
                branch: "main",
                connection: "live",
                lastContactAt: nowMs - 20_000,
                counts: nil
            ),
        ]

        let sessions = [
            CompanionSession(
                id: "session-codex",
                projectId: "project-kaisola",
                kind: .agent,
                title: "Build the iPhone companion",
                status: .running,
                boardLane: "running",
                needsYou: false,
                unread: false,
                updatedAt: nowMs - 8_000,
                provider: "Codex",
                model: "GPT-5",
                mode: "Agent",
                branch: "feature/mobile-companion",
                summary: "Creating the observe-only gateway and native Now screen",
                startedAt: nowMs - 18 * minute,
                turns: [
                    CompanionTurn(
                        role: .user,
                        text: "Build the companion so I can follow every agent from my phone.",
                        at: nowMs - 18 * minute
                    ),
                    CompanionTurn(
                        role: .thought,
                        text: "I’ll keep the Mac authoritative and start with a bounded, read-only stream.",
                        status: "complete",
                        at: nowMs - 17 * minute
                    ),
                    CompanionTurn(
                        role: .tool,
                        text: "57 protocol and terminal-observer tests passed.",
                        status: "passed",
                        at: nowMs - 8 * minute
                    ),
                    CompanionTurn(
                        role: .assistant,
                        text: "The desktop observation spine is live. I’m now shaping the one-column mobile control surface.",
                        status: "streaming",
                        at: nowMs - 20_000
                    ),
                ],
                terminalLines: nil
            ),
            CompanionSession(
                id: "session-review",
                projectId: "project-kaisola",
                kind: .agent,
                title: "Review terminal permissions",
                status: .waiting,
                boardLane: "waiting",
                needsYou: true,
                unread: true,
                updatedAt: nowMs - minute,
                provider: "Claude",
                model: "Claude",
                mode: "Default",
                branch: "feature/mobile-companion",
                summary: "Approval needed for one scoped file edit",
                startedAt: nowMs - 11 * minute,
                turns: [
                    CompanionTurn(role: .assistant, text: "I need approval to update the terminal subscription policy.", at: nowMs - minute),
                ],
                terminalLines: nil
            ),
            CompanionSession(
                id: "terminal-probe",
                projectId: "project-kaisola",
                kind: .terminal,
                title: "Broker continuity probe",
                status: .running,
                boardLane: "running",
                needsYou: false,
                unread: false,
                updatedAt: nowMs - 3_000,
                provider: "Terminal",
                model: nil,
                mode: "Read only",
                branch: "feature/mobile-companion",
                summary: "Verifying desktop and observer output agreement",
                startedAt: nowMs - 4 * minute,
                turns: nil,
                terminalLines: [
                    "$ npm run broker:probe",
                    "same broker pid ............ PASS",
                    "observer output ordered .... PASS",
                    "cursor resume .............. PASS",
                    "desktop ownership unchanged  PASS",
                    "waiting for final cleanup…",
                ]
            ),
            CompanionSession(
                id: "session-build",
                projectId: "project-kaisola",
                kind: .terminal,
                title: "Production build",
                status: .done,
                boardLane: "done",
                needsYou: false,
                unread: true,
                updatedAt: nowMs - 12 * minute,
                provider: "Terminal",
                model: nil,
                mode: nil,
                branch: "feature/mobile-companion",
                summary: "1987 modules transformed — build passed",
                startedAt: nowMs - 15 * minute,
                turns: nil,
                terminalLines: ["✓ 1987 modules transformed", "✓ built in 3.45s"]
            ),
            CompanionSession(
                id: "session-eval",
                projectId: "project-programbench",
                kind: .agent,
                title: "Score Box 2 trajectories",
                status: .running,
                boardLane: "running",
                needsYou: false,
                unread: false,
                updatedAt: nowMs - 25_000,
                provider: "Codex",
                model: "GPT-5",
                mode: "Agent",
                branch: "main",
                summary: "Processing 42 of 60 trajectories",
                startedAt: nowMs - 36 * minute,
                turns: [
                    CompanionTurn(role: .assistant, text: "The evaluator is healthy; 18 trajectories remain.", at: nowMs - 25_000),
                ],
                terminalLines: nil
            ),
            CompanionSession(
                id: "session-ci-failure",
                projectId: "project-programbench",
                kind: .terminal,
                title: "Nightly regression suite",
                status: .failed,
                boardLane: "waiting",
                needsYou: false,
                unread: true,
                updatedAt: nowMs - 7 * minute,
                provider: "Terminal",
                model: nil,
                mode: nil,
                branch: "main",
                summary: "One assertion failed in score normalization",
                startedAt: nowMs - 22 * minute,
                turns: nil,
                terminalLines: ["FAIL score normalization", "Expected 0.82, received 0.81"]
            ),
        ]

        let permissions = [
            CompanionPermission(
                permId: "permission-1",
                projectId: "project-kaisola",
                sessionId: "session-review",
                agent: "Claude",
                title: "Edit terminal subscription policy",
                kind: "edit",
                requestedAt: nowMs - minute,
                options: [
                    CompanionPermissionOption(id: "allow-once", label: "Allow once"),
                    CompanionPermissionOption(id: "reject", label: "Reject"),
                ],
                diffs: [
                    CompanionPermissionDiff(
                        relativePath: "electron/ipc/terminalManager.cjs",
                        oldText: "one owner",
                        newText: "one owner plus bounded observers"
                    ),
                ]
            ),
        ]

        let attention = [
            CompanionAttention(
                id: "attention-review-1",
                projectId: "project-programbench",
                sessionId: "session-ci-failure",
                kind: "failed",
                title: "Regression suite needs review",
                detail: "A score normalization assertion failed seven minutes ago.",
                createdAt: nowMs - 7 * minute,
                severity: "critical"
            ),
        ]

        return CompanionStore(
            connection: .preview,
            projects: projects,
            sessions: sessions,
            attention: attention,
            permissions: permissions,
            isPreview: true
        )
    }
}
