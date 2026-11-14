import Foundation

/// Escapes a string the way JavaScript's `JSON.stringify` does (opencode runs on Bun and
/// stores messages with JSON.stringify), so a shell command taken from argv can be found
/// verbatim inside `session_message.data`.
///
/// Verified against the live DB: `"` → `\"`, `\` → `\\`, newline → `\n`; `/` and non-ASCII
/// characters (e.g. "›") are NOT escaped.
public enum JSONEscape {
    public static func escape(_ s: String) -> String {
        var out = ""
        out.reserveCapacity(s.utf8.count + 16)
        for u in s.unicodeScalars {
            switch u {
            case "\"": out += "\\\""
            case "\\": out += "\\\\"
            case "\n": out += "\\n"
            case "\r": out += "\\r"
            case "\t": out += "\\t"
            case "\u{08}": out += "\\b"
            case "\u{0C}": out += "\\f"
            default:
                if u.value < 0x20 {
                    out += String(format: "\\u%04x", u.value)
                } else {
                    out.unicodeScalars.append(u)
                }
            }
        }
        return out
    }

    /// The exact text we look for: the JSON field holding the command in a tool-call part,
    /// i.e. `..."state":{"status":"…","input":{"command":"<escaped>", ...`.
    /// Including the closing quote makes it an exact (not prefix) match.
    public static func commandNeedle(_ command: String) -> String {
        "\"command\":\"" + escape(command) + "\""
    }
}
