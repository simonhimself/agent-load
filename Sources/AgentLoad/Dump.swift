import Foundation
import AgentLoadCore

/// `--dump`: prints the full snapshot as text, for checking attribution against `ps`.
enum Dump {
    static func text(_ s: Snapshot, verbose: Bool = true) -> String {
        var out: [String] = []
        func line(_ x: String) { out.append(x) }
        func cmd(_ p: ProcInfo) -> String {
            let c = p.argv.isEmpty ? (p.path.isEmpty ? p.name : p.path) : p.argv.joined(separator: " ")
            return String(c.prefix(160))
        }
        func procs(_ ps: [ProcInfo]) {
            for p in ps.sorted(by: { $0.pid < $1.pid }) {
                line(String(format: "      %6d %6d %6.1f%% %7.0f MB  %@%@", p.pid, p.ppid, p.cpuPercent,
                            Double(p.memBytes) / 1_048_576, p.isZombie ? "<zombie> " : "", cmd(p)))
            }
        }
        line("STATUS  \(s.level)  \(s.headline)  |  \(s.verdict)")
        line("CPU     \(Format.cores(load: s.cpuAveragePercent / 100, cores: s.cores)) in use (30 s avg; now \(Format.cpu(s.machineCPUPercent))  (load average \(String(format: "%.1f", s.load1)), not used for status))")
        line("MEMORY  \(Format.memory(used: s.memUsedBytes, total: s.memTotalBytes))  pressure level \(s.pressureLevel)  swap \(String(format: "%.2f", s.swapBytesPerSec / 1_000_000)) MB/s")
        line("ICON    ● \(s.sessionCount)")
        line("LISTED  cpu \(Format.cpu(s.listedCPUPercent))  mem \(Format.gb(s.listedMemBytes))  (vs machine \(Format.cpu(s.machineCPUPercent)) / \(Format.gb(s.memUsedBytes)))")
        for n in s.notes { line("NOTE    \(n)") }
        line("")
        line("SESSIONS")
        for r in s.sessions {
            line("  \(r.title)  [\(r.project ?? "-")]  <\(r.harness.displayName)>   \(Format.cpu(r.cpuPercent))  \(Format.gb(r.memBytes))   id=\(r.id)")
            line("    \(r.subtitle)    state=\(r.state)  folder=\(r.folderPath)")
            if !r.waitingFor.isEmpty { line("    waiting for: " + r.waitingFor.joined(separator: " | ")) }
            line("    hover: " + r.kinds.map { "\($0.label) \(Format.cpu($0.cpuPercent)) \(Format.gb($0.memBytes))" }.joined(separator: " | "))
            if verbose { procs(r.processes) }
        }
        line("AGENT TOOLS   (members: \(s.agentToolsGroup.members))")
        for p in s.toolParts { line("  · part of OpenChamber: \(p.name)   \(Format.cpu(p.cpuPercent))  \(Format.gb(p.memBytes))   (\(p.processes.count) processes)") }
        for r in s.agentTools {
            line("  \(r.name)   \(Format.cpu(r.cpuPercent))  \(Format.gb(r.memBytes))   (\(r.processes.count) processes)")
            if verbose { procs(r.processes.filter { !$0.isZombie }) }
        }
        line("OTHER APPS")
        line("  (all app groups: " + s.allAppNames.joined(separator: ", ") + ")")
        for r in s.otherApps {
            line("  \(r.name)   \(Format.cpu(r.cpuPercent))  \(Format.gb(r.memBytes))   (\(r.processes.count) processes)")
        }
        let e = s.everythingElse
        line("  \(e.name)   \(Format.cpu(e.cpuPercent))  \(Format.gb(e.memBytes))   (\(e.processes.count) processes)")
        if verbose {
            line("  heaviest unlisted processes:")
            procs(Array(e.processes.sorted { $0.cpuPercent > $1.cpuPercent }.prefix(15)))
        }
        return out.joined(separator: "\n")
    }
}
