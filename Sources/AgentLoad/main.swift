import AppKit
import AgentLoadCore

// Entry point.
//   AgentLoad                       run the menu bar app
//   AgentLoad --dump [secs]         print one snapshot (two samples `secs` apart, default 3) and exit
//   AgentLoad --render-png <path> [--hover | --hover-tools | --hover-other | --hover-thinking | --hover-waiting] [--dark] [--mockup-data] [--swap <MB/s>]
//                                   render the dropdown from live data to a PNG and exit
let args = CommandLine.arguments

if args.contains("--dump") {
    let sampler = Sampler()
    let gap = args.firstIndex(of: "--dump").flatMap { i in i + 1 < args.count ? Double(args[i + 1]) : nil } ?? 3
    _ = sampler.sample(includeOtherUsers: true)
    Thread.sleep(forTimeInterval: gap)
    let snap = sampler.sample(includeOtherUsers: true)
    print(Dump.text(snap))
    exit(0)
}

if args.contains("--bench") {
    // Diagnostic: CPU cost of one refresh (process CPU time, not wall time).
    func cpuNow() -> Double { var u = rusage(); getrusage(RUSAGE_SELF, &u)
        return Double(u.ru_utime.tv_sec + u.ru_stime.tv_sec) + Double(u.ru_utime.tv_usec + u.ru_stime.tv_usec) / 1e6 }
    let sampler = Sampler()
    _ = sampler.sample(includeOtherUsers: true)
    for others in [false, true] {
        let c0 = cpuNow()
        for _ in 0..<(args.contains("--long") ? 300 : 10) { _ = sampler.sample(includeOtherUsers: others) }
        print("sample(includeOtherUsers: \(others)): \(String(format: "%.1f", (cpuNow() - c0) * 100)) ms CPU per refresh")
    }
    exit(0)
}

if args.contains("--verify-db") {
    // Diagnostic: proves that JSONEscape reproduces opencode's JSON text for recent commands.
    let db = SessionDB()
    let t0 = Date()
    let r = db.verifyEscaping(limit: 400)
    print("checked \(r.checked) shell commands, matched \(r.matched), with quotes/newlines/backslashes \(r.tricky), took \(String(format: "%.2f", Date().timeIntervalSince(t0))) s")
    for f in r.failures { print("  NO MATCH: \(f)") }
    if let e = db.lastError { print("DB error: \(e)") }
    exit(0)
}

if let i = args.firstIndex(of: "--render-png"), i + 1 < args.count {
    let app = NSApplication.shared
    app.setActivationPolicy(.prohibited)
    let ok = MainActor.assumeIsolated {
        Render.renderPNG(to: args[i + 1],
                         hover: args.contains("--hover") ? "session" : args.contains("--hover-tools") ? "folded:tools"
                             : args.contains("--hover-other") ? "folded:other"
                             : args.contains("--hover-thinking") ? "thinking" : args.contains("--hover-waiting") ? "waiting" : nil,
                          dark: args.contains("--dark"),
                         mockupData: args.contains("--mockup-data"),
                         swapMBps: args.firstIndex(of: "--swap").flatMap { i in i + 1 < args.count ? Double(args[i + 1]) : nil })
    }
    exit(ok ? 0 : 1)
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)   // no Dock icon (also LSUIElement in Info.plist)
app.run()
