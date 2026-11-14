import Testing
import Foundation
@testable import AgentLoadCore

// Run with scripts/test.sh (Command Line Tools need extra framework flags for Swift Testing).

// MARK: - Fixture process tree (modelled on the real tree seen on the author's Mac, 2026-11-13)

private let home = "/Users/me"
private let wt = "\(home)/Documents/1-projects/dev/my-app-wt"

private func P(_ pid: Int32, _ ppid: Int32, _ name: String, path: String = "", argv: [String] = [],
               uid: UInt32 = 501, zombie: Bool = false, cpu: Double = 0, mem: UInt64 = 0, start: Int64 = 1) -> ProcInfo {
    ProcInfo(pid: pid, ppid: ppid, uid: uid, startMicros: start, name: name, path: path,
             argv: argv.isEmpty && !path.isEmpty ? [path] : argv, isZombie: zombie, cpuPercent: cpu, memBytes: mem)
}

private let opencode = "\(home)/.opencode/bin/opencode"
private let fixture: [ProcInfo] = [
    P(1, 0, "launchd", path: "/sbin/launchd", uid: 0),
    // OpenChamber app + helper
    P(865, 1, "OpenChamber", path: "/Applications/OpenChamber.app/Contents/MacOS/OpenChamber", cpu: 4),
    P(1083, 865, "OpenChamber Helper (Renderer)", path: "/Applications/OpenChamber.app/Contents/Frameworks/OpenChamber Helper (Renderer).app/Contents/MacOS/OpenChamber Helper (Renderer)", cpu: 9),
    // opencode server (started by OpenChamber)
    P(1108, 865, "opencode", path: opencode, argv: [opencode, "serve", "--hostname", "127.0.0.1", "--port", "49153"], cpu: 13),
    P(3548, 1108, "caffeinate", path: "/usr/bin/caffeinate", argv: ["caffeinate", "-ims"]),
    // claude CLI under the server
    P(4565, 1108, "claude", path: "\(home)/.local/share/claude/versions/2.1.0", argv: ["\(home)/.local/bin/claude", "--output-format", "stream-json"], cpu: 1),
    // Session A: shell under opencode serve → node → playwright → chrome
    P(71477, 1108, "zsh", path: "/bin/zsh", argv: ["/bin/zsh", "+o", "nomatch", "-c", "cd \(wt)/wiki-w14 && pnpm exec playwright test"]),
    P(78085, 71477, "node", path: "/opt/homebrew/bin/node", argv: ["node", "\(wt)/wiki-w14/node_modules/@playwright/test/cli.js", "test"], cpu: 20),
    P(78222, 78085, "workerd", path: "\(wt)/wiki-w14/node_modules/@cloudflare/workerd-darwin-arm64/bin/workerd", cpu: 45),
    P(78300, 78085, "chrome-headless-shell", path: "\(home)/Library/Caches/ms-playwright/chromium_headless_shell-1248/chrome-headless-shell-mac-arm64/chrome-headless-shell", cpu: 60),
    // opencode service + pty daemon + zombie + a session shell under the pty daemon
    P(3272, 1, "opencode", path: opencode, argv: [opencode, "serve", "--service"]),
    P(3693, 3272, "opencode-pty", path: "\(home)/.cache/opencode/bin/opencode-pty/0.5.2/opencode-pty", argv: ["opencode-pty", "daemon"]),
    P(3694, 3693, "zsh", zombie: true),
    P(62126, 3693, "zsh", path: "/bin/zsh", argv: ["/bin/zsh", "+o", "nomatch", "-c", "cd \(wt)/e2e && node tools/run.mjs"]),
    P(62127, 62126, "node", path: "/opt/homebrew/bin/node", argv: ["node", "tools/run.mjs"], cpu: 2),
    // claude under the service, with a shell child of its own
    P(4639, 3272, "claude", path: "\(home)/.local/share/claude/versions/2.1.0", argv: ["\(home)/.local/bin/claude"]),
    P(5000, 4639, "bash", path: "/bin/bash", argv: ["/bin/bash", "-c", "vitest run"]),
    P(5001, 5000, "node", path: "/opt/homebrew/bin/node", argv: ["node", "node_modules/vitest/vitest.mjs", "run"], cpu: 30),
    // A brand-new shell (first sample) → must not create a row yet
    P(9000, 1108, "zsh", path: "/bin/zsh", argv: ["/bin/zsh", "-c", "sleep 1"], start: 999),
    // Orphan in a worktree (re-parented to launchd)
    P(7000, 1, "workerd", path: "\(wt)/wiki-w16/node_modules/.bin/workerd", cpu: 15),
    // Other apps + Spotlight (root, no argv) + a daemon
    P(2000, 1, "firefox", path: "/Applications/Firefox.app/Contents/MacOS/firefox", cpu: 12, mem: 3_000_000_000),
    P(2001, 2000, "plugin-container", path: "/Applications/Firefox.app/Contents/MacOS/plugin-container.app/Contents/MacOS/plugin-container", cpu: 3),
    P(621, 1, "mds", path: "/System/Library/Frameworks/CoreServices.framework/Versions/A/Frameworks/Metadata.framework/Versions/A/Support/mds", argv: [], uid: 0, cpu: 60),
    P(592, 1, "logd", path: "/usr/libexec/logd", uid: 0, cpu: 5),
]

private let sessW14 = SessionInfo(id: "ses_w14", title: "W14 Images", directory: "\(home)/Documents/1-projects/dev/my-app")
private let sessT2 = SessionInfo(id: "ses_t2", title: "T2 measure", directory: "\(home)/Documents/1-projects/dev/my-app")
private let sessW16 = SessionInfo(id: "ses_w16", title: "W16 Comments", directory: "\(home)/Documents/1-projects/dev/my-app")
private let sessChat = SessionInfo(id: "ses_chat", title: "Quick chat", directory: "\(home)/.config/openchamber/chats/abc")

private func env(seen: Set<Int32>? = nil) -> Classifier.Environment {
    Classifier.Environment(
        sessionForShell: { _, cmd in
            if cmd.contains("wiki-w14") { return sessW14 }
            if cmd.contains("tools/run.mjs") { return sessT2 }
            if cmd.contains("vitest") { return sessChat }
            return nil
        },
        sessionForFolder: { $0.hasSuffix("/wiki-w16") ? sessW16 : nil },
        cwd: { p in
            switch p.pid {
            case 78085, 78222, 78300: return "\(wt)/wiki-w14"
            case 62127: return "\(wt)/e2e"
            case 7000: return "\(wt)/wiki-w16/apps/web"
            default: return ""
            }
        },
        wasSeenBefore: { key in seen.map { $0.contains(key.pid) } ?? (key.startMicros != 999) },
        uid: 501)
}

@Suite("Classification order")
struct ClassificationTests {
    let r = Classifier.classify(fixture, env: env())
    func pids(_ ps: [ProcInfo]) -> Set<Int32> { Set(ps.map(\.pid)) }
    func session(_ id: String) -> Classifier.SessionGroup? { r.sessions.first { $0.id == id } }

    @Test func sessionShellSubtreesComeFirst() {
        // Even though everything descends from OpenChamber, session work is not OpenChamber's.
        #expect(pids(session("ses_w14")!.procs) == [71477, 78085, 78222, 78300])
        #expect(session("ses_w14")!.folderPath == "\(wt)/wiki-w14")
    }

    @Test func shellsUnderPtyDaemonAndClaudeAreSessions() {
        #expect(pids(session("ses_t2")!.procs) == [62126, 62127])
        #expect(pids(session("ses_chat")!.procs) == [5000, 5001])
    }

    @Test func claudeProcessesCountedWithoutSessionWork() {
        #expect(r.claudeCount == 2)
        #expect(pids(r.claude) == [4565, 4639])
    }

    @Test func serverAndServiceGetTheirHelpers() {
        #expect(pids(r.server) == [1108, 3548])
        #expect(pids(r.service) == [3272, 3693, 3694])
    }

    @Test func openChamberGetsOnlyItsBundleProcesses() {
        #expect(pids(r.openChamber) == [865, 1083])
    }

    @Test func orphanInWorktreeGoesToOwningSession() {
        #expect(pids(session("ses_w16")!.procs) == [7000])
    }

    @Test func appsAndSpotlightAreGroupedByName() {
        #expect(pids(r.apps["Firefox"] ?? []) == [2000, 2001])
        #expect(pids(r.apps["Spotlight indexing"] ?? []) == [621])
    }

    @Test func firstSightShellAndDaemonsAreEverythingElse() {
        #expect(pids(r.unassigned) == [1, 592, 9000])
        #expect(!r.sessions.contains { $0.procs.contains { $0.pid == 9000 } })
    }

    @Test func everyProcessIsAssignedExactlyOnce() {
        var all = r.claude + r.server + r.service + r.openChamber + r.unassigned
        all += r.sessions.flatMap(\.procs) + r.apps.values.flatMap { $0 }
        #expect(all.count == fixture.count)
        #expect(Set(all.map(\.pid)).count == fixture.count)
    }

    @Test func unknownSessionFallsBackToFolder() {
        let e = env()
        let noDB = Classifier.Environment(sessionForShell: { _, _ in nil }, sessionForFolder: { _ in nil },
                                          cwd: e.cwd, wasSeenBefore: e.wasSeenBefore, uid: 501)
        let r2 = Classifier.classify(fixture, env: noDB)
        let g = r2.sessions.first { $0.procs.contains { $0.pid == 78222 } }
        #expect(g?.id == "folder:\(wt)/wiki-w14")
        #expect(g?.info == nil)
    }

    @Test func snapshotRowsAndEverythingElse() {
        let t = SystemTotals(load1: 3, cores: 8, pressureLevel: 1, memUsedBytes: 10_000_000_000,
                             memTotalBytes: 17_179_869_184, machineCPUPercent: 400)
        let s = SnapshotBuilder.build(classification: r, totals: t, now: Date(timeIntervalSince1970: 100), home: home)
        #expect(s.sessions.map(\.title) == ["W14 Images", "Quick chat", "W16 Comments", "T2 measure"])  // sorted by CPU
        #expect(s.sessions.first { $0.title == "Quick chat" }?.project == nil)        // chats folder: no project
        #expect(s.sessions.first?.project == "my-app")
        #expect(s.sessions.first?.subtitle == "wiki-w14 · browser tests · 1 min")
        #expect(s.sessionCount == 4)
        #expect(s.agentTools.map(\.name) == ["OpenChamber app", "opencode server", "opencode service", "Claude Code ×2"])
        #expect(s.otherApps.map(\.name).first == "Firefox")
        #expect(s.everythingElse.cpuPercent == max(0, 400 - s.listedCPUPercent))
    }
}

@Suite("Folded groups and Everything else memory")
struct FoldedTests {
    @Test func foldedRowsMatchTheReference() {
        let s = MockupData.snapshot()
        let tools = s.agentToolsGroup, other = s.otherAppsGroup
        #expect(tools.title == "Agent tools" && tools.members == "OpenChamber, opencode, Claude Code ×9")
        #expect(Format.cpu(tools.cpuPercent) == "51%" && Format.gb(tools.memBytes) == "3.2 GB")
        #expect(tools.items.map(\.name) == ["OpenChamber app", "opencode server", "opencode service", "Claude Code ×9"])
        #expect(other.title == "Other apps" && other.members == "Firefox, Spotlight indexing, everything else")
        #expect(Format.cpu(other.cpuPercent) == "92%" && Format.gb(other.memBytes) == "5.1 GB")
        #expect(other.items.map(\.name) == ["Firefox", "Spotlight indexing", "Everything else"])
    }

    @Test func everythingElseMemoryIsSumOfUnlistedProcessesWithOutlierGuard() {
        let mb: UInt64 = 1_048_576
        var normal = P(500, 1, "logd", path: "/usr/libexec/logd", mem: 40 * mb); normal.residentBytes = 30 * mb
        var compressedHeavy = P(501, 1, "x", path: "/usr/bin/x", mem: 900 * mb); compressedHeavy.residentBytes = 100 * mb
        var vm = P(502, 1, "vm", path: "/System/Library/Frameworks/Virtualization.framework/XPCServices/vm.xpc/vm",
                   mem: 12_000 * mb); vm.residentBytes = 290 * mb
        let unknownResident = P(503, 1, "y", path: "/usr/bin/y", mem: 2_000 * mb)   // resident 0 = unknown → footprint
        var c = Classifier.Result()
        c.unassigned = [normal, compressedHeavy, vm, unknownResident]
        // Memory used deliberately below the listed total: the old clamp would have shown 0.
        let t = SystemTotals(load1: 1, cores: 8, pressureLevel: 1, memUsedBytes: 1, memTotalBytes: 16 << 30, machineCPUPercent: 0)
        let s = SnapshotBuilder.build(classification: c, totals: t, now: Date(), home: home)
        // 40 + 900 (gap < 1 GB: footprint kept) + 290 (VM: resident) + 2000 (no resident known)
        #expect(s.everythingElse.memBytes == (40 + 900 + 290 + 2000) * mb)
    }
}

@Suite("Session listing rule")
struct ListingTests {
    let now: Int64 = 1_800_000_000_000
    let min: Int64 = 60_000
    let proj = "\(home)/Documents/1-projects/dev/my-app"
    let chat = "\(home)/.config/openchamber/chats/2026-11-10/session-x"

    func procRow(_ id: String, _ title: String, cpu: Double, mins: Int, parent: String? = nil) -> SessionRow {
        SessionRow(id: id, title: title, project: "my-app", folderName: "wiki-w14", folderPath: "/x",
                   activity: "sleep", runningSeconds: mins * 60, cpuPercent: cpu, memBytes: 0, kinds: [], processes: [],
                   parentID: parent)
    }
    func rows(_ p: [SessionRow], _ db: [DBSession]) -> [SessionRow] {
        SessionListing.rows(processRows: p, db: db, nowMs: now, home: home)
    }

    @Test func busySessionWithoutProcessesIsThinking() {
        let s = DBSession(id: "a", title: "Core redesign", directory: chat, timeBusy: now - 5 * min, timeIdle: nil, lastActivity: now - min)
        let r = rows([], [s])
        #expect(r.count == 1 && r[0].state == .thinking)
        #expect(r[0].subtitle == "thinking · 5 min")          // chat folder: no folder part
        #expect(r[0].folderPath == "" && r[0].cpuPercent == 0 && r[0].memBytes == 0)
    }

    @Test func projectFolderShownForThinkingRow() {
        let s = DBSession(id: "a", title: "T", directory: proj, timeBusy: now - 2 * min, timeIdle: now - 3 * min, lastActivity: now)
        #expect(rows([], [s]).first?.subtitle == "my-app · thinking · 2 min")
        #expect(rows([], [s]).first?.folderPath == proj)
    }

    @Test func finishedSessionIsExcluded() {
        let s = DBSession(id: "a", title: "Done", directory: proj, timeBusy: now - 10 * min, timeIdle: now - 9 * min, lastActivity: now - 9 * min)
        #expect(rows([], [s]).isEmpty)
    }

    @Test func staleBusyFlagIsIgnored() {
        let old = now - 13 * 60 * min
        let stale = DBSession(id: "a", title: "Stuck", directory: proj, timeBusy: old, timeIdle: nil, lastActivity: old)
        #expect(rows([], [stale]).isEmpty)
        // Busy for 13 h but with a recent message: still active.
        let alive = DBSession(id: "b", title: "Long", directory: proj, timeBusy: old, timeIdle: nil, lastActivity: now - 60 * min)
        #expect(rows([], [alive]).map(\.id) == ["b"])
        // Stale flag but processes running: listed through its processes.
        #expect(rows([procRow("a", "Stuck", cpu: 0, mins: 1)], [stale]).map(\.state) == [.processes])
    }

    @Test func parentsOfActiveSessionsWait() {
        let grand = DBSession(id: "g", title: "Pi extensions", directory: chat, timeBusy: now - 90 * min, timeIdle: now - 80 * min, lastActivity: now - 80 * min)
        let parent = DBSession(id: "p", title: "[my-app] dev", directory: proj, parentID: "g", timeBusy: now - 60 * min, timeIdle: now - 50 * min, lastActivity: now)
        let busyKid = DBSession(id: "k1", title: "W17", directory: proj, parentID: "p", timeBusy: now - 30 * min, timeIdle: nil, lastActivity: now)
        let procKidDB = DBSession(id: "k2", title: "W14", directory: proj, parentID: "p", timeBusy: now - 5 * min, timeIdle: now - min, lastActivity: now)
        let r = rows([procRow("k2", "W14", cpu: 0, mins: 3, parent: "p")], [grand, parent, busyKid, procKidDB])
        let p = r.first { $0.id == "p" }!
        #expect(p.state == .waiting && p.activity == "waiting for 2 sessions")
        #expect(p.waitingFor == ["W17", "W14"])                 // oldest active first
        #expect(p.runningSeconds == 30 * 60)                     // since the oldest active descendant
        let g = r.first { $0.id == "g" }!
        #expect(g.activity == "waiting for 2 sessions" && g.subtitle == "waiting for 2 sessions · 30 min")
        #expect(r.count == 4)
    }

    @Test func processOnlyRowsStayAndOrderIsCPUThenThinkingWaitingSleeping() {
        let thinkOld = DBSession(id: "t1", title: "T old", directory: proj, timeBusy: now - 20 * min, lastActivity: now)
        let thinkNew = DBSession(id: "t2", title: "T new", directory: proj, timeBusy: now - 2 * min, lastActivity: now)
        let parent = DBSession(id: "w", title: "Waiter", directory: proj, timeBusy: now - 99 * min, timeIdle: now - 98 * min)
        let kid = DBSession(id: "k", title: "Kid", directory: proj, parentID: "w")
        let r = rows([procRow("busy", "Busy", cpu: 150, mins: 4), procRow("sleep", "Sleeper", cpu: 0, mins: 7),
                      procRow("k", "Kid", cpu: 0.2, mins: 1, parent: "w")],
                     [thinkOld, thinkNew, parent, kid])
        #expect(r.map(\.id) == ["busy", "t2", "t1", "w", "k", "sleep"])
    }
}

@Suite("JSON escaping and matching")
struct JSONEscapeTests {
    @Test func escapesLikeJSONStringify() {
        #expect(JSONEscape.escape(#"grep -v "waiting for" | tail -5"#) == #"grep -v \"waiting for\" | tail -5"#)
        #expect(JSONEscape.escape("a\\b") == #"a\\b"#)
        #expect(JSONEscape.escape("line1\nline2\ttab") == #"line1\nline2\ttab"#)
        #expect(JSONEscape.escape("/tmp/x › y") == "/tmp/x › y")   // no escaping of / or non-ASCII
        #expect(JSONEscape.escape("\u{01}") == #"\u0001"#)
    }

    @Test func needleMatchesRealMessageShape() throws {
        let cmd = "cd /tmp/t2 && ./measure.sh 2>&1 | grep -v \"waiting for\" | tail -5\necho 'done'"
        // Encode the way opencode stores a tool call, then check our needle is found verbatim.
        let part: [String: Any] = ["type": "tool", "name": "shell", "state": ["status": "running", "input": ["command": cmd, "timeout": 0]]]
        let data = try JSONSerialization.data(withJSONObject: ["content": [part]], options: [.withoutEscapingSlashes, .sortedKeys])
        let json = String(decoding: data, as: UTF8.self)
        #expect(json.contains(JSONEscape.commandNeedle(cmd)))
        // A longer command that merely starts with ours must not match (closing quote is part of the needle).
        #expect(!json.contains(JSONEscape.commandNeedle("cd /tmp/t2")))
    }
}

@Suite("Activity labels")
struct ActivityTests {
    func node(_ script: String, _ args: [String] = [], cpu: Double = 0) -> ProcInfo {
        P(10, 1, "node", path: "/opt/homebrew/bin/node", argv: ["node", script] + args, cpu: cpu)
    }
    let chrome = P(11, 1, "chrome-headless-shell", path: "/x/ms-playwright/chromium_headless_shell-1/chrome-headless-shell")
    let workerd = P(12, 1, "workerd", path: "/x/node_modules/workerd/bin/workerd")

    @Test func kinds() {
        #expect(Activity.kind(of: chrome) == "Headless Chrome")
        #expect(Activity.kind(of: node("/x/node_modules/playwright/lib/worker/workerProcess.js")) == "Playwright runner")
        #expect(Activity.kind(of: node("./node_modules/.bin/../vite/bin/vite.js", ["preview"])) == "vite")
        #expect(Activity.kind(of: node("/opt/homebrew/bin/pnpm", ["exec"])) == "pnpm")
        #expect(Activity.kind(of: workerd) == "workerd")
        #expect(Activity.kind(of: P(13, 1, "zsh", path: "/bin/zsh")) == "shell")
    }

    @Test func browserTestsWinAlone() {
        #expect(Activity.label(for: [chrome, workerd, node("/x/vite/bin/vite.js", ["preview"])]) == "browser tests")
    }

    @Test func buildPlusPreview() {
        let build = node("/x/vite/bin/vite.js", ["build", "--sourcemap"])
        let preview = node("/x/vite/bin/vite.js", ["preview", "--port", "9281"])
        #expect(Activity.label(for: [build, preview, workerd]) == "build + preview")
        #expect(Activity.label(for: [preview, workerd]) == "preview")
        #expect(Activity.label(for: [workerd]) == "dev server")
        #expect(Activity.label(for: [node("/x/typescript/bin/tsc", ["--noEmit"])]) == "build")
    }

    @Test func unitTests() {
        #expect(Activity.label(for: [node("/x/node_modules/vitest/vitest.mjs", ["run"])]) == "unit tests")
        #expect(Activity.label(for: [node("/x/node_modules/jest/bin/jest.js")]) == "unit tests")
    }

    @Test func fallbackIsMainProgramName() {
        #expect(Activity.label(for: [P(13, 1, "zsh", path: "/bin/zsh"), node("tools/run.mjs", cpu: 3)]) == "node")
    }

    @Test func groupsCountByKind() {
        let g = Activity.groups(for: [chrome, chrome, chrome, workerd])
        #expect(g.first { $0.kind == "Headless Chrome" }?.label == "Headless Chrome ×3")
        #expect(g.first { $0.kind == "workerd" }?.label == "workerd")
    }
}

@Suite("Status rules")
struct StatusTests {
    @Test func green() {
        let r = StatusRules.evaluate(pressure: 1, load: 8.0, cores: 8)   // load == cores is still green
        #expect(r.level == .green && r.headline == "Calm" && r.verdict == "Room for another session")
    }
    @Test func amberMemory() {
        let r = StatusRules.evaluate(pressure: 2, load: 2, cores: 8)
        #expect(r.level == .amber && r.headline == "Busy · memory is tight" && r.verdict == "Wait before starting another session")
        #expect(r.memLevel == .amber && r.cpuLevel == .green)
    }
    @Test func amberCPU() {
        let r = StatusRules.evaluate(pressure: 1, load: 8.1, cores: 8)
        #expect(r.level == .amber && r.headline == "Busy · CPU is busy")
    }
    @Test func amberBoth() {
        #expect(StatusRules.evaluate(pressure: 2, load: 9, cores: 8).headline == "Busy · memory and CPU")
        #expect(StatusRules.evaluate(pressure: 2, load: 17, cores: 8).headline == "Overloaded · memory and CPU")
    }
    @Test func red() {
        let m = StatusRules.evaluate(pressure: 4, load: 1, cores: 8)
        #expect(m.level == .red && m.headline == "Overloaded · memory is critical" && m.verdict == "Too much running: free something up")
        let c = StatusRules.evaluate(pressure: 1, load: 16.1, cores: 8)
        #expect(c.level == .red && c.headline == "Overloaded · CPU is overloaded")
        #expect(StatusRules.evaluate(pressure: 1, load: 16, cores: 8).level == .amber)   // exactly 2× is not red
    }
}

@Suite("Helpers")
struct HelperTests {
    @Test func psTime() {
        #expect(ReaderTime.parse("1:47.13") == 107.13)
        #expect(abs((ReaderTime.parse("1-02:00:00.00") ?? 0) - 93_600) < 0.001)
        #expect(ReaderTime.parse("garbage") == nil)
    }
    @Test func worktree() {
        #expect(Classifier.worktree(of: "\(wt)/wiki-w14/apps/web")?.name == "wiki-w14")
        #expect(Classifier.worktree(of: "\(wt)/wiki-w14")?.path == "\(wt)/wiki-w14")
        #expect(Classifier.worktree(of: "\(home)/Documents/1-projects/dev/my-app") == nil)
    }
    @Test func formats() {
        #expect(Format.duration(30) == "<1 min")
        #expect(Format.duration(6 * 60 + 5) == "6 min")
        #expect(Format.duration(65 * 60) == "1 h 5 min")
        #expect(Format.cpu(209.6) == "210%")
        #expect(Format.gb(2_576_980_378) == "2.4 GB")
        #expect(Format.cores(load: 7.33, cores: 8) == "7.3 of 8 cores")
    }
}

/// Small alias so the test reads naturally.
enum ReaderTime { static func parse(_ s: String) -> Double? { ProcessReader.parsePSTime(s) } }

@Suite("Temp-folder test sessions and folder part")
struct TempSessionTests {
    let t = SystemTotals(load1: 1, cores: 8, pressureLevel: 1, memUsedBytes: 1, memTotalBytes: 16 << 30, machineCPUPercent: 100)
    let chatDir = "\(home)/.config/openchamber/chats/2026-11-10/session-ad57fc62"

    @Test func tempPaths() {
        #expect(SnapshotBuilder.isTempPath("/private/tmp/ar-v2-a", tmpDir: nil))
        #expect(SnapshotBuilder.isTempPath("/tmp", tmpDir: nil))
        #expect(SnapshotBuilder.isTempPath("/var/folders/bv/x/T/foo", tmpDir: nil))
        #expect(SnapshotBuilder.isTempPath("/private/var/folders/bv/x/T", tmpDir: "/var/folders/bv/x/T/"))
        #expect(!SnapshotBuilder.isTempPath("/tmpfoo", tmpDir: nil))
        #expect(!SnapshotBuilder.isTempPath("\(home)/Documents/1-projects/dev/agent-load", tmpDir: nil))
    }

    /// Throwaway sessions in /private/tmp are listed like any other session (they use capacity).
    /// A chat session that `cd`s into /private/tmp shows no folder part.
    @Test func tempSessionsListedChatSessionWithoutFolder() {
        let tempProc = P(800, 1108, "zsh", path: "/bin/zsh", cpu: 7, mem: 5_000_000)
        let chatProc = P(801, 1108, "zsh", path: "/bin/zsh", cpu: 3, mem: 1_000_000)
        var c = Classifier.Result()
        c.sessions = [
            .init(info: SessionInfo(id: "v2", title: "V2 A: full run", directory: "/private/tmp/ar-v2-a"),
                  id: "v2", procs: [tempProc], folderPath: "/private/tmp/ar-v2-a"),
            .init(info: SessionInfo(id: "lb", title: "Live test B", directory: chatDir),
                  id: "lb", procs: [chatProc], folderPath: "/private/tmp/ar-v2-b1"),
        ]
        let busyTemp = DBSession(id: "v2b", title: "V2 B: smoke", directory: "/private/tmp/ar-v2-b1",
                                 timeBusy: 99_999_000, lastActivity: 99_999_000)
        let s = SnapshotBuilder.build(classification: c, totals: t, now: Date(timeIntervalSince1970: 100_000),
                                      home: home, dbSessions: [busyTemp])
        #expect(Set(s.sessions.map(\.title)) == ["V2 A: full run", "Live test B", "V2 B: smoke"])
        let lb = s.sessions.first { $0.title == "Live test B" }!
        #expect(lb.folderName == "" && lb.folderPath == "")
        #expect(s.sessions.first { $0.title == "V2 A: full run" }?.folderName == "ar-v2-a")
        #expect(!s.everythingElse.processes.contains { $0.pid == 800 })
    }

    @Test func worktreeCwdKeepsItsName() {
        let f = SnapshotBuilder.processRowFolder(groupFolder: "\(wt)/wiki-w14",
            info: SessionInfo(id: "x", title: "W14", directory: "\(home)/Documents/1-projects/dev/my-app"), home: home)
        #expect(f.name == "wiki-w14")
        let g = SnapshotBuilder.processRowFolder(groupFolder: "/private/tmp/x",
            info: SessionInfo(id: "y", title: "A", directory: "\(home)/Documents/1-projects/dev/agent-load"), home: home)
        #expect(g.name == "agent-load")
    }
}

@Suite("Culprit line and sort by what is short")
struct CulpritTests {
    func snap(pressure: Int, load: Double) -> Snapshot {
        var c = Classifier.Result()
        c.sessions = [
            .init(info: SessionInfo(id: "a", title: "W14 Images", directory: "\(home)/p"), id: "a",
                  procs: [P(10, 1108, "node", path: "/x/node", cpu: 270, mem: 1_000_000_000)], folderPath: "\(home)/p"),
            .init(info: SessionInfo(id: "b", title: "W17 Mentions", directory: "\(home)/p"), id: "b",
                  procs: [P(11, 1108, "node", path: "/x/node", cpu: 20, mem: 3_000_000_000)], folderPath: "\(home)/p"),
        ]
        // Firefox is not in the top 3 shown apps here only by name; it is the biggest memory user.
        c.apps = ["Firefox": [P(20, 1, "firefox", path: "/Applications/Firefox.app/Contents/MacOS/firefox", cpu: 5, mem: 7_301_444_403)]]
        c.claude = [P(30, 1108, "claude", path: "/c", cpu: 400, mem: 100_000_000)]; c.claudeCount = 9
        let t = SystemTotals(load1: load, cores: 8, pressureLevel: pressure, memUsedBytes: 1, memTotalBytes: 16 << 30, machineCPUPercent: 700)
        return SnapshotBuilder.build(classification: c, totals: t, now: Date(timeIntervalSince1970: 100), home: home)
    }

    @Test func calmKeepsAdvice() {
        let s = snap(pressure: 1, load: 3)
        #expect(s.verdict == "Room for another session")
        #expect(s.sessions.first?.title == "W14 Images")             // CPU order
    }

    @Test func memoryShortNamesBiggestMemoryUserAndSortsByMemory() {
        let s = snap(pressure: 2, load: 3)
        #expect(s.verdict == "Firefox is using 6.8 GB")
        #expect(s.sessions.map(\.title) == ["W17 Mentions", "W14 Images"])
    }

    @Test func cpuShortNamesBiggestCPUUserWithoutCount() {
        let s = snap(pressure: 1, load: 12)
        #expect(s.verdict == "Claude Code is using 4.0 cores")
        #expect(s.sessions.first?.title == "W14 Images")
    }
}

@Suite("Swapping")
struct SwapTests {
    @Test func lineOnlyFromOneMBps() {
        #expect(Format.swapping(400_000) == nil)
        #expect(Format.swapping(12_300_000) == "Swapping 12 MB/s")
        #expect(Format.swapping(1_500_000_000) == "Swapping 1.5 GB/s")
    }

    @Test func heavySwapTurnsMemoryAmberWithItsOwnReason() {
        let r = StatusRules.evaluate(pressure: 1, load: 3, cores: 8, heavySwap: true)
        #expect(r.level == .amber && r.memLevel == .amber && r.headline == "Busy · memory is swapping")
        // Real pressure keeps its own wording; critical stays red.
        #expect(StatusRules.evaluate(pressure: 2, load: 3, cores: 8, heavySwap: true).headline == "Busy · memory is tight")
        #expect(StatusRules.evaluate(pressure: 4, load: 3, cores: 8, heavySwap: true).level == .red)
        #expect(StatusRules.evaluate(pressure: 1, load: 3, cores: 8).level == .green)
    }

    @Test func heavySwapNamesMemoryCulpritAndSortsByMemory() {
        var c = Classifier.Result()
        c.sessions = [
            .init(info: SessionInfo(id: "a", title: "Fast", directory: "\(home)/p"), id: "a",
                  procs: [P(10, 1108, "node", path: "/x/node", cpu: 270, mem: 1_000_000_000)], folderPath: "\(home)/p"),
            .init(info: SessionInfo(id: "b", title: "Big", directory: "\(home)/p"), id: "b",
                  procs: [P(11, 1108, "node", path: "/x/node", cpu: 20, mem: 3_000_000_000)], folderPath: "\(home)/p"),
        ]
        let t = SystemTotals(load1: 3, cores: 8, pressureLevel: 1, memUsedBytes: 1, memTotalBytes: 16 << 30,
                             machineCPUPercent: 300, swapBytesPerSec: 85_000_000, heavySwap: true)
        let s = SnapshotBuilder.build(classification: c, totals: t, now: Date(timeIntervalSince1970: 100), home: home)
        #expect(s.headline == "Busy · memory is swapping")
        #expect(s.verdict == "Big is using 2.8 GB")
        #expect(s.sessions.map(\.title) == ["Big", "Fast"])
        #expect(s.swapBytesPerSec == 85_000_000)
    }
}
