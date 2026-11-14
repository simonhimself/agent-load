import Foundation

/// Number formatting shared by the dropdown and --dump, so both show identical text.
public enum Format {
    public static let gib = 1024.0 * 1024.0 * 1024.0

    /// "210%" (100% = one core).
    public static func cpu(_ pct: Double) -> String { "\(Int(pct.rounded()))%" }

    /// "2.4 GB" (GB as Activity Monitor counts it: 2^30 bytes).
    public static func gb(_ bytes: UInt64) -> String { String(format: "%.1f GB", Double(bytes) / gib) }

    /// Running time for the grey session line: "<1 min", "6 min", "1 h 5 min".
    public static func duration(_ seconds: Int) -> String {
        if seconds < 60 { return "<1 min" }
        let m = seconds / 60
        if m < 60 { return "\(m) min" }
        let h = m / 60, rm = m % 60
        return rm == 0 ? "\(h) h" : "\(h) h \(rm) min"
    }

    /// "7.3 of 8 cores"
    public static func cores(load: Double, cores: Int) -> String { String(format: "%.1f of %d cores", load, cores) }

    /// "13.1 of 16 GB"
    public static func memory(used: UInt64, total: UInt64) -> String {
        String(format: "%.1f of %d GB", Double(used) / gib, Int((Double(total) / gib).rounded()))
    }
}
