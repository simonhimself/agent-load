import Foundation

/// The agent tool ("harness") that runs a session. Each session row shows its official icon.
///
/// - OpenChamber / OpenCode share opencode's database. A session belongs to OpenChamber when
///   it or one of its ancestor sessions carries an `"openchamber"` key in `session_v2.metadata`
///   (OpenChamber writes it as soon as it creates a session; sub-sessions from before
///   2026-10 lack it themselves, hence the ancestor walk), or when its commands run under the
///   `opencode serve` that OpenChamber.app started. Everything else in the DB is OpenCode.
/// - Claude Code, Codex and Pi started on their own (in a terminal): their CLI process with no
///   opencode process among its ancestors. The CLI and all its descendants are one session.
public enum Harness: String, Sendable, CaseIterable {
    case openChamber, openCode, claudeCode, codex, pi

    public var displayName: String {
        switch self {
        case .openChamber: return "OpenChamber"
        case .openCode: return "OpenCode"
        case .claudeCode: return "Claude Code"
        case .codex: return "Codex"
        case .pi: return "Pi"
        }
    }
}

/// Recognises terminal harness CLIs in the process list. Pure.
public enum HarnessDetect {
    /// The script a node process runs: the first argument after argv[0] that is not a flag.
    static func nodeScript(_ p: ProcInfo) -> String? {
        guard p.exeName == "node" || p.name == "node" else { return nil }
        return p.argv.dropFirst().first { !$0.hasPrefix("-") }
    }

    public static func isCodex(_ p: ProcInfo) -> Bool {
        // `codex app-server` is the backend of the Codex / ChatGPT desktop apps, not a terminal session.
        if p.argv.contains("app-server") { return false }
        // Native binary (…/@openai/codex-darwin-arm64/vendor/…/bin/codex) or the npm wrapper
        // `/opt/homebrew/bin/codex` (a node script: argv = node /opt/homebrew/bin/codex …).
        if p.exeName == "codex" || p.name == "codex" { return true }
        if let s = nodeScript(p) { return (s as NSString).lastPathComponent == "codex" || s.contains("@openai/codex/") }
        return false
    }

    public static func isPi(_ p: ProcInfo) -> Bool {
        // npm package @earendil-works/pi-coding-agent; its bin is `pi`, run by node.
        if p.exeName == "pi" || p.name == "pi" { return true }
        if let s = nodeScript(p) { return (s as NSString).lastPathComponent == "pi" || s.contains("pi-coding-agent") }
        return false
    }

    /// Which terminal harness this process is, if any. CLIs bundled inside a desktop app
    /// (e.g. the Codex CLI inside ChatGPT.app) are that app's business, not terminal sessions.
    public static func terminalHarness(_ p: ProcInfo) -> Harness? {
        if p.isZombie || p.path.contains(".app/") { return nil }
        if Classifier.isClaude(p) { return .claudeCode }
        if isCodex(p) { return .codex }
        if isPi(p) { return .pi }
        return nil
    }

    /// Any opencode process (server, service, pty daemon, TUI): a harness below one of these
    /// is driven by OpenChamber / OpenCode and keeps its old place ("Claude Code ×N").
    public static func isOpencodeProcess(_ p: ProcInfo) -> Bool {
        p.exeName == "opencode" || p.name == "opencode" || Classifier.isPtyDaemon(p)
    }

    /// A shell running one command for an agent: `zsh -c …`, `zsh -lc …`, `bash -c -l …`.
    public static func isCommandShell(_ p: ProcInfo) -> Bool {
        guard Activity.shells.contains(p.exeName) else { return false }
        return p.argv.dropFirst().contains { $0.hasPrefix("-") && !$0.hasPrefix("--") && $0.contains("c") }
    }

    /// Claude Code's transcript folder name: every character other than a letter or digit
    /// becomes "-" (`/Users/me/.config/x` → `-Users-me--config-x`; checked against 81 real folders).
    public static func claudeFolderName(cwd: String) -> String {
        String(cwd.unicodeScalars.map { (CharacterSet.alphanumerics.contains($0) && $0.isASCII) ? Character($0) : "-" })
    }

    /// Pi's session folder name (docs/session-format.md): `--<cwd without the leading slash,
    /// "/", "\" and ":" replaced by "-">--`.
    public static func piFolderName(cwd: String) -> String {
        var s = cwd
        if s.hasPrefix("/") { s.removeFirst() }
        s = String(s.map { "/\\:".contains($0) ? "-" : $0 })
        return "--\(s)--"
    }

    /// Value of the first of `flags` in argv (`--resume abc` or `--resume=abc`).
    public static func argValue(_ argv: [String], _ flags: [String]) -> String? {
        for (i, a) in argv.enumerated() {
            for f in flags {
                if a == f, i + 1 < argv.count, !argv[i + 1].hasPrefix("-") { return argv[i + 1] }
                if a.hasPrefix(f + "=") { return String(a.dropFirst(f.count + 1)) }
            }
        }
        return nil
    }

    /// When a terminal harness row is shown (owner, 2026-11-14): only while it works, i.e. its
    /// processes used ≥ 1% CPU in the last sample, or its transcript was written in the last
    /// 2 minutes. A harness left open waiting for the user disappears.
    public static let workingCPU = 1.0
    public static let recentTranscriptMs: Int64 = 120_000
    public static func isWorking(cpuPercent: Double, transcriptModifiedMs: Int64?, nowMs: Int64) -> Bool {
        if cpuPercent >= workingCPU { return true }
        if let m = transcriptModifiedMs, nowMs - m <= recentTranscriptMs { return true }
        return false
    }
}

// MARK: - Transcripts

/// What the app learns from a terminal harness's transcript.
public struct TranscriptInfo: Sendable, Equatable {
    public var path: String
    /// Session title (explicit name, generated title, or the first user message), nil if none.
    public var title: String?
    /// Time of the last real user message (ms since 1970).
    public var lastUserMs: Int64?
    /// File modification time (ms since 1970).
    public var modifiedMs: Int64
    public init(path: String, title: String?, lastUserMs: Int64?, modifiedMs: Int64) {
        self.path = path; self.title = title; self.lastUserMs = lastUserMs; self.modifiedMs = modifiedMs
    }
}

/// Running result of scanning transcript lines (head, then appended lines).
public struct TranscriptScan: Sendable, Equatable {
    /// A name the user gave (Claude Code `custom-title`, Pi `session_info`). Latest wins.
    public var name: String?
    /// A generated title (Claude Code `ai-title` / `summary`). Latest wins.
    public var autoTitle: String?
    public var firstUser: String?
    public var lastUserMs: Int64?
    /// Codex: session id from `session_meta` (for the session index).
    public var sessionID: String?
    public init() {}

    public var title: String? { name ?? autoTitle ?? firstUser }
}

/// Parses transcript lines of the three terminal harnesses. Pure (no file access).
public enum TranscriptParser {
    /// Only lines containing one of these are JSON-decoded (lines can be megabytes long).
    static func needles(_ h: Harness) -> [String] {
        switch h {
        case .claudeCode: return ["\"custom-title\"", "\"ai-title\"", "\"type\":\"summary\"", "\"type\":\"user\""]
        case .codex: return ["\"session_meta\"", "\"user_message\"", "\"role\":\"user\""]
        case .pi: return ["\"session_info\"", "\"role\":\"user\""]
        default: return []
        }
    }

    /// Lines longer than this are skipped (tool output blobs); titles and prompts are short.
    static let maxLine = 512 * 1024

    public static func scan(_ text: Substring, harness h: Harness, into s: inout TranscriptScan) {
        let needles = needles(h)
        for line in text.split(separator: "\n", omittingEmptySubsequences: true) {
            guard line.utf8.count <= maxLine, needles.contains(where: { line.contains($0) }) else { continue }
            guard let obj = (try? JSONSerialization.jsonObject(with: Data(line.utf8))) as? [String: Any] else { continue }
            switch h {
            case .claudeCode: claudeLine(obj, &s)
            case .codex: codexLine(obj, &s)
            case .pi: piLine(obj, &s)
            default: break
            }
        }
    }

    // Claude Code: ~/.claude/projects/<folder>/<sessionId>.jsonl
    static func claudeLine(_ o: [String: Any], _ s: inout TranscriptScan) {
        switch o["type"] as? String {
        case "custom-title": if let t = nonEmpty(o["customTitle"]) { s.name = t }
        case "ai-title": if let t = nonEmpty(o["aiTitle"]) { s.autoTitle = t }
        case "summary": if let t = nonEmpty(o["summary"]) { s.autoTitle = t }
        case "user":
            guard o["isMeta"] as? Bool != true, o["isSidechain"] as? Bool != true,
                  let msg = o["message"] as? [String: Any], let text = userText(msg["content"]) else { return }
            if s.firstUser == nil { s.firstUser = oneLine(text) }
            if let ms = isoMs(o["timestamp"]) { s.lastUserMs = ms }
        default: break
        }
    }

    // Codex: ~/.codex/sessions/YYYY/MM/DD/rollout-…-<id>.jsonl
    static func codexLine(_ o: [String: Any], _ s: inout TranscriptScan) {
        guard let p = o["payload"] as? [String: Any] else { return }
        let type = o["type"] as? String
        if type == "session_meta" { if let id = p["id"] as? String { s.sessionID = id }; return }
        var text: String?
        if type == "event_msg", p["type"] as? String == "user_message" {
            text = (p["message"] as? String).flatMap(cleanUser)
        } else if type == "response_item", p["type"] as? String == "message", p["role"] as? String == "user" {
            text = userText(p["content"])
        }
        guard let text else { return }
        if s.firstUser == nil { s.firstUser = oneLine(text) }
        if let ms = isoMs(o["timestamp"]) { s.lastUserMs = max(s.lastUserMs ?? 0, ms) }
    }

    // Pi: ~/.pi/agent/sessions/--<cwd>--/<timestamp>_<id>.jsonl
    static func piLine(_ o: [String: Any], _ s: inout TranscriptScan) {
        switch o["type"] as? String {
        case "session_info": s.name = nonEmpty(o["name"])     // /name; an empty name clears it
        case "message":
            guard let msg = o["message"] as? [String: Any], msg["role"] as? String == "user",
                  let text = userText(msg["content"]) else { return }
            if s.firstUser == nil { s.firstUser = oneLine(text) }
            if let ms = isoMs(o["timestamp"]) ?? (msg["timestamp"] as? NSNumber)?.int64Value { s.lastUserMs = ms }
        default: break
        }
    }

    /// Text the user typed: a string, or the first text block of a content array. Injected
    /// context (`<system-reminder>`, `<environment_context>`, `# AGENTS.md …`) and tool
    /// results are not user messages.
    static func userText(_ content: Any?) -> String? {
        if let s = content as? String { return cleanUser(s) }
        guard let blocks = content as? [[String: Any]] else { return nil }
        if blocks.contains(where: { $0["type"] as? String == "tool_result" }) { return nil }
        for b in blocks {
            let t = b["type"] as? String
            guard t == "text" || t == "input_text", let s = b["text"] as? String, let c = cleanUser(s) else { continue }
            return c
        }
        return nil
    }

    static func cleanUser(_ s: String) -> String? {
        let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
        if t.isEmpty || t.hasPrefix("<") || t.hasPrefix("# AGENTS.md") || t.hasPrefix("Caveat:") { return nil }
        return t
    }

    static func nonEmpty(_ v: Any?) -> String? {
        guard let s = (v as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !s.isEmpty else { return nil }
        return s
    }

    /// First line, at most 80 characters (the row truncates further).
    static func oneLine(_ s: String) -> String {
        let first = s.split(whereSeparator: \.isNewline).first.map(String.init) ?? s
        return first.count > 80 ? String(first.prefix(79)) + "…" : first
    }

    private static let iso: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter(); f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]; return f
    }()
    private static let isoPlain = ISO8601DateFormatter()
    static func isoMs(_ v: Any?) -> Int64? {
        guard let s = v as? String, let d = iso.date(from: s) ?? isoPlain.date(from: s) else { return nil }
        return Int64(d.timeIntervalSince1970 * 1000)
    }

    /// Codex session index (`~/.codex/session_index.jsonl`): id → thread name; later lines win.
    public static func codexIndex(_ text: Substring) -> [String: String] {
        var out: [String: String] = [:]
        for line in text.split(separator: "\n") where line.contains("\"thread_name\"") {
            guard let o = (try? JSONSerialization.jsonObject(with: Data(line.utf8))) as? [String: Any],
                  let id = o["id"] as? String, let n = nonEmpty(o["thread_name"]) else { continue }
            out[id] = n
        }
        return out
    }
}
