import Foundation
import Darwin

/// Reads the process table in-process (no shelling out), with per-process CPU deltas.
///
/// - Process list, ppid, uid, start time, short name: `sysctl(KERN_PROC_ALL)`. This works for
///   every process, including root-owned ones, which libproc's PROC_PIDTBSDINFO refuses.
/// - CPU + memory for our own processes: `proc_pid_rusage(RUSAGE_INFO_V4)`;
///   memory = `ri_phys_footprint` (what Activity Monitor shows), CPU = user+system time.
///   On Apple Silicon those times are Mach ticks (timebase 125/3), converted to ns.
/// - Other users' processes (e.g. Spotlight's `mds` as root, `mds_stores` as _mds_stores)
///   cannot be read via libproc (EPERM, verified). For them we run ONE
///   `/bin/ps -o pid=,time=,rss= -p <pids>` per refresh (ps is setuid root), and only when
///   asked (`includeOtherUsers`), i.e. while the dropdown is open. Their memory is RSS.
/// - argv (`KERN_PROCARGS2`) and executable path are cached per (pid, start time).
public final class ProcessReader {
    private struct Static { var path: String; var argv: [String]; var responsiblePath: String }

    /// `responsibility_get_pid_responsible_for_pid` (libSystem, not in public headers; it is
    /// what Activity Monitor uses to group helpers under their app). Looked up at runtime so a
    /// future macOS without it just loses the grouping instead of failing to launch.
    private typealias ResponsibleFn = @convention(c) (pid_t) -> pid_t
    private static let responsibleFn: ResponsibleFn? = {
        guard let sym = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "responsibility_get_pid_responsible_for_pid") else { return nil }
        return unsafeBitCast(sym, to: ResponsibleFn.self)
    }()
    private var staticCache: [ProcKey: Static] = [:]
    /// Last cumulative CPU time (ns) per process, for deltas.
    private var lastCPU: [ProcKey: UInt64] = [:]
    private var lastSampleNanos: UInt64 = 0
    /// Wall clock of the previous sample (µs since 1970), to spot processes born since then.
    private var lastSampleWallMicros: Int64 = 0
    private let tickNumer: Double
    private let tickDenom: Double
    public let myUID = getuid()

    public init() {
        var tb = mach_timebase_info_data_t()
        mach_timebase_info(&tb)
        tickNumer = Double(tb.numer); tickDenom = Double(tb.denom)
    }

    /// Takes one sample. CPU% is relative to the previous call (0 on the first call).
    public func sample(includeOtherUsers: Bool) -> [ProcInfo] {
        let now = DispatchTime.now().uptimeNanoseconds
        let wall = lastSampleNanos == 0 ? 0 : Double(now - lastSampleNanos)
        lastSampleNanos = now
        let nowWall = Int64(Date().timeIntervalSince1970 * 1_000_000)
        let prevWall = lastSampleWallMicros
        lastSampleWallMicros = nowWall
        /// CPU% from a cumulative CPU time. A process born after the previous sample did all
        /// its work since its start, so it is measured over its own lifetime (otherwise every
        /// short-lived test browser would read 0%).
        func percent(_ key: ProcKey, _ ns: UInt64) -> Double {
            if wall > 0, let prev = lastCPU[key] { return ns >= prev ? Double(ns - prev) / wall * 100 : 0 }
            if prevWall > 0, key.startMicros > prevWall, nowWall > key.startMicros {
                // Lifetime of at least 1 s: a process a few ms old would otherwise read e.g.
                // 1353% from timing noise. Never more than all cores busy.
                let lifeNs = max(Double(nowWall - key.startMicros) * 1000, 1e9)
                return min(Double(ns) / lifeNs * 100, Double(ProcessInfo.processInfo.activeProcessorCount) * 100)
            }
            return 0
        }

        var procs = Self.kinfoAll()
        var newCPU: [ProcKey: UInt64] = [:]
        var othersNeedingPS: [Int] = []
        var newStatic: [ProcKey: Static] = [:]

        for i in procs.indices {
            let key = procs[i].key
            // Path / argv: cached; path works for other users too, argv only for ours.
            let st: Static
            if let c = staticCache[key] { st = c } else {
                let pid = procs[i].pid
                var resp = ""
                if let f = Self.responsibleFn, !procs[i].isZombie {
                    let r = f(pid)
                    if r > 0 && r != pid { resp = Self.path(r) }
                }
                st = Static(path: Self.path(pid),
                            argv: procs[i].uid == myUID && !procs[i].isZombie ? Self.argv(pid) : [],
                            responsiblePath: resp)
            }
            newStatic[key] = st
            procs[i].path = st.path
            procs[i].argv = st.argv
            procs[i].responsiblePath = st.responsiblePath
            procs[i].refreshExeName()
            if procs[i].isZombie { continue }

            if procs[i].uid == myUID, let ru = Self.rusage(procs[i].pid) {
                let ns = UInt64(Double(ru.ri_user_time &+ ru.ri_system_time) * tickNumer / tickDenom)
                newCPU[key] = ns
                procs[i].memBytes = ru.ri_phys_footprint
                procs[i].residentBytes = ru.ri_resident_size
                procs[i].cpuPercent = percent(key, ns)
            } else if procs[i].pid > 0 {
                othersNeedingPS.append(Int(procs[i].pid))
            }
        }

        if includeOtherUsers && !othersNeedingPS.isEmpty {
            let ps = Self.psTimes(pids: othersNeedingPS)
            for i in procs.indices {
                guard let (cpuNs, rss) = ps[procs[i].pid] else { continue }
                let key = procs[i].key
                newCPU[key] = cpuNs
                procs[i].memBytes = rss
                procs[i].residentBytes = rss
                procs[i].cpuPercent = percent(key, cpuNs)
            }
        }
        // Dropping entries for vanished processes keeps the caches bounded.
        staticCache = newStatic
        lastCPU = newCPU
        return procs
    }

    // MARK: - Low-level readers

    /// All processes via sysctl(KERN_PROC_ALL).
    static func kinfoAll() -> [ProcInfo] {
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_ALL, 0]
        var size = 0
        guard sysctl(&mib, 4, nil, &size, nil, 0) == 0 else { return [] }
        size += size / 8 + 16 * MemoryLayout<kinfo_proc>.stride   // room for new processes
        let count = size / MemoryLayout<kinfo_proc>.stride
        var buf = [kinfo_proc](repeating: kinfo_proc(), count: count)
        guard sysctl(&mib, 4, &buf, &size, nil, 0) == 0 else { return [] }
        let n = size / MemoryLayout<kinfo_proc>.stride
        var out: [ProcInfo] = []
        out.reserveCapacity(n)
        for k in buf.prefix(n) {
            let pid = k.kp_proc.p_pid
            let st = k.kp_proc.p_un.__p_starttime
            var comm = k.kp_proc.p_comm
            let name = withUnsafeBytes(of: &comm) { raw -> String in
                let b = raw.bindMemory(to: CChar.self)
                return String(cString: b.baseAddress!)
            }
            out.append(ProcInfo(pid: pid, ppid: k.kp_eproc.e_ppid, uid: k.kp_eproc.e_ucred.cr_uid,
                                startMicros: Int64(st.tv_sec) * 1_000_000 + Int64(st.tv_usec),
                                name: name, isZombie: k.kp_proc.p_stat == SZOMB))
        }
        return out
    }

    static func rusage(_ pid: Int32) -> rusage_info_v4? {
        var ru = rusage_info_v4()
        let r = withUnsafeMutablePointer(to: &ru) {
            $0.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { proc_pid_rusage(pid, RUSAGE_INFO_V4, $0) }
        }
        return r == 0 ? ru : nil
    }

    static func path(_ pid: Int32) -> String {
        var buf = [CChar](repeating: 0, count: Int(MAXPATHLEN) * 4)
        let n = proc_pidpath(pid, &buf, UInt32(buf.count))
        return n > 0 ? String(cString: buf) : ""
    }

    /// Current working directory via PROC_PIDVNODEPATHINFO (own processes only).
    /// This reads kernel metadata, not files, so it does not trigger folder privacy prompts.
    public static func cwd(_ pid: Int32) -> String {
        var vi = proc_vnodepathinfo()
        let size = Int32(MemoryLayout<proc_vnodepathinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDVNODEPATHINFO, 0, &vi, size) == size else { return "" }
        return withUnsafeBytes(of: &vi.pvi_cdir.vip_path) { raw in
            String(cString: raw.bindMemory(to: CChar.self).baseAddress!)
        }
    }

    /// argv via sysctl(KERN_PROCARGS2): [argc:int32][exec path\0][padding \0…][argv0\0argv1\0…][env…].
    static func argv(_ pid: Int32) -> [String] {
        var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
        var size = 0
        guard sysctl(&mib, 3, nil, &size, nil, 0) == 0, size > 4 else { return [] }
        var buf = [UInt8](repeating: 0, count: size)
        guard sysctl(&mib, 3, &buf, &size, nil, 0) == 0, size > 4 else { return [] }
        let argc = buf.withUnsafeBytes { $0.loadUnaligned(as: Int32.self) }
        var i = 4
        while i < size && buf[i] != 0 { i += 1 }       // skip exec path
        while i < size && buf[i] == 0 { i += 1 }       // skip padding
        var args: [String] = []
        var start = i
        while i < size && args.count < Int(argc) {
            if buf[i] == 0 {
                args.append(String(decoding: buf[start..<i], as: UTF8.self))
                start = i + 1
            }
            i += 1
        }
        return args
    }

    /// One `ps` call for processes we cannot read ourselves: pid → (cumulative CPU ns, RSS bytes).
    static func psTimes(pids: [Int]) -> [Int32: (UInt64, UInt64)] {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/ps")
        task.arguments = ["-o", "pid=,time=,rss=", "-p", pids.map(String.init).joined(separator: ",")]
        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = FileHandle.nullDevice
        do { try task.run() } catch { return [:] }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        task.waitUntilExit()
        var out: [Int32: (UInt64, UInt64)] = [:]
        for line in String(decoding: data, as: UTF8.self).split(separator: "\n") {
            let f = line.split(separator: " ", omittingEmptySubsequences: true)
            guard f.count >= 3, let pid = Int32(f[0]), let rssKB = UInt64(f[2]),
                  let secs = parsePSTime(String(f[1])) else { continue }
            out[pid] = (UInt64(secs * 1e9), rssKB * 1024)
        }
        return out
    }

    /// ps TIME column: `[[dd-]hh:]mm:ss.cc` → seconds.
    public static func parsePSTime(_ s: String) -> Double? {
        var days = 0.0
        var rest = Substring(s)
        if let dash = rest.firstIndex(of: "-") {
            guard let d = Double(rest[..<dash]) else { return nil }
            days = d; rest = rest[rest.index(after: dash)...]
        }
        let parts = rest.split(separator: ":").map { Double($0) }
        guard !parts.isEmpty, parts.allSatisfy({ $0 != nil }) else { return nil }
        var total = 0.0
        for p in parts { total = total * 60 + p! }
        return days * 86400 + total
    }
}
