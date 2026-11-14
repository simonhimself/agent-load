import Foundation

/// Identifies one process instance. PIDs are reused by macOS, so every cache in this
/// app is keyed by (pid, start time) rather than by pid alone.
public struct ProcKey: Hashable, Sendable {
    public let pid: Int32
    /// Process start time in microseconds since 1970.
    public let startMicros: Int64
    public init(pid: Int32, startMicros: Int64) {
        self.pid = pid
        self.startMicros = startMicros
    }
}

/// One process as seen in a single sample.
public struct ProcInfo: Sendable {
    public var pid: Int32
    public var ppid: Int32
    public var uid: UInt32
    public var startMicros: Int64
    /// Short name from the kernel (p_comm, max 16 chars).
    public var name: String
    /// Full executable path ("" when unknown).
    public var path: String
    /// argv (empty for other users' processes, which we may not read).
    public var argv: [String]
    /// Current working directory, filled lazily only where needed ("" when unknown).
    public var cwd: String
    public var isZombie: Bool
    /// CPU over the last sample interval, in percent of one core (100 = one core busy).
    public var cpuPercent: Double
    /// Memory in bytes: phys_footprint for own processes (matches Activity Monitor),
    /// RSS from `ps` for other users' processes (e.g. Spotlight's root-owned mds).
    public var memBytes: UInt64
    /// Executable path of the "responsible" process (the app that launched this helper, as
    /// Activity Monitor groups them), "" if it is the process itself or unknown.
    public var responsiblePath: String = ""
    /// Resident memory in bytes (ri_resident_size, or ps RSS). 0 = unknown.
    public var residentBytes: UInt64 = 0

    public var key: ProcKey { ProcKey(pid: pid, startMicros: startMicros) }

    public init(pid: Int32, ppid: Int32, uid: UInt32 = 501, startMicros: Int64 = 0, name: String,
                path: String = "", argv: [String] = [], cwd: String = "", isZombie: Bool = false,
                cpuPercent: Double = 0, memBytes: UInt64 = 0) {
        self.pid = pid; self.ppid = ppid; self.uid = uid; self.startMicros = startMicros
        self.name = name; self.path = path; self.argv = argv; self.cwd = cwd
        self.isZombie = isZombie; self.cpuPercent = cpuPercent; self.memBytes = memBytes
        self.exeName = ProcInfo.exeName(path: path, argv: argv, name: name)
    }

    /// Basename of the executable, preferring the full path over the 16-char kernel name.
    /// Stored (not computed) because the classifier asks for it many times per process;
    /// call `refreshExeName()` after changing path/argv.
    public private(set) var exeName: String

    public mutating func refreshExeName() { exeName = ProcInfo.exeName(path: path, argv: argv, name: name) }

    static func exeName(path: String, argv: [String], name: String) -> String {
        if !path.isEmpty { return (path as NSString).lastPathComponent }
        if let a0 = argv.first, !a0.isEmpty { return (a0 as NSString).lastPathComponent }
        return name
    }
}

/// Info about an agent session from the opencode database.
public struct SessionInfo: Sendable, Equatable {
    public var id: String
    public var title: String
    public var directory: String
    public var parentID: String?
    public init(id: String, title: String, directory: String, parentID: String? = nil) {
        self.id = id; self.title = title; self.directory = directory; self.parentID = parentID
    }
}

// MARK: - Snapshot (what the UI and --dump show)

/// Machine status colour. Raw values order by severity.
public enum StatusLevel: Int, Comparable, Sendable {
    case green = 0, amber = 1, red = 2
    public static func < (a: StatusLevel, b: StatusLevel) -> Bool { a.rawValue < b.rawValue }
}

/// A group of processes of one kind inside a session (hover panel line), e.g. "Headless Chrome ×6".
public struct KindGroup: Sendable, Identifiable {
    public var id: String { kind }
    public var kind: String
    public var count: Int
    public var cpuPercent: Double
    public var memBytes: UInt64
    public var label: String { count > 1 ? "\(kind) ×\(count)" : kind }
}

public struct SessionRow: Sendable, Identifiable {
    /// Session id from the DB, or "folder:<path>" when the DB lookup failed.
    public var id: String
    public var title: String
    /// Project folder name shown in grey next to the title; nil = omitted.
    public var project: String?
    /// Worktree / folder name for the grey second line.
    public var folderName: String
    /// Folder revealed in Finder on click.
    public var folderPath: String
    public var activity: String
    public var runningSeconds: Int
    public var cpuPercent: Double
    public var memBytes: UInt64
    public var kinds: [KindGroup]
    public var processes: [ProcInfo]
    /// Why the session is listed: it runs programs, it is thinking (busy in OpenChamber, no
    /// programs), or it waits on active sub-sessions.
    public var state: SessionState = .processes
    /// Titles of the active descendant sessions (waiting rows only; shown in the hover panel).
    public var waitingFor: [String] = []
    /// Parent session id from the DB (for the "waiting" rule).
    public var parentID: String? = nil

    /// `wiki-w14 · browser tests · 6 min`
    public var subtitle: String {
        [folderName, activity, Format.duration(runningSeconds)].filter { !$0.isEmpty }.joined(separator: " · ")
    }
}

public enum SessionState: Int, Sendable {
    case processes = 0, thinking, waiting
}

/// A session row as read from `session_v2` for the listing rule (see SessionListing).
public struct DBSession: Sendable, Equatable {
    public var id: String
    public var title: String
    public var directory: String
    public var parentID: String?
    /// ms since 1970; nil when never set.
    public var timeBusy: Int64?
    public var timeIdle: Int64?
    /// Latest sign of life in ms: max(session time_updated, newest message).
    public var lastActivity: Int64
    public init(id: String, title: String, directory: String, parentID: String? = nil,
                timeBusy: Int64? = nil, timeIdle: Int64? = nil, lastActivity: Int64 = 0) {
        self.id = id; self.title = title; self.directory = directory; self.parentID = parentID
        self.timeBusy = timeBusy; self.timeIdle = timeIdle; self.lastActivity = lastActivity
    }
    /// OpenChamber's busy flag: busy more recently than idle.
    public var flaggedBusy: Bool { (timeBusy ?? 0) > (timeIdle ?? 0) }
}

/// A plain row (agent tools, other apps, everything else).
public struct SimpleRow: Sendable, Identifiable {
    public var id: String { name }
    public var name: String
    public var cpuPercent: Double
    public var memBytes: UInt64
    public var processes: [ProcInfo]
}

/// One of the two folded rows under "Everything that is not a session" ("Agent tools",
/// "Other apps"): a title, a grey line naming its members, summed numbers, and the items its
/// hover panel lists (all of them; nothing is hidden there).
public struct FoldedGroup: Sendable, Identifiable {
    public var id: String
    public var title: String
    public var panelTitle: String
    public var members: String
    public var cpuPercent: Double
    public var memBytes: UInt64
    public var items: [SimpleRow]
}

public struct Snapshot: Sendable {
    public var date: Date
    public var level: StatusLevel
    public var cpuLevel: StatusLevel
    public var memLevel: StatusLevel
    public var headline: String
    public var verdict: String
    public var load1: Double
    public var cores: Int
    public var memUsedBytes: UInt64
    public var memTotalBytes: UInt64
    public var pressureLevel: Int
    /// Whole-machine CPU busy in percent of one core (0 … cores×100).
    public var machineCPUPercent: Double
    public var sessions: [SessionRow]
    public var agentTools: [SimpleRow]
    public var otherApps: [SimpleRow]
    public var everythingElse: SimpleRow
    /// Sum of all listed rows' memory (for --dump sanity checks; footprints can exceed "Memory Used").
    public var listedMemBytes: UInt64
    public var listedCPUPercent: Double
    /// Non-fatal problems (e.g. DB unreadable) for --dump.
    public var notes: [String]
    /// Every app group found, including those too small to list (for --dump).
    public var allAppNames: [String] = []

    /// Folded "Agent tools" row: OpenChamber app + opencode server + opencode service + Claude Code.
    public var agentToolsGroup: FoldedGroup {
        var names: [String] = []
        for r in agentTools {
            let n: String
            switch r.name {
            case "OpenChamber app": n = "OpenChamber"
            case "opencode server", "opencode service": n = "opencode"
            default: n = r.name            // "Claude Code ×N"
            }
            if !names.contains(n) { names.append(n) }
        }
        return FoldedGroup(id: "folded:tools", title: "Agent tools", panelTitle: "Agent tools",
                           members: names.joined(separator: ", "),
                           cpuPercent: agentTools.reduce(0) { $0 + $1.cpuPercent },
                           memBytes: agentTools.reduce(0) { $0 + $1.memBytes }, items: agentTools)
    }

    /// Folded "Other apps" row: the named top apps in order, then Everything else.
    public var otherAppsGroup: FoldedGroup {
        let items = otherApps + [everythingElse]
        return FoldedGroup(id: "folded:other", title: "Other apps", panelTitle: "Other apps",
                           members: (otherApps.map(\.name) + ["everything else"]).joined(separator: ", "),
                           cpuPercent: items.reduce(0) { $0 + $1.cpuPercent },
                           memBytes: items.reduce(0) { $0 + $1.memBytes }, items: items)
    }

    /// Count shown next to the menu bar dot = number of session rows shown.
    public var sessionCount: Int { sessions.count }
}
