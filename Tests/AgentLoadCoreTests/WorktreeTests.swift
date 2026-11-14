import Testing
import Foundation
@testable import AgentLoadCore

// Worktree inferred from a session's recent messages (fixture message data, neutral names).

private let wt = "/Users/me/dev/my-app-wt"
private func msg(_ path: String) -> String {
    #"{"type":"tool","state":{"input":{"command":"cd \#(path) && pnpm test"}}}"#
}

@Suite("Worktree from messages")
struct WorktreeInferenceTests {
    @Test func clearWinner() {
        let texts = Array(repeating: msg("\(wt)/wiki-w22/apps/web"), count: 5) + [msg("\(wt)/other")] + ["no paths here"]
        #expect(WorktreeInference.pick(texts) == "\(wt)/wiki-w22")
    }

    @Test func tieOrBelowSixtyPercentGivesNone() {
        #expect(WorktreeInference.pick(Array(repeating: msg("\(wt)/a"), count: 4) + Array(repeating: msg("\(wt)/b"), count: 4)) == nil)
        // 5 of 9 = 56%.
        #expect(WorktreeInference.pick(Array(repeating: msg("\(wt)/a"), count: 5) + Array(repeating: msg("\(wt)/b"), count: 4)) == nil)
        // 6 of 10 = 60%: enough.
        #expect(WorktreeInference.pick(Array(repeating: msg("\(wt)/a"), count: 6) + Array(repeating: msg("\(wt)/b"), count: 4)) == "\(wt)/a")
    }

    @Test func fewerThanThreeGivesNone() {
        #expect(WorktreeInference.pick([msg("\(wt)/a"), msg("\(wt)/a")]) == nil)
        #expect(WorktreeInference.pick([]) == nil)
    }

    @Test func appliedOnlyWhereProgramsShowNoWorktree() {
        func row(_ id: String, folder: String, path: String, state: SessionState = .thinking) -> SessionRow {
            SessionRow(id: id, title: id, project: "my-app", folderName: folder, folderPath: path, activity: "thinking",
                       runningSeconds: 14 * 60, cpuPercent: 0, memBytes: 0, kinds: [], processes: [], state: state)
        }
        let rows = [
            row("think", folder: "my-app", path: "/Users/me/dev/my-app"),                          // main checkout
            row("busy", folder: "wiki-w21", path: "\(wt)/wiki-w21", state: .processes),             // programs in a worktree
            row("harness:1:1", folder: "", path: "/Users/me/dev/my-app"),
        ]
        let out = WorktreeInference.apply(rows, worktrees: ["think": "\(wt)/wiki-w22", "busy": "\(wt)/zzz", "harness:1:1": "\(wt)/zzz"])
        #expect(out[0].subtitle == "wiki-w22 · thinking · 14 min")
        #expect(out[0].folderPath == "\(wt)/wiki-w22")                                          // click reveals it
        #expect(out[1].folderName == "wiki-w21" && out[1].folderPath == "\(wt)/wiki-w21")      // unchanged
        #expect(out[2].folderName == "")                                                        // terminal harness: untouched
        #expect(WorktreeInference.needsLookup(rows[0]) && !WorktreeInference.needsLookup(rows[1]))
    }
}
