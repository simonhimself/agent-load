import Foundation

/// Status colour, headline and verdict, exactly per the table in docs/design.md.
///
/// - Memory pressure (kern.memorystatus_vm_pressure_level: 1 normal, 2 warning, 4 critical)
///   is the primary signal; 1-minute load average vs core count is second.
/// - Swap never changes the colour (it lingers after a crunch), so it is not an input.
public enum StatusRules {
    public struct Result: Equatable {
        public var level: StatusLevel
        public var cpuLevel: StatusLevel
        public var memLevel: StatusLevel
        public var headline: String
        public var verdict: String
    }

    public static func memLevel(pressure: Int) -> StatusLevel {
        if pressure >= 4 { return .red }
        if pressure >= 2 { return .amber }
        return .green
    }

    public static func cpuLevel(load: Double, cores: Int) -> StatusLevel {
        let c = Double(max(cores, 1))
        if load > 2 * c { return .red }
        if load > c { return .amber }
        return .green
    }

    /// `heavySwap`: memory has been swapping heavily for several seconds. That makes memory
    /// amber even while macOS still reports normal pressure (owner, 2026-11-14): heavy
    /// swapping is exactly when everything feels slow. Swap *size* is still never an input.
    public static func evaluate(pressure: Int, load: Double, cores: Int, heavySwap: Bool = false) -> Result {
        let pressureLevel = memLevel(pressure: pressure)
        let m = max(pressureLevel, heavySwap ? .amber : .green)
        let swapOnly = heavySwap && pressureLevel == .green
        let c = cpuLevel(load: load, cores: cores)
        let level = max(m, c)
        // The headline names the reason. Single-resource wording comes from the spec/mockup
        // ("memory is tight", "CPU is busy"); when both are not green it says "memory and CPU"
        // (our wording: the spec only says "memory, CPU, or both", and longer text gets cut off).
        let reason: String
        switch (m, c) {
        case (.green, _): reason = c == .red ? "CPU is overloaded" : "CPU is busy"
        case (_, .green): reason = m == .red ? "memory is critical" : swapOnly ? "memory is swapping" : "memory is tight"
        default: reason = "memory and CPU"
        }
        let reasons = [reason]
        switch level {
        case .green:
            return Result(level: level, cpuLevel: c, memLevel: m, headline: "Calm",
                          verdict: "Room for another session")
        case .amber:
            return Result(level: level, cpuLevel: c, memLevel: m,
                          headline: "Busy · " + reasons.joined(separator: ", "),
                          verdict: "Wait before starting another session")
        case .red:
            return Result(level: level, cpuLevel: c, memLevel: m,
                          headline: "Overloaded · " + reasons.joined(separator: ", "),
                          verdict: "Too much running: free something up")
        }
    }
}
