import Foundation
import Darwin

/// Machine-wide totals: load, memory pressure, memory used, machine CPU.
public final class SystemStats {
    private var lastTicks: (busy: UInt64, total: UInt64)?
    public let cores: Int
    public let memTotal: UInt64

    public init() {
        cores = ProcessInfo.processInfo.activeProcessorCount
        memTotal = Self.sysctlUInt64("hw.memsize") ?? ProcessInfo.processInfo.physicalMemory
    }

    public func read() -> SystemTotals {
        var loads = [Double](repeating: 0, count: 3)
        getloadavg(&loads, 3)
        return SystemTotals(load1: loads[0], cores: cores,
                            pressureLevel: Int(Self.sysctlInt32("kern.memorystatus_vm_pressure_level") ?? 1),
                            memUsedBytes: Self.memoryUsed(), memTotalBytes: memTotal,
                            machineCPUPercent: machineCPU())
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
