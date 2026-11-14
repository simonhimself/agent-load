import Foundation

public enum MockupData {
    /// The illustrative numbers from docs/mockup.html, for a pixel comparison with the mockup
    /// (`--render-png <path> --mockup-data`). Not used by the live app.
    public static func snapshot() -> Snapshot {
        let gb: (Double) -> UInt64 = { UInt64($0 * Format.gib) }
        func k(_ n: String, _ c: Int, _ cpu: Double, _ m: Double) -> KindGroup { KindGroup(kind: n, count: c, cpuPercent: cpu, memBytes: gb(m)) }
        func s(_ t: String, _ f: String, _ a: String, _ mins: Int, _ cpu: Double, _ m: Double, _ kinds: [KindGroup] = []) -> SessionRow {
            SessionRow(id: t, title: t, project: "my-app", folderName: f, folderPath: "", activity: a,
                       runningSeconds: mins * 60, cpuPercent: cpu, memBytes: gb(m), kinds: kinds, processes: [])
        }
        func r(_ n: String, _ cpu: Double, _ m: Double) -> SimpleRow { SimpleRow(name: n, cpuPercent: cpu, memBytes: gb(m), processes: []) }
        let st = StatusRules.evaluate(pressure: 2, load: 7.3, cores: 8)
        return Snapshot(date: Date(), level: st.level, cpuLevel: .amber, memLevel: st.memLevel, headline: st.headline,
                        // Same culprit rule as the live app: memory is short, Firefox (3.0 GB) uses the most.
                        verdict: SnapshotBuilder.culpritLine(name: "Firefox", cpuPercent: 12, memBytes: gb(3.0), byMemory: true),
                        load1: 7.3, cores: 8, memUsedBytes: gb(13.1), memTotalBytes: gb(16), pressureLevel: 2, machineCPUPercent: 600,
                        sessions: [s("W14 Images", "wiki-w14", "browser tests", 6, 210, 2.4,
                                     [k("Headless Chrome", 6, 120, 1.3), k("workerd", 1, 45, 0.4), k("Playwright runner", 1, 25, 0.3), k("vite", 1, 20, 0.4)]),
                                   s("W16 Comments", "wiki-w16", "browser tests", 3, 180, 2.1),
                                   s("T2 concurrent e2e measurement", "t2-measure-a", "build + preview", 1, 90, 0.9)],
                        agentTools: [r("OpenChamber app", 21, 1.2), r("opencode server", 4, 0.4), r("opencode service", 1, 0.3), r("Claude Code ×9", 25, 1.3)],
                        otherApps: [r("Firefox", 12, 3.0), r("Spotlight indexing", 60, 0.2)], everythingElse: r("Everything else", 20, 1.9),
                        listedMemBytes: 0, listedCPUPercent: 0, notes: [])
    }
}
