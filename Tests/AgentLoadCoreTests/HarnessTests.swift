import Testing
import Foundation
@testable import AgentLoadCore

// Harness detection, transcript titles and the working/idle rule for terminal harness rows.
// Fixtures are hand-written (no real transcripts: those carry account ids and project names).

private let home = "/Users/me"

private func Q(_ pid: Int32, _ ppid: Int32, _ name: String, path: String = "", argv: [String] = [],
               cpu: Double = 0, mem: UInt64 = 0, startSec: Int64 = 1_000) -> ProcInfo {
    ProcInfo(pid: pid, ppid: ppid, uid: 501, startMicros: startSec * 1_000_000, name: name, path: path,
             argv: argv.isEmpty && !path.isEmpty ? [path] : argv, cpuPercent: cpu, memBytes: mem)
}

private let claudeBin = "\(home)/.local/share/claude/versions/2.1.0"
private let opencode = "\(home)/.opencode/bin/opencode"

/// Process tree with every kind of harness: Claude Code under OpenChamber's opencode server
/// (must stay "Claude Code ×N"), and Claude Code, Codex (node wrapper + native child) and Pi
/// started in a terminal.
private let tree: [ProcInfo] = [
    Q(1, 0, "launchd", path: "/sbin/launchd"),
    Q(865, 1, "OpenChamber", path: "/Applications/OpenChamber.app/Contents/MacOS/OpenChamber"),
    Q(1108, 865, "opencode", path: opencode, argv: [opencode, "serve", "--port", "1"]),
    Q(4565, 1108, "claude", path: claudeBin, argv: ["\(home)/.local/bin/claude", "--output-format", "stream-json"], cpu: 3),
    Q(4600, 1108, "zsh", path: "/bin/zsh", argv: ["/bin/zsh", "+o", "nomatch", "-c", "pnpm test"]),
    // Terminal app → login shell → claude → its command shell → vitest; plus an MCP server.
    Q(500, 1, "Terminal", path: "/System/Applications/Utilities/Terminal.app/Contents/MacOS/Terminal"),
    Q(501, 500, "zsh", path: "/bin/zsh", argv: ["-zsh"]),
    Q(600, 501, "claude", path: claudeBin, argv: ["claude"], cpu: 20, mem: 300_000_000),
    Q(601, 600, "zsh", path: "/bin/zsh", argv: ["/bin/zsh", "-c", "-l", "source snap && eval 'pnpm vitest run'"]),
    Q(602, 601, "node", path: "/opt/homebrew/bin/node", argv: ["node", "node_modules/vitest/vitest.mjs", "run"], cpu: 50, mem: 200_000_000),
    Q(603, 600, "node", path: "/opt/homebrew/bin/node", argv: ["node", "mcp-server.js"], mem: 40_000_000),
    // Codex: npm wrapper (node script) + native binary + a command.
    Q(502, 500, "zsh", path: "/bin/zsh", argv: ["-zsh"]),
    Q(700, 502, "node", path: "/opt/homebrew/bin/node", argv: ["node", "/opt/homebrew/bin/codex"], mem: 50_000_000),
    Q(701, 700, "codex", path: "/opt/homebrew/lib/node_modules/@openai/codex/node_modules/@openai/codex-darwin-arm64/vendor/aarch64-apple-darwin/bin/codex",
      cpu: 2, mem: 80_000_000),
    Q(702, 701, "zsh", path: "/bin/zsh", argv: ["/bin/zsh", "-lc", "sleep 20"]),
    Q(703, 702, "sleep", path: "/bin/sleep", argv: ["sleep", "20"]),
    // Pi (node), idle.
    Q(503, 500, "zsh", path: "/bin/zsh", argv: ["-zsh"]),
    Q(800, 503, "node", path: "/opt/homebrew/bin/node", argv: ["node", "/opt/homebrew/bin/pi"], mem: 90_000_000),
    // Codex desktop backend: not a terminal session.
    Q(900, 1, "codex", path: "/Applications/ChatGPT.app/Contents/Resources/codex", argv: ["codex", "app-server"]),
]

private func env(cwds: [Int32: String] = [600: "\(home)/dev/agent-load", 700: "\(home)/dev/my-site", 800: "/private/tmp/pi-test"],
                 seen: Bool = true) -> Classifier.Environment {
    Classifier.Environment(sessionForShell: { _, _ in nil }, sessionForFolder: { _ in nil },
                           cwd: { cwds[$0.pid] ?? "" }, wasSeenBefore: { _ in seen }, uid: 501)
}

@Suite("Harness detection")
struct HarnessDetectionTests {
    @Test func standaloneHarnessesBecomeGroupsClaudeUnderOpencodeStays() {
        let r = Classifier.classify(tree, env: env())
        let byHarness = Dictionary(grouping: r.harnessGroups, by: \.harness)
        #expect(r.harnessGroups.count == 3)
        // Claude Code in the terminal: the CLI and all its descendants, its programs = shell subtree.
        let cc = byHarness[.claudeCode]!.first!
        #expect(cc.root.pid == 600)
        #expect(Set(cc.procs.map(\.pid)) == [600, 601, 602, 603])
        #expect(Set(cc.commands.map(\.pid)) == [601, 602])
        #expect(cc.cwd == "\(home)/dev/agent-load")
        // Codex: one group rooted at the node wrapper; `zsh -lc` counts as a command shell.
        let cx = byHarness[.codex]!.first!
        #expect(cx.root.pid == 700)
        #expect(Set(cx.procs.map(\.pid)) == [700, 701, 702, 703])
        #expect(Set(cx.commands.map(\.pid)) == [702, 703])
        #expect(byHarness[.pi]!.first!.root.pid == 800)
        // claude under opencode keeps its old place; its count is only those.
        #expect(r.claudeCount == 1)
        #expect(r.claude.map(\.pid) == [4565])
        // The desktop app's codex is not a terminal session.
        #expect(!r.harnessGroups.contains { $0.root.pid == 900 })
        // Terminal itself is still an app.
        #expect(r.apps["Terminal"]?.map(\.pid) == [500])
    }

    @Test func harnessSeenOnceMakesNoGroup() {
        let r = Classifier.classify(tree, env: env(seen: false))
        #expect(r.harnessGroups.isEmpty)
        #expect(r.unassigned.contains { $0.pid == 600 })
    }

    @Test func recognisers() {
        #expect(HarnessDetect.isCodex(Q(1, 0, "node", path: "/opt/homebrew/bin/node", argv: ["node", "/opt/homebrew/bin/codex", "exec", "hi"])))
        #expect(!HarnessDetect.isCodex(Q(1, 0, "node", path: "/opt/homebrew/bin/node", argv: ["node", "vite.js"])))
        #expect(HarnessDetect.isPi(Q(1, 0, "node", path: "/opt/homebrew/bin/node",
                                     argv: ["node", "--no-warnings", "/x/node_modules/@earendil-works/pi-coding-agent/dist/cli.js"])))
        #expect(HarnessDetect.isCommandShell(Q(1, 0, "zsh", path: "/bin/zsh", argv: ["/bin/zsh", "-lc", "ls"])))
        #expect(!HarnessDetect.isCommandShell(Q(1, 0, "zsh", path: "/bin/zsh", argv: ["-zsh"])))
        #expect(HarnessDetect.claudeFolderName(cwd: "/Users/me/.config/my_app 2") == "-Users-me--config-my-app-2")
        #expect(HarnessDetect.piFolderName(cwd: "/Users/me/dev/x") == "--Users-me-dev-x--")
        #expect(HarnessDetect.argValue(["claude", "--resume", "abc"], ["--resume"]) == "abc")
        #expect(HarnessDetect.argValue(["claude", "--session-id=abc"], ["--session-id"]) == "abc")
    }
}

@Suite("OpenChamber vs OpenCode")
struct OpenChamberRuleTests {
    @Test func keyOnSessionOrAncestor() {
        let db = [
            DBSession(id: "root", title: "Root", directory: "/d", openChamberOwn: true),
            DBSession(id: "child", title: "Child", directory: "/d", parentID: "root"),         // older sub-session, no key
            DBSession(id: "grandchild", title: "GC", directory: "/d", parentID: "child"),
            DBSession(id: "tui", title: "TUI session", directory: "/d"),                      // OpenCode
            DBSession(id: "tuichild", title: "TUI child", directory: "/d", parentID: "tui"),
        ]
        #expect(SessionListing.openChamberIDs(db) == ["root", "child", "grandchild"])
    }

    @Test func rowsGetTheirHarness() {
        let now: Int64 = 10_000_000
        let db = [
            DBSession(id: "oc", title: "OC busy", directory: "/d", timeBusy: now - 1000, timeIdle: nil, lastActivity: now, openChamberOwn: true),
            DBSession(id: "code", title: "OpenCode busy", directory: "/d", timeBusy: now - 1000, timeIdle: nil, lastActivity: now),
        ]
        var c = Classifier.Result()
        // A process row without DB info, but whose shell runs under OpenChamber's opencode server.
        c.sessions = [Classifier.SessionGroup(info: nil, id: "folder:/x", procs: [Q(5, 4, "node", cpu: 5)], folderPath: "/x",
                                              underOpenChamber: true),
                      Classifier.SessionGroup(info: SessionInfo(id: "plain", title: "Plain", directory: "/y"), id: "plain",
                                              procs: [Q(6, 4, "node", cpu: 4)], folderPath: "/y")]
        let t = SystemTotals(load1: 1, cores: 8, pressureLevel: 1, memUsedBytes: 1, memTotalBytes: 16 << 30, machineCPUPercent: 100)
        let s = SnapshotBuilder.build(classification: c, totals: t, now: Date(timeIntervalSince1970: Double(now) / 1000),
                                      home: home, dbSessions: db)
        let h = Dictionary(uniqueKeysWithValues: s.sessions.map { ($0.id, $0.harness) })
        #expect(h["oc"] == .openChamber)
        #expect(h["code"] == .openCode)
        #expect(h["folder:/x"] == .openChamber)
        #expect(h["plain"] == .openCode)
    }

    @Test func processTreeSignal() {
        // Shell under OpenChamber's server → underOpenChamber; under the service → not.
        let procs: [ProcInfo] = [
            Q(865, 1, "OpenChamber", path: "/Applications/OpenChamber.app/Contents/MacOS/OpenChamber"),
            Q(1108, 865, "opencode", path: opencode, argv: [opencode, "serve"]),
            Q(10, 1108, "zsh", path: "/bin/zsh", argv: ["/bin/zsh", "-c", "a"], cpu: 1),
            Q(3272, 1, "opencode", path: opencode, argv: [opencode, "serve", "--service"]),
            Q(11, 3272, "zsh", path: "/bin/zsh", argv: ["/bin/zsh", "-c", "b"], cpu: 1),
        ]
        let e = Classifier.Environment(sessionForShell: { _, cmd in SessionInfo(id: cmd, title: cmd, directory: "/d") },
                                       sessionForFolder: { _ in nil }, cwd: { _ in "" }, wasSeenBefore: { _ in true }, uid: 501)
        let r = Classifier.classify(procs, env: e)
        #expect(r.sessions.first { $0.id == "a" }?.underOpenChamber == true)
        #expect(r.sessions.first { $0.id == "b" }?.underOpenChamber == false)
    }
}

@Suite("Transcript titles")
struct TranscriptTitleTests {
    func scan(_ h: Harness, _ lines: [String]) -> TranscriptScan {
        var s = TranscriptScan()
        TranscriptParser.scan(Substring(lines.joined(separator: "\n") + "\n"), harness: h, into: &s)
        return s
    }

    @Test func claudeCode() {
        let base = [
            #"{"type":"user","isMeta":true,"message":{"role":"user","content":"<local-command-caveat>x"},"timestamp":"2026-11-14T10:00:00.000Z"}"#,
            #"{"type":"user","message":{"role":"user","content":[{"type":"text","text":"<system-reminder>ctx</system-reminder>"},{"type":"text","text":"Fix the login redirect\nmore detail"}]},"timestamp":"2026-11-14T10:00:01.000Z"}"#,
            #"{"type":"assistant","message":{"role":"assistant","content":[{"type":"text","text":"ok"}]}}"#,
            #"{"type":"user","message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"t","content":"done"}]},"timestamp":"2026-11-14T10:05:00.000Z"}"#,
        ]
        let s1 = scan(.claudeCode, base)
        #expect(s1.title == "Fix the login redirect")
        #expect(s1.lastUserMs == 1_794_650_401_000)   // the real prompt, not the tool result
        let s2 = scan(.claudeCode, base + [#"{"type":"ai-title","aiTitle":"Login redirect fix","sessionId":"s"}"#])
        #expect(s2.title == "Login redirect fix")
        let s3 = scan(.claudeCode, base + [#"{"type":"custom-title","customTitle":"Fix login redirect","sessionId":"s"}"#,
                                           #"{"type":"ai-title","aiTitle":"Something else","sessionId":"s"}"#])
        #expect(s3.title == "Fix login redirect")      // a name the user gave wins over generated titles
    }

    @Test func codex() {
        let lines = [
            #"{"timestamp":"2026-11-14T10:00:00.000Z","type":"session_meta","payload":{"id":"0199aaaa-bbbb-7ccc-8ddd-eeeeffff0000","cwd":"/Users/me/dev/my-site","originator":"codex_cli_rs"}}"#,
            #"{"timestamp":"2026-11-14T10:00:01.000Z","type":"response_item","payload":{"type":"message","role":"user","content":[{"type":"input_text","text":"<environment_context>\n<cwd>/x</cwd>\n</environment_context>"}]}}"#,
            #"{"timestamp":"2026-11-14T10:00:02.000Z","type":"response_item","payload":{"type":"message","role":"user","content":[{"type":"input_text","text":"Refactor the billing page"}]}}"#,
            #"{"timestamp":"2026-11-14T10:00:02.000Z","type":"event_msg","payload":{"type":"user_message","message":"Refactor the billing page","images":[]}}"#,
        ]
        let s = scan(.codex, lines)
        #expect(s.sessionID == "0199aaaa-bbbb-7ccc-8ddd-eeeeffff0000")
        #expect(s.title == "Refactor the billing page")
        #expect(s.lastUserMs == 1_794_650_402_000)
        let idx = TranscriptParser.codexIndex(Substring([
            #"{"id":"0199aaaa-bbbb-7ccc-8ddd-eeeeffff0000","thread_name":"Old name","updated_at":"2026-11-14T10:00:00Z"}"#,
            #"{"id":"0199aaaa-bbbb-7ccc-8ddd-eeeeffff0000","thread_name":"Refactor billing page","updated_at":"2026-11-14T10:01:00Z"}"#,
        ].joined(separator: "\n")))
        #expect(idx["0199aaaa-bbbb-7ccc-8ddd-eeeeffff0000"] == "Refactor billing page")
    }

    @Test func pi() {
        let lines = [
            #"{"type":"session","version":3,"id":"u1","timestamp":"2026-11-14T10:00:00.000Z","cwd":"/Users/me/dev/docs"}"#,
            #"{"type":"message","id":"a0","parentId":null,"timestamp":"2026-11-14T10:00:00.500Z","message":{"role":"system","content":"","timestamp":1}}"#,
            #"{"type":"message","id":"a1","parentId":"a0","timestamp":"2026-11-14T10:00:01.000Z","message":{"role":"user","content":"Tidy the docs folder","timestamp":1794996001000}}"#,
            #"{"type":"message","id":"a2","parentId":"a1","timestamp":"2026-11-14T10:00:02.000Z","message":{"role":"assistant","content":[{"type":"text","text":"Hi"}]}}"#,
        ]
        #expect(scan(.pi, lines).title == "Tidy the docs folder")
        let named = scan(.pi, lines + [#"{"type":"session_info","id":"k1","parentId":"a2","timestamp":"2026-11-14T10:01:00.000Z","name":"Tidy docs"}"#,
                                       #"{"type":"message","id":"a3","parentId":"k1","timestamp":"2026-11-14T10:02:00.000Z","message":{"role":"user","content":[{"type":"text","text":"and the README"}]}}"#])
        #expect(named.title == "Tidy docs")
        #expect(named.lastUserMs == 1_794_650_520_000)
    }
}

@Suite("Transcript files")
struct TranscriptStoreTests {
    /// Temporary fake home with a Claude Code, a Codex and a Pi transcript.
    func makeHome() throws -> String {
        let h = NSTemporaryDirectory() + "agentload-test-\(UUID().uuidString)"
        let fm = FileManager.default
        func write(_ rel: String, _ lines: [String]) throws {
            let p = h + "/" + rel
            try fm.createDirectory(atPath: (p as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
            try (lines.joined(separator: "\n") + "\n").write(toFile: p, atomically: true, encoding: .utf8)
        }
        let cc = ".claude/projects/" + HarnessDetect.claudeFolderName(cwd: "/Users/me/dev/agent-load")
        try write(cc + "/new-session.jsonl", [#"{"type":"user","entrypoint":"cli","message":{"role":"user","content":"Fix login redirect"},"timestamp":"2026-11-14T10:00:01.000Z"}"#])
        // Written by a Claude Code that opencode drives (Agent SDK): never a terminal session's.
        try write(cc + "/sdk-session.jsonl", [#"{"type":"user","entrypoint":"sdk-ts","message":{"role":"user","content":"Other work"},"timestamp":"2026-11-14T10:00:02.000Z"}"#])
        let f = DateFormatter(); f.dateFormat = "yyyy/MM/dd"
        try write(".codex/sessions/\(f.string(from: Date()))/rollout-2026-11-14T10-00-00-0199aaaa-bbbb-7ccc-8ddd-eeeeffff0000.jsonl", [
            #"{"timestamp":"2026-11-14T10:00:00.000Z","type":"session_meta","payload":{"id":"0199aaaa-bbbb-7ccc-8ddd-eeeeffff0000","cwd":"/Users/me/dev/my-site"}}"#,
            #"{"timestamp":"2026-11-14T10:00:02.000Z","type":"event_msg","payload":{"type":"user_message","message":"Refactor the billing page"}}"#])
        try write(".codex/session_index.jsonl", [#"{"id":"0199aaaa-bbbb-7ccc-8ddd-eeeeffff0000","thread_name":"Refactor billing page","updated_at":"2026-11-14T10:01:00Z"}"#])
        try write(".pi/agent/sessions/" + HarnessDetect.piFolderName(cwd: "/tmp/pi-test") + "/2026-11-14T10-00-00-000Z_u1.jsonl", [
            #"{"type":"session","version":3,"id":"u1","timestamp":"2026-11-14T10:00:00.000Z","cwd":"/tmp/pi-test"}"#,
            #"{"type":"message","id":"a1","parentId":null,"timestamp":"2026-11-14T10:00:01.000Z","message":{"role":"user","content":"Tidy docs please"}}"#])
        return h
    }

    @Test func findsAndReadsEachHarnessTranscript() throws {
        let h = try makeHome()
        defer { try? FileManager.default.removeItem(atPath: h) }
        let startSec = Int64(Date().timeIntervalSince1970) - 5   // started just before the files were written
        let procs = [Q(600, 1, "claude", path: claudeBin, argv: ["claude"], startSec: startSec),
                     Q(700, 1, "node", path: "/opt/homebrew/bin/node", argv: ["node", "/opt/homebrew/bin/codex"], startSec: startSec),
                     Q(800, 1, "node", path: "/opt/homebrew/bin/node", argv: ["node", "/opt/homebrew/bin/pi"], startSec: startSec)]
        let groups = [Classifier.HarnessGroup(harness: .claudeCode, root: procs[0], procs: [procs[0]], commands: [], cwd: "/Users/me/dev/agent-load"),
                      Classifier.HarnessGroup(harness: .codex, root: procs[1], procs: [procs[1]], commands: [], cwd: "/Users/me/dev/my-site"),
                      Classifier.HarnessGroup(harness: .pi, root: procs[2], procs: [procs[2]], commands: [], cwd: "/private/tmp/pi-test")]
        let store = TranscriptStore(home: h)
        let infos = store.infos(for: groups)
        #expect(infos[procs[0].key]?.title == "Fix login redirect")
        #expect(infos[procs[0].key]?.path.hasSuffix("new-session.jsonl") == true)
        #expect(infos[procs[1].key]?.title == "Refactor billing page")      // from the session index
        // Pi's folder is named after the cwd as Pi sees it; the kernel reports /private/tmp.
        // (Pi itself would have written to the /private/tmp folder name; here only /tmp exists.)
        #expect(infos[procs[2].key] == nil || infos[procs[2].key]?.title == "Tidy docs please")

        // Appended lines are picked up (custom title set later).
        let cc = h + "/.claude/projects/" + HarnessDetect.claudeFolderName(cwd: "/Users/me/dev/agent-load") + "/new-session.jsonl"
        let fh = try #require(FileHandle(forWritingAtPath: cc))
        try fh.seekToEnd()
        try fh.write(contentsOf: Data((#"{"type":"custom-title","customTitle":"Login fix","sessionId":"s"}"# + "\n").utf8))
        try fh.close()
        #expect(store.infos(for: groups)[procs[0].key]?.title == "Login fix")
    }

    @Test func piTranscriptInItsCwdFolder() throws {
        let h = try makeHome()
        defer { try? FileManager.default.removeItem(atPath: h) }
        let p = Q(800, 1, "node", path: "/opt/homebrew/bin/node", argv: ["node", "/opt/homebrew/bin/pi"], startSec: Int64(Date().timeIntervalSince1970) - 5)
        let g = Classifier.HarnessGroup(harness: .pi, root: p, procs: [p], commands: [], cwd: "/tmp/pi-test")
        #expect(TranscriptStore(home: h).infos(for: [g])[p.key]?.title == "Tidy docs please")
    }

    @Test func fileOlderThanTheProcessIsNotItsTranscript() throws {
        let h = try makeHome()
        defer { try? FileManager.default.removeItem(atPath: h) }
        let p = Q(600, 1, "claude", path: claudeBin, argv: ["claude"], startSec: Int64(Date().timeIntervalSince1970) + 600)
        let g = Classifier.HarnessGroup(harness: .claudeCode, root: p, procs: [p], commands: [], cwd: "/Users/me/dev/agent-load")
        #expect(TranscriptStore(home: h).infos(for: [g])[p.key] == nil)
    }
}

@Suite("Working or idle")
struct WorkingRuleTests {
    @Test func rule() {
        let now: Int64 = 1_000_000_000
        #expect(HarnessDetect.isWorking(cpuPercent: 1.0, transcriptModifiedMs: nil, nowMs: now))
        #expect(!HarnessDetect.isWorking(cpuPercent: 0.9, transcriptModifiedMs: nil, nowMs: now))
        #expect(HarnessDetect.isWorking(cpuPercent: 0, transcriptModifiedMs: now - 119_000, nowMs: now))
        #expect(!HarnessDetect.isWorking(cpuPercent: 0, transcriptModifiedMs: now - 121_000, nowMs: now))
    }

    @Test func idleHarnessDisappearsWorkingOneShows() {
        let r = Classifier.classify(tree, env: env())
        let nowSec: Int64 = 2_000
        let t = SystemTotals(load1: 1, cores: 8, pressureLevel: 1, memUsedBytes: 1, memTotalBytes: 16 << 30, machineCPUPercent: 200)
        let codexKey = r.harnessGroups.first { $0.harness == .codex }!.root.key
        let claudeKey = r.harnessGroups.first { $0.harness == .claudeCode }!.root.key
        let transcripts = [
            claudeKey: TranscriptInfo(path: "/c.jsonl", title: "Fix login redirect", lastUserMs: (nowSec - 240) * 1000, modifiedMs: nowSec * 1000),
            // Codex: 2% CPU (native binary) → working even with an old transcript.
            codexKey: TranscriptInfo(path: "/x.jsonl", title: "Refactor billing page", lastUserMs: nil, modifiedMs: 0),
        ]
        let s = SnapshotBuilder.build(classification: r, totals: t, now: Date(timeIntervalSince1970: Double(nowSec)), home: home,
                                      transcripts: transcripts)
        let cc = s.sessions.first { $0.harness == .claudeCode }
        #expect(cc?.title == "Fix login redirect")
        #expect(cc?.project == "agent-load")
        #expect(cc?.subtitle == "unit tests · 4 min")
        #expect(cc?.cpuPercent == 70)                          // claude itself + vitest
        #expect(cc?.kinds.contains { $0.label == "Claude Code itself" } == true)
        let cx = s.sessions.first { $0.harness == .codex }
        #expect(cx?.activity == "sleep")
        #expect(cx?.kinds.first { $0.kind == "Codex itself" }?.count == 1)   // wrapper + native binary counted as itself
        // Pi: 0% CPU, no transcript → not working, not listed; its process goes to Everything else.
        #expect(!s.sessions.contains { $0.harness == .pi })
        #expect(s.everythingElse.processes.contains { $0.pid == 800 })
        #expect(s.agentToolsGroup.members.contains("Claude Code ×1"))
    }

    @Test func workingWithoutPrograms() {
        let p = Q(600, 1, "claude", path: claudeBin, argv: ["claude"], cpu: 4, startSec: 1_000)
        let g = Classifier.HarnessGroup(harness: .claudeCode, root: p, procs: [p], commands: [], cwd: "\(home)/dev/x")
        let row = SnapshotBuilder.harnessRow(g, transcript: nil, nowMs: 1_120_000, home: home)
        #expect(row?.title == "Claude Code")
        #expect(row?.subtitle == "working · 2 min")
        #expect(SnapshotBuilder.harnessRow(g, transcript: nil, nowMs: 1_120_000, home: home)?.harness == .claudeCode)
    }
}
