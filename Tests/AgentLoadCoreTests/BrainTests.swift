import Testing
import Foundation
@testable import AgentLoadCore

// Claude Code brains (a `claude` run by opencode for a session on the claude-code provider)
// and the one-line-per-tool Agent tools.

private let dir = "/Users/me/dev/my-app"
private let now: Int64 = 10_000_000_000

private func sess(_ id: String, busySince: Int64? = nil, provider: String? = "claude-code", directory: String = dir,
                  lastActivity: Int64 = now) -> DBSession {
    DBSession(id: id, title: id, directory: directory, timeBusy: busySince, timeIdle: busySince.map { $0 - 1 },
              lastActivity: lastActivity, provider: provider)
}

@Suite("Brain matching")
struct BrainMatchTests {
    @Test func singleCandidateByCwd() {
        let sessions = [sess("a", busySince: now - 5_000),
                        sess("other-dir", busySince: now - 5_000, directory: "/Users/me/dev/other"),
                        sess("other-provider", busySince: now - 5_000, provider: "anthropic"),
                        sess("idle-old", lastActivity: now - 3_600_000)]
        // No transcript text needed: exactly one busy claude-code session in that folder.
        #expect(BrainMatcher.match(cwd: dir, startMs: now - 4_000, transcriptLastUser: nil, sessions: sessions,
                                   nowMs: now, lastUserText: { _ in nil }) == "a")
        // /private/tmp vs /tmp are the same folder.
        #expect(BrainMatcher.match(cwd: "/private/tmp/x", startMs: now, transcriptLastUser: nil,
                                   sessions: [sess("t", busySince: now - 1, directory: "/tmp/x")], nowMs: now,
                                   lastUserText: { _ in nil }) == "t")
    }

    @Test func severalCandidatesResolvedByTranscriptText() {
        let sessions = [sess("a", busySince: now - 60_000), sess("b", busySince: now - 5_000)]
        let texts = ["a": "Fix the login redirect", "b": "Tidy the docs folder\n\nand the README"]
        func m(_ mine: String?, start: Int64 = now - 4_000) -> String? {
            BrainMatcher.match(cwd: dir, startMs: start, transcriptLastUser: mine, sessions: sessions, nowMs: now,
                               lastUserText: { texts[$0] })
        }
        #expect(m("Tidy the docs folder and the README") == "b")             // whitespace differences ignored
        #expect(m("<system-reminder>x</system-reminder> Fix the login redirect") == "a")   // wrapped prompt
        #expect(m("Something else entirely") == nil)                          // no text match → unmatched
        #expect(m(nil) == nil)                                                // no transcript → unmatched
    }

    @Test func sameTextTieBrokenByStartTime() {
        let sessions = [sess("a", busySince: now - 60_000), sess("b", busySince: now - 5_000)]
        let r = BrainMatcher.match(cwd: dir, startMs: now - 59_000, transcriptLastUser: "run the tests", sessions: sessions,
                                   nowMs: now, lastUserText: { _ in "run the tests" })
        #expect(r == "a")
    }

    @Test func noCandidateIsUnmatched() {
        #expect(BrainMatcher.match(cwd: dir, startMs: now, transcriptLastUser: "x", sessions: [sess("old", lastActivity: now - 3_600_000)],
                                   nowMs: now, lastUserText: { _ in "x" }) == nil)
    }
}

@Suite("Brains in rows, Agent tools per tool")
struct BrainRowTests {
    let gb: UInt64 = 1 << 30
    func P(_ pid: Int32, _ ppid: Int32, _ name: String, cpu: Double = 0, mem: UInt64 = 0) -> ProcInfo {
        ProcInfo(pid: pid, ppid: ppid, uid: 501, startMicros: 1, name: name, path: "/x/\(name)", argv: [name], cpuPercent: cpu, memBytes: mem)
    }

    func build(brains: [ProcKey: String], load: Double = 1) -> Snapshot {
        var c = Classifier.Result()
        c.openChamber = [P(865, 1, "OpenChamber", cpu: 5, mem: gb / 2)]
        c.server = [P(1108, 865, "opencode", cpu: 2, mem: gb / 4)]
        c.service = [P(3272, 1, "opencode", cpu: 1, mem: gb / 4)]
        let b1 = P(500, 1108, "claude", cpu: 300, mem: gb / 2), b2 = P(501, 1108, "claude", cpu: 2, mem: gb / 8)
        let b3 = P(502, 3272, "claude", cpu: 1, mem: gb / 8)
        c.claude = [b1, b2, b3]; c.claudeCount = 3
        c.claudeGroups = [Classifier.ClaudeGroup(root: b1, procs: [b1], cwd: dir),
                          Classifier.ClaudeGroup(root: b2, procs: [b2], cwd: dir),
                          Classifier.ClaudeGroup(root: b3, procs: [b3], cwd: "/elsewhere")]
        c.claudeApp = [P(100, 1, "Claude", cpu: 1, mem: gb / 4)]
        let db = [DBSession(id: "think", title: "Plugin review", directory: dir, timeBusy: now - 60_000, timeIdle: nil, lastActivity: now,
                            openChamberOwn: true, provider: "claude-code")]
        let t = SystemTotals(load1: load, cores: 8, pressureLevel: 1, memUsedBytes: 1, memTotalBytes: 16 * gb,
                             machineCPUPercent: load > 8 ? 780 : 400)   // CPU status follows cores in use
        return SnapshotBuilder.build(classification: c, totals: t, now: Date(timeIntervalSince1970: Double(now) / 1000),
                                     home: "/Users/me", dbSessions: db, brains: brains)
    }

    @Test func brainJoinsThinkingRowUnmatchedStayInAgentTools() {
        let s = build(brains: [ProcKey(pid: 500, startMicros: 1): "think"])
        let row = s.sessions.first { $0.id == "think" }!
        #expect(row.state == .thinking)
        #expect(row.subtitle == "thinking · 1 min")                           // grey line unchanged
        #expect(row.cpuPercent == 300 && row.memBytes == gb / 2)              // the brain's numbers
        #expect(row.kinds.map(\.label) == ["Claude Code (agent)"])
        #expect(s.agentTools.map(\.name) == ["OpenChamber", "Claude app", "Claude Code (unmatched) ×2"])
        #expect(s.agentToolsGroup.members == "OpenChamber, Claude app, Claude Code (unmatched) ×2")
        let oc = s.agentTools[0]
        #expect(oc.cpuPercent == 8 && oc.memBytes == gb)                      // app + server + service
        #expect(s.toolParts.map(\.name) == ["OpenChamber app", "opencode server", "opencode service"])
    }

    @Test func allMatchedHidesUnmatchedLine() {
        var c = build(brains: [ProcKey(pid: 500, startMicros: 1): "think", ProcKey(pid: 501, startMicros: 1): "think",
                               ProcKey(pid: 502, startMicros: 1): "think"])
        #expect(c.agentTools.map(\.name) == ["OpenChamber", "Claude app"])
        c = build(brains: [ProcKey(pid: 500, startMicros: 1): "think", ProcKey(pid: 501, startMicros: 1): "think"])
        #expect(c.agentTools.last?.name == "Claude Code (unmatched)")        // one left: no "×1"
    }

    @Test func culpritNamesOpenChamberOrTheSession() {
        // CPU short (cores in use ≥ 85%): the session with its 300% brain is the biggest user.
        #expect(build(brains: [ProcKey(pid: 500, startMicros: 1): "think"], load: 12).verdict == "Plugin review is using 3.0 cores")
        // Without the match the unmatched brains are, named without the count.
        #expect(build(brains: [:], load: 12).verdict == "Claude Code (unmatched) is using 3.0 cores")
        var c = Classifier.Result()
        c.openChamber = [P(865, 1, "OpenChamber", cpu: 500)]
        let t = SystemTotals(load1: 12, cores: 8, pressureLevel: 1, memUsedBytes: 1, memTotalBytes: 16 * gb, machineCPUPercent: 700)
        #expect(SnapshotBuilder.build(classification: c, totals: t, now: Date(), home: "/Users/me").verdict == "OpenChamber is using 5.0 cores")
    }
}
