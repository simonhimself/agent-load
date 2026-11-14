import Testing
import Foundation
@testable import AgentLoadCore

// The Claude desktop app is an agent tool ("Claude app"), including the VM it runs its local
// agent work in; other apps' VMs stay where they were.

private let vmPath = "/System/Library/Frameworks/Virtualization.framework/Versions/A/XPCServices/com.apple.Virtualization.VirtualMachine.xpc/Contents/MacOS/com.apple.Virtualization.VirtualMachine"

private func R(_ pid: Int32, _ ppid: Int32, _ name: String, path: String, responsible: String = "",
               cpu: Double = 0, mem: UInt64 = 0, resident: UInt64 = 0) -> ProcInfo {
    var p = ProcInfo(pid: pid, ppid: ppid, uid: 501, startMicros: 1, name: name, path: path, argv: [path],
                     cpuPercent: cpu, memBytes: mem)
    p.responsiblePath = responsible
    p.residentBytes = resident
    return p
}

private let gb: UInt64 = 1 << 30
private let claudeMain = "/Applications/Claude.app/Contents/MacOS/Claude"
private let procs: [ProcInfo] = [
    R(1, 0, "launchd", path: "/sbin/launchd"),
    R(865, 1, "OpenChamber", path: "/Applications/OpenChamber.app/Contents/MacOS/OpenChamber", cpu: 2, mem: gb / 4),
    R(100, 1, "Claude", path: claudeMain, cpu: 3, mem: gb / 2),
    R(101, 100, "Claude Helper (Renderer)",
      path: "/Applications/Claude.app/Contents/Frameworks/Claude Helper (Renderer).app/Contents/MacOS/Claude Helper (Renderer)",
      responsible: claudeMain, cpu: 4, mem: gb / 4),
    // Claude's VM: 12 GB footprint, 0.4 GB resident; responsible process = Claude.app.
    R(200, 1, "com.apple.Virtualization.VirtualMachine", path: vmPath, responsible: claudeMain,
      cpu: 10, mem: 12 * gb, resident: 400 << 20),
    // A Lima VM (e.g. Colima): same executable, but responsible = limactl → stays Everything else.
    R(300, 1, "limactl", path: "/Users/me/.colima/bin/limactl", cpu: 1, mem: 30 << 20),
    R(301, 1, "com.apple.Virtualization.VirtualMachine", path: vmPath, responsible: "/Users/me/.colima/bin/limactl",
      cpu: 5, mem: 8 * gb, resident: 300 << 20),
    // A VM owned by another app bundle stays that app's.
    R(400, 1, "com.apple.Virtualization.VirtualMachine", path: vmPath, responsible: "/Applications/UTM.app/Contents/MacOS/UTM",
      cpu: 2, mem: 4 * gb, resident: 4 * gb),
]

private func classify() -> Classifier.Result {
    Classifier.classify(procs, env: Classifier.Environment(sessionForShell: { _, _ in nil }, sessionForFolder: { _ in nil },
                                                           cwd: { _ in "" }, wasSeenBefore: { _ in true }, uid: 501))
}

@Suite("Claude desktop app")
struct ClaudeAppTests {
    @Test func claudeAppProcessesAndItsVMAreOneAgentTool() {
        let r = classify()
        #expect(Set(r.claudeApp.map(\.pid)) == [100, 101, 200])
        #expect(r.apps["Claude"] == nil)                               // no longer an "other app"
        #expect(r.unassigned.contains { $0.pid == 301 })                // Lima's VM: as before
        #expect(r.apps["UTM"]?.map(\.pid) == [400])                     // UTM's VM: as before
    }

    @Test func rowMembersAndMemoryGuard() {
        var c = classify()
        c.claude = [R(30, 1, "claude", path: "/c", cpu: 1, mem: gb / 8)]; c.claudeCount = 1
        c.server = [R(31, 865, "opencode", path: "/o", mem: gb / 8)]
        let t = SystemTotals(load1: 1, cores: 8, pressureLevel: 1, memUsedBytes: 1, memTotalBytes: 16 * gb, machineCPUPercent: 100)
        let s = SnapshotBuilder.build(classification: c, totals: t, now: Date(), home: "/Users/me")
        #expect(s.agentTools.map(\.name) == ["OpenChamber", "Claude app", "Claude Code (unmatched)"])
        #expect(s.agentToolsGroup.members == "OpenChamber, Claude app, Claude Code (unmatched)")
        let app = s.agentTools.first { $0.name == "Claude app" }!
        #expect(app.cpuPercent == 17)
        // VM counted with its resident 0.4 GB, not its 12 GB footprint.
        #expect(app.memBytes == gb / 2 + gb / 4 + (400 << 20))
        #expect(!s.otherApps.contains { $0.name == "Claude" })
    }

    @Test func culpritCanBeTheClaudeApp() {
        var c = Classifier.Result()
        c.claudeApp = [R(100, 1, "Claude", path: claudeMain, cpu: 500, mem: gb)]
        let t = SystemTotals(load1: 12, cores: 8, pressureLevel: 1, memUsedBytes: 1, memTotalBytes: 16 * gb, machineCPUPercent: 700)
        let s = SnapshotBuilder.build(classification: c, totals: t, now: Date(), home: "/Users/me")
        #expect(s.verdict == "Claude app is using 5.0 cores")
    }
}

@Suite("Cua")
struct CuaTests {
    let home = "/Users/me"
    let cuaApp = "/Applications/Cua Spaces.app/Contents/MacOS/CuaSpacesMac"
    let limactl = "/Users/me/.cua/runtimes/linux/colima-0.10.3-lima-2.2.0/lima/bin/limactl"
    var tree: [ProcInfo] {
        var ssh = R(14, 1, "ssh", path: "/usr/bin/ssh")
        ssh.argv = ["ssh: /Users/me/.cua/runtimes/linux/vm/_lima/colima-cua/ssh.sock [mux]"]
        return [
            R(1, 0, "launchd", path: "/sbin/launchd"),
            R(10, 1, "CuaSpacesMac", path: cuaApp, cpu: 1, mem: gb / 8),
            R(11, 10, "cua-driver", path: "/Applications/Cua Spaces.app/Contents/Helpers/cua-driver", mem: gb / 16),
            R(12, 1, "cua", path: "/Applications/Cua Spaces.app/Contents/MacOS/cua", mem: gb / 16),
            R(13, 1, "limactl", path: limactl, mem: gb / 32),
            ssh,
            R(15, 1, "com.apple.Virtualization.VirtualMachine", path: vmPath, responsible: limactl,
              cpu: 2, mem: 12 * gb, resident: 400 << 20),
            // Someone else's Colima: not Cua.
            R(20, 1, "limactl", path: "/opt/homebrew/bin/limactl", mem: gb / 32),
            R(21, 1, "com.apple.Virtualization.VirtualMachine", path: vmPath, responsible: "/opt/homebrew/bin/limactl",
              mem: 8 * gb, resident: 300 << 20),
            R(100, 1, "Claude", path: claudeMain, mem: gb / 2),
        ]
    }

    @Test func cuaRowHoldsAppDaemonRuntimeAndVM() {
        var e = Classifier.Environment(sessionForShell: { _, _ in nil }, sessionForFolder: { _ in nil },
                                       cwd: { _ in "" }, wasSeenBefore: { _ in true }, uid: 501)
        e.home = home
        let c = Classifier.classify(tree, env: e)
        #expect(Set(c.cua.map(\.pid)) == [10, 11, 12, 13, 14, 15])
        #expect(c.apps["Cua Spaces"] == nil)
        #expect(c.unassigned.contains { $0.pid == 20 } && c.unassigned.contains { $0.pid == 21 })
        let t = SystemTotals(load1: 1, cores: 8, pressureLevel: 1, memUsedBytes: 1, memTotalBytes: 16 * gb, machineCPUPercent: 100)
        var c2 = c
        c2.claude = [R(30, 1, "claude", path: "/c", mem: gb / 8)]; c2.claudeCount = 1
        c2.server = [R(31, 1, "opencode", path: "/o", mem: gb / 8)]
        c2.openChamber = [R(32, 1, "OpenChamber", path: "/Applications/OpenChamber.app/Contents/MacOS/OpenChamber", mem: gb / 8)]
        let s = SnapshotBuilder.build(classification: c2, totals: t, now: Date(), home: home)
        #expect(s.agentToolsGroup.members == "OpenChamber, Claude app, Cua, Claude Code (unmatched)")
        let row = s.agentTools.first { $0.name == "Cua" }!
        // VM with its resident 0.4 GB, not its 12 GB footprint.
        #expect(row.memBytes == gb / 8 + gb / 16 + gb / 16 + gb / 32 + (400 << 20))
        #expect(!s.otherApps.contains { $0.name == "Cua Spaces" })
    }
}
