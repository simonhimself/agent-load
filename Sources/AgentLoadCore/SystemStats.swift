import Foundation
import Darwin

/// Machine-wide totals: load, memory pressure, memory used, machine CPU.
public final class SystemStats {
    private var lastTicks: (busy: UInt64, total: UInt64)?
    private var lastSwap: (pages: UInt64, at: Date)?
    /// Machine CPU per interval (seconds, percent) over the last `cpuWindow` seconds.
    private var cpuHistory: [(dt: Double, cpu: Double)] = []
    private var lastCPUAt: Date?
    public static let cpuWindow: Double = 30
    /// Consecutive samples at or above `heavySwapRate`.
    private var heavySamples = 0
    /// Swapping at least this fast counts as heavy (bytes/s). Calm on the owner's Mac is
    /// well under 1 MB/s even with 11 GB sitting in swap.
    public static let heavySwapRate: Double = 30 * 1_000_000
    /// Heavy only after this many consecutive samples (≥ 6 s open, ≥ 20 s closed): "several seconds".
    public static let heavySamplesNeeded = 2
    public let cores: Int
    public let memTotal: UInt64

    public init() {
        cores = ProcessInfo.processInfo.activeProcessorCount
        memTotal = Self.sysctlUInt64("hw.memsize") ?? ProcessInfo.processInfo.physicalMemory
    }

    public func read() -> SystemTotals {
        var loads = [Double](repeating: 0, count: 3)
        getloadavg(&loads, 3)
        let swap = swapRate()
        heavySamples = swap >= Self.heavySwapRate ? heavySamples + 1 : 0
        let now = Date()
        let cpu = machineCPU()
        // Status uses a ~30 s average so a short spike (one build step) doesn't flip the dot,
        // while a machine that stays busy shows within half a minute.
        if let last = lastCPUAt, now > last { cpuHistory.append((now.timeIntervalSince(last), cpu)) }
        lastCPUAt = now
        var kept: [(dt: Double, cpu: Double)] = []; var span = 0.0
        for e in cpuHistory.reversed() where span < Self.cpuWindow { kept.insert(e, at: 0); span += e.dt }
        cpuHistory = kept
        let avg = span > 0 ? kept.reduce(0) { $0 + $1.dt * $1.cpu } / span : cpu
        return SystemTotals(load1: loads[0], cores: cores,
                            pressureLevel: Int(Self.sysctlInt32("kern.memorystatus_vm_pressure_level") ?? 1),
                            memUsedBytes: Self.memoryUsed(), memTotalBytes: memTotal,
                            machineCPUPercent: cpu,
                            swapBytesPerSec: swap, heavySwap: heavySamples >= Self.heavySamplesNeeded,
                            cpuAveragePercent: avg)
    }

    /// Swap-ins + swap-outs since the previous call, in bytes per second (0 on the first call).
    func swapRate(now: Date = Date()) -> Double {
        guard let (stats, pageSize) = Self.vmStats() else { return 0 }
        let pages = UInt64(stats.swapins) + UInt64(stats.swapouts)
        defer { lastSwap = (pages, now) }
        guard let last = lastSwap, pages >= last.pages else { return 0 }
        let dt = now.timeIntervalSince(last.at)
        guard dt > 0.2 else { return 0 }
        return Double(pages - last.pages) * Double(pageSize) / dt
    }

    static func vmStats() -> (vm_statistics64, UInt64)? {
        var stats = vm_statistics64()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64>.size / MemoryLayout<integer_t>.size)
        let kr = withUnsafeMutablePointer(to: &stats) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count)
            }
        }
        guard kr == KERN_SUCCESS else { return nil }
        var pageSize: vm_size_t = 0
        host_page_size(mach_host_self(), &pageSize)
        return (stats, UInt64(pageSize))
    }

    /// Activity Monitor's "Memory Used" = app memory (internal − purgeable) + wired + compressed.
    static func memoryUsed() -> UInt64 {
        var stats = vm_statistics64()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64>.size / MemoryLayout<integer_t>.size)
        let kr = withUnsafeMutablePointer(to: &stats) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count)
            }
        }
        guard kr == KERN_SUCCESS else { return 0 }
        var pageSize: vm_size_t = 0
        host_page_size(mach_host_self(), &pageSize)
        let app = UInt64(stats.internal_page_count) - min(UInt64(stats.internal_page_count), UInt64(stats.purgeable_count))
        let pages = app + UInt64(stats.wire_count) + UInt64(stats.compressor_page_count)
        return pages * UInt64(pageSize)
    }

    /// Machine CPU busy since the previous call, in percent of one core (0 … cores×100).
    func machineCPU() -> Double {
        var cpuCount: natural_t = 0
        var info: processor_info_array_t?
        var infoCount: mach_msg_type_number_t = 0
        guard host_processor_info(mach_host_self(), PROCESSOR_CPU_LOAD_INFO, &cpuCount, &info, &infoCount) == KERN_SUCCESS,
              let info else { return 0 }
        defer {
            vm_deallocate(mach_task_self_, vm_address_t(bitPattern: info),
                          vm_size_t(Int(infoCount) * MemoryLayout<integer_t>.stride))
        }
        var busy: UInt64 = 0, total: UInt64 = 0
        for c in 0..<Int(cpuCount) {
            let base = c * Int(CPU_STATE_MAX)
            let user = UInt64(UInt32(bitPattern: info[base + Int(CPU_STATE_USER)]))
            let sys = UInt64(UInt32(bitPattern: info[base + Int(CPU_STATE_SYSTEM)]))
            let nice = UInt64(UInt32(bitPattern: info[base + Int(CPU_STATE_NICE)]))
            let idle = UInt64(UInt32(bitPattern: info[base + Int(CPU_STATE_IDLE)]))
            busy += user + sys + nice
            total += user + sys + nice + idle
        }
        defer { lastTicks = (busy, total) }
        guard let last = lastTicks, total > last.total, busy >= last.busy else { return 0 }
        return Double(busy - last.busy) / Double(total - last.total) * Double(cpuCount) * 100
    }

    static func sysctlInt32(_ name: String) -> Int32? {
        var v: Int32 = 0; var size = MemoryLayout<Int32>.size
        return sysctlbyname(name, &v, &size, nil, 0) == 0 ? v : nil
    }
    static func sysctlUInt64(_ name: String) -> UInt64? {
        var v: UInt64 = 0; var size = MemoryLayout<UInt64>.size
        return sysctlbyname(name, &v, &size, nil, 0) == 0 ? v : nil
    }
}
