import Foundation

/// Turns processes into human words: a "kind" per process (hover panel grouping, e.g.
/// "Headless Chrome") and an activity label per session (grey line, e.g. "browser tests").
public enum Activity {
    /// Activity tags, in priority order (lower = more important).
    public enum Tag: Int, Comparable, CaseIterable {
        case browserTests = 0, unitTests, build, preview, devServer
        public static func < (a: Tag, b: Tag) -> Bool { a.rawValue < b.rawValue }
        public var label: String {
            switch self {
            case .browserTests: return "browser tests"
            case .unitTests: return "unit tests"
            case .build: return "build"
            case .preview: return "preview"
            case .devServer: return "dev server"
            }
        }
    }

    /// Lower-cased "haystack" of path + argv used for pattern checks.
    static func haystack(_ p: ProcInfo) -> String {
        ([p.path] + p.argv.prefix(6)).joined(separator: " ").lowercased()
    }

    /// The script a node/bun process runs (argv[1] or the first non-flag argument), lower-cased.
    static func script(_ p: ProcInfo) -> String {
        for a in p.argv.dropFirst() where !a.hasPrefix("-") { return a.lowercased() }
        return ""
    }

    static let shells: Set<String> = ["zsh", "bash", "sh", "dash", "fish"]

    /// Kind name for the hover panel.
    public static func kind(of p: ProcInfo) -> String {
        let exe = p.exeName.lowercased()
        let h = haystack(p)
        if h.contains("chrome-headless-shell") || h.contains("ms-playwright") || h.contains("chrome for testing")
            || exe.hasPrefix("chromium") { return "Headless Chrome" }
        if exe == "workerd" { return "workerd" }
        if shells.contains(exe) { return "shell" }
        let s = script(p)
        if h.contains("playwright") && (s.contains("playwright") || exe == "playwright") { return "Playwright runner" }
        if s.contains("vitest") || exe == "vitest" { return "vitest" }
        if s.contains("/jest") || exe == "jest" { return "jest" }
        if s.contains("wrangler") || exe == "wrangler" { return "wrangler" }
        if s.contains("/vite/") || s.hasSuffix("vite.js") || exe == "vite" { return "vite" }
        if s.contains("typescript/bin/tsc") || s.hasSuffix("/tsc") || exe == "tsc" { return "tsc" }
        if exe == "esbuild" || h.contains("/esbuild ") { return "esbuild" }
        if ["pnpm", "npm", "npx", "yarn", "bun", "deno"].contains(exe) { return exe }
        if exe == "node" {
            // pnpm/npm run through node: node .../pnpm.cjs
            if s.contains("pnpm") { return "pnpm" }
            if s.contains("npm-cli") || s.hasSuffix("/npm") { return "npm" }
            return "node"
        }
        return p.exeName
    }

    /// Activity tag a single process implies, if any.
    public static func tag(of p: ProcInfo) -> Tag? {
        let k = kind(of: p)
        let args = p.argv.map { $0.lowercased() }
        switch k {
        case "Headless Chrome", "Playwright runner": return .browserTests
        case "vitest", "jest": return .unitTests
        case "tsc", "esbuild": return .build
        case "workerd", "wrangler": return .devServer
        case "vite":
            if args.contains("build") { return .build }
            if args.contains("preview") { return .preview }
            return .devServer
        default:
            return nil
        }
    }

    /// Session activity label. Tests are what the session is doing when present (their
    /// servers are test infrastructure), so they win alone; otherwise build / preview /
    /// dev server are combined, two at most ("build + preview"). "preview" already implies a
    /// running server, so it replaces "dev server". Fallback: the heaviest program's name.
    public static func label(for procs: [ProcInfo]) -> String {
        let tags = Set(procs.compactMap { tag(of: $0) })
        let tests = tags.filter { $0 == .browserTests || $0 == .unitTests }.sorted()
        if !tests.isEmpty { return tests.prefix(2).map(\.label).joined(separator: " + ") }
        var rest = tags.sorted()
        if rest.contains(.preview) { rest.removeAll { $0 == .devServer } }
        if !rest.isEmpty { return rest.prefix(2).map(\.label).joined(separator: " + ") }
        // Fallback: main program = heaviest non-shell process (CPU, then memory).
        let main = procs.filter { kind(of: $0) != "shell" && !$0.isZombie }
            .max { ($0.cpuPercent, Double($0.memBytes)) < ($1.cpuPercent, Double($1.memBytes)) }
        if let main { return kind(of: main) == "Headless Chrome" ? "browser" : main.exeName }
        return "shell"
    }

    /// Hover panel lines: processes grouped by kind, heaviest first.
    public static func groups(for procs: [ProcInfo]) -> [KindGroup] {
        var byKind: [String: KindGroup] = [:]
        for p in procs where !p.isZombie {
            let k = kind(of: p)
            var g = byKind[k] ?? KindGroup(kind: k, count: 0, cpuPercent: 0, memBytes: 0)
            g.count += 1; g.cpuPercent += p.cpuPercent; g.memBytes += p.memBytes
            byKind[k] = g
        }
        return byKind.values.sorted { ($0.cpuPercent, Double($0.memBytes)) > ($1.cpuPercent, Double($1.memBytes)) }
    }
}
