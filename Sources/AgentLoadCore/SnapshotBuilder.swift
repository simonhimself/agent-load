import Foundation

/// Machine-wide numbers for one sample.
public struct SystemTotals: Sendable {
    public var load1: Double
    public var cores: Int
    public var pressureLevel: Int
    public var memUsedBytes: UInt64
    public var memTotalBytes: UInt64
    /// Machine CPU busy over the last interval, percent of one core (0 … cores×100).
    public var machineCPUPercent: Double
    /// Memory moved between RAM and disk (swap-ins + swap-outs) over the last interval, bytes/s.
    public var swapBytesPerSec: Double
    /// Swapping has been heavy for several seconds (see SystemStats.heavySwapRate).
    public var heavySwap: Bool
    public init(load1: Double, cores: Int, pressureLevel: Int, memUsedBytes: UInt64, memTotalBytes: UInt64, machineCPUPercent: Double,
                swapBytesPerSec: Double = 0, heavySwap: Bool = false) {
        self.load1 = load1; self.cores = cores; self.pressureLevel = pressureLevel
        self.memUsedBytes = memUsedBytes; self.memTotalBytes = memTotalBytes; self.machineCPUPercent = machineCPUPercent
        self.swapBytesPerSec = swapBytesPerSec; self.heavySwap = heavySwap
    }
}

/// Turns a classification + system totals into the rows the dropdown shows. Pure.
public enum SnapshotBuilder {
    /// At most this many "Other apps" rows (spec: "top 2–3 heaviest by name").
    public static let maxOtherApps = 3
    /// An app must use at least this share of the machine (CPU share + memory share) to be listed.
    public static let minAppScore = 0.01

    /// Footprint-over-resident gap above which a process's footprint is treated as an outlier.
    public static let outlierGap: UInt64 = 1 << 30   // 1 GB

    /// A process's memory as counted in "Everything else": its footprint, except when the
    /// footprint is more than 1 GB above what is actually resident. Then most of it is swapped
    /// out (e.g. a virtual machine: 12 GB footprint, 0.3 GB resident) and not using RAM now, so
    /// the resident size is used instead. Ordinary processes never hit this.
    public static func ramContribution(_ p: ProcInfo) -> UInt64 {
        guard p.residentBytes > 0, p.memBytes > p.residentBytes + outlierGap else { return p.memBytes }
        return p.residentBytes
    }

    static func sum(_ procs: [ProcInfo]) -> (Double, UInt64) {
        procs.reduce((0.0, UInt64(0))) { ($0.0 + $1.cpuPercent, $0.1 + $1.memBytes) }
    }

    /// Project name for the grey text next to the title: basename of the session directory,
    /// omitted for OpenChamber's scratch chats (~/.config/openchamber/chats/...).
    public static func projectName(directory: String, home: String) -> String? {
        if directory.isEmpty { return nil }
        if directory.hasPrefix(home + "/.config/openchamber/chats") { return nil }
        return (directory as NSString).lastPathComponent
    }

    /// Temporary folders: /tmp, /private/tmp, /var/folders, /private/var/folders and $TMPDIR.
    public static func isTempPath(_ path: String, tmpDir: String? = ProcessInfo.processInfo.environment["TMPDIR"]) -> Bool {
        var roots = ["/tmp", "/private/tmp", "/var/folders", "/private/var/folders"]
        if let t = tmpDir, !t.isEmpty {
            let trimmed = t.hasSuffix("/") ? String(t.dropLast()) : t
            roots.append(trimmed)
            if trimmed.hasPrefix("/var/") { roots.append("/private" + trimmed) }
        }
        return roots.contains { path == $0 || path.hasPrefix($0 + "/") }
    }

    /// Folder part of a process row's grey line, and the folder revealed on click.
    /// - programs run in a worktree (`*-wt/<name>`): that worktree, as before;
    /// - otherwise the session's own directory: its name, or nothing for chat folders
    ///   (~/.config/openchamber/chats), whatever folder the commands `cd` into (e.g. /tmp);
    /// - without DB info: the folder the programs run in.
    static func processRowFolder(groupFolder: String, info: SessionInfo?, home: String) -> (name: String, path: String) {
        if let wt = Classifier.worktree(of: groupFolder) { return (wt.name, wt.path) }
        if let info, !info.directory.isEmpty {
            guard let name = projectName(directory: info.directory, home: home) else { return ("", "") }
            return (name, info.directory)
        }
        return (groupFolder.isEmpty ? "" : (groupFolder as NSString).lastPathComponent, groupFolder)
    }

    /// "Firefox is using 6.8 GB" / "W14 Images is using 2.7 cores". "Claude Code ×9" → "Claude Code".
    public static func culpritLine(name: String, cpuPercent: Double, memBytes: UInt64, byMemory: Bool) -> String {
        var n = name
        if let r = n.range(of: " ×", options: .backwards) { n = String(n[..<r.lowerBound]) }
        let amount = byMemory ? Format.gb(memBytes) : String(format: "%.1f cores", cpuPercent / 100)
        return "\(n) is using \(amount)"
    }

    /// Row for a terminal harness session (Claude Code, Codex, Pi started on their own), or nil
    /// while it is not working (then its processes count under "Everything else").
    /// - title: the transcript's title, else the harness name; project: its folder's name;
    /// - grey line: `<activity> · <time>`: the label of the programs it runs, or "working"
    ///   when it runs none; the time since the last user message (at most since the start);
    /// - hover: its own processes as "<Harness> itself", the rest by kind.
    public static func harnessRow(_ g: Classifier.HarnessGroup, transcript t: TranscriptInfo?, nowMs: Int64,
                                  home: String) -> SessionRow? {
        let (cpu, mem) = sum(g.procs)
        guard HarnessDetect.isWorking(cpuPercent: cpu, transcriptModifiedMs: t?.modifiedMs, nowMs: nowMs) else { return nil }
        let programs = g.commands.filter { !$0.isZombie }
        let startMs = g.root.startMicros / 1000
        let since = min(max(t?.lastUserMs ?? startMs, startMs), nowMs)
        let project: String? = (g.cwd.isEmpty || g.cwd == home || g.cwd == "/") ? nil : (g.cwd as NSString).lastPathComponent
        let own = g.procs.filter { HarnessDetect.terminalHarness($0) != nil }
        let ownKeys = Set(own.map(\.key))
        var kinds = Activity.groups(for: g.procs.filter { !ownKeys.contains($0.key) })
        if !own.isEmpty {
            let (oc, om) = sum(own)
            kinds.insert(KindGroup(kind: "\(g.harness.displayName) itself", count: 1, cpuPercent: oc, memBytes: om), at: 0)
            kinds.sort { ($0.cpuPercent, Double($0.memBytes)) > ($1.cpuPercent, Double($1.memBytes)) }
        }
        var row = SessionRow(
            id: "harness:\(g.root.pid):\(g.root.startMicros)",
            title: t?.title ?? g.harness.displayName,
            project: project,
            folderName: "",
            folderPath: g.cwd,
            activity: programs.isEmpty ? "working" : Activity.label(for: programs),
            runningSeconds: Int(max(0, nowMs - since) / 1000),
            cpuPercent: cpu, memBytes: mem,
            kinds: kinds,
            processes: g.procs.sorted { $0.pid < $1.pid })
        row.harness = g.harness
        return row
    }

    public static func build(classification c: Classifier.Result, totals t: SystemTotals, now: Date,
                             home: String, notes: [String] = [], dbSessions: [DBSession] = [],
                             transcripts: [ProcKey: TranscriptInfo] = [:]) -> Snapshot {
        let status = StatusRules.evaluate(pressure: t.pressureLevel, load: t.load1, cores: t.cores, heavySwap: t.heavySwap)
        let nowMicros = Int64(now.timeIntervalSince1970 * 1_000_000)

        // Sessions. Throwaway test sessions in temp folders (e.g. /private/tmp/ar-v2-*) are
        // listed like any other: the owner wants them visible because they use capacity
        // (decided 2026-11-14, reversing a short-lived exclusion).
        let ocIDs = SessionListing.openChamberIDs(dbSessions)
        var sessions0: [SessionRow] = c.sessions.map { g in
            let (cpu, mem) = sum(g.procs)
            let oldest = g.procs.map(\.startMicros).filter { $0 > 0 }.min() ?? nowMicros
            let folder = processRowFolder(groupFolder: g.folderPath, info: g.info, home: home)
            var row = SessionRow(
                id: g.id,
                title: g.info?.title.isEmpty == false ? g.info!.title : (folder.name.isEmpty ? "Session" : folder.name),
                project: g.info.flatMap { projectName(directory: $0.directory, home: home) },
                folderName: folder.name,
                folderPath: folder.path,
                activity: Activity.label(for: g.procs),
                runningSeconds: Int(max(0, nowMicros - oldest) / 1_000_000),
                cpuPercent: cpu, memBytes: mem,
                kinds: Activity.groups(for: g.procs),
                processes: g.procs.sorted { $0.pid < $1.pid },
                parentID: g.info?.parentID)
            // OpenChamber when the DB says so (key on the session or an ancestor) or the shell runs
            // under OpenChamber's own opencode server; otherwise OpenCode.
            row.harness = (g.info?.openChamber == true || ocIDs.contains(g.id) || g.underOpenChamber) ? .openChamber : .openCode
            return row
        }
        // Terminal harness sessions: listed only while working.
        var idleHarnessProcs: [ProcInfo] = []
        for g in c.harnessGroups {
            if let r = harnessRow(g, transcript: transcripts[g.root.key], nowMs: nowMicros / 1000, home: home) {
                sessions0.append(r)
            } else {
                idleHarnessProcs += g.procs
            }
        }
        var sessions = sessions0
        // Add sessions without processes (thinking / waiting) and sort (SessionListing).
        sessions = SessionListing.rows(processRows: sessions, db: dbSessions, nowMs: nowMicros / 1000, home: home,
                                       byMemory: status.memLevel != .green)

        // Agent tools (only rows that exist)
        var tools: [SimpleRow] = []
        func addTool(_ name: String, _ procs: [ProcInfo]) {
            guard !procs.isEmpty else { return }
            let (cpu, mem) = sum(procs)
            tools.append(SimpleRow(name: name, cpuPercent: cpu, memBytes: mem, processes: procs))
        }
        addTool("OpenChamber app", c.openChamber)
        addTool("opencode server", c.server)
        addTool("opencode service", c.service)
        addTool("Claude Code ×\(c.claudeCount)", c.claude)
        // Claude desktop app and Cua run virtual machines. A VM's footprint counts guest memory that
        // is mostly not resident (12 GB footprint, 0.4 GB resident), so these two rows, and only
        // these agent tools rows, use the same outlier guard as Everything else.
        func addVMTool(_ name: String, _ procs: [ProcInfo]) {
            guard !procs.isEmpty else { return }
            tools.append(SimpleRow(name: name, cpuPercent: procs.reduce(0) { $0 + $1.cpuPercent },
                                   memBytes: procs.reduce(UInt64(0)) { $0 + ramContribution($1) }, processes: procs))
        }
        addVMTool("Claude app", c.claudeApp)
        addVMTool("Cua", c.cua)

        // Other apps: rank by share of the machine (CPU share + memory share) so both a
        // 3 GB browser and a 60%-CPU indexer can show up.
        let coresPct = Double(max(t.cores, 1)) * 100
        func score(_ r: SimpleRow) -> Double {
            r.cpuPercent / coresPct + Double(r.memBytes) / Double(max(t.memTotalBytes, 1))
        }
        let others = c.apps.map { name, procs -> SimpleRow in
            let (cpu, mem) = sum(procs)
            return SimpleRow(name: name, cpuPercent: cpu, memBytes: mem, processes: procs)
        }
        .filter { score($0) >= minAppScore }
        .sorted { score($0) > score($1) }
        let shownApps = Array(others.prefix(maxOtherApps))

        // Everything else = machine totals minus everything listed, clamped at zero.
        let listed = sessions.map { ($0.cpuPercent, $0.memBytes) } + (tools + shownApps).map { ($0.cpuPercent, $0.memBytes) }
        let listedCPU = listed.reduce(0) { $0 + $1.0 }
        let listedMem = listed.reduce(UInt64(0)) { $0 + $1.1 }
        let restCPU = max(0, t.machineCPUPercent - listedCPU)
        let hiddenApps = others.dropFirst(maxOtherApps).flatMap(\.processes)
            + c.apps.filter { name, _ in !others.contains { $0.name == name } }.flatMap(\.value)
        // Memory = sum of the actual unlisted processes, like every other row. (Total minus
        // listed does not work: footprints count compressed and swapped memory, so the rows
        // add up to more than "Memory used" and the difference clamped to 0.)
        let restProcs = c.unassigned + hiddenApps + idleHarnessProcs
        let restMem = restProcs.reduce(UInt64(0)) { $0 + ramContribution($1) }
        let rest = SimpleRow(name: "Everything else", cpuPercent: restCPU, memBytes: restMem,
                             processes: restProcs)

        // When not calm, the line under the headline names the main culprit instead of the
        // generic advice (owner, 2026-11-14): the biggest user of the resource that is short,
        // among sessions, agent tools and ALL named apps (also ones folded away or not in the
        // top 3). Memory wins when both are short, as it is the primary signal.
        var verdict = status.verdict
        if status.level != .green {
            let byMem = status.memLevel != .green
            let candidates: [(name: String, cpu: Double, mem: UInt64)] =
                sessions.map { ($0.title, $0.cpuPercent, $0.memBytes) }
                + tools.map { ($0.name, $0.cpuPercent, $0.memBytes) }
                + others.map { ($0.name, $0.cpuPercent, $0.memBytes) }
            if let top = candidates.max(by: { byMem ? $0.mem < $1.mem : $0.cpu < $1.cpu }) {
                verdict = culpritLine(name: top.name, cpuPercent: top.cpu, memBytes: top.mem, byMemory: byMem)
            }
        }

        var snap = Snapshot(date: now, level: status.level, cpuLevel: status.cpuLevel, memLevel: status.memLevel,
                        headline: status.headline, verdict: verdict,
                        load1: t.load1, cores: t.cores, memUsedBytes: t.memUsedBytes, memTotalBytes: t.memTotalBytes,
                        pressureLevel: t.pressureLevel, machineCPUPercent: t.machineCPUPercent,
                        sessions: sessions, agentTools: tools, otherApps: shownApps, everythingElse: rest,
                        listedMemBytes: listedMem, listedCPUPercent: listedCPU, notes: notes)
        snap.allAppNames = c.apps.keys.sorted()
        snap.swapBytesPerSec = t.swapBytesPerSec
        return snap
    }
}
