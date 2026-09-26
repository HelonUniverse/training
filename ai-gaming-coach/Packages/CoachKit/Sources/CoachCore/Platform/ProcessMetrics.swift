import Foundation
#if canImport(Darwin)
import Darwin
#endif

/// Coarse device heat level, mirroring `ProcessInfo.ThermalState`.
/// Ordered so the worst state of a session is `max`.
public enum ThermalState: String, Codable, Comparable, Sendable {
    case nominal, fair, serious, critical

    private var rank: Int {
        switch self {
        case .nominal: return 0
        case .fair: return 1
        case .serious: return 2
        case .critical: return 3
        }
    }

    public static func < (lhs: ThermalState, rhs: ThermalState) -> Bool { lhs.rank < rhs.rank }
}

/// One reading of the hosting process's resource use. Fields are nil where
/// the platform has no public API for them (e.g. on Linux).
public struct ProcessMetricsSample: Equatable, Sendable {
    public var memoryFootprintBytes: Int64?
    public var cpuPercent: Double?
    public var thermalState: ThermalState?

    public init(memoryFootprintBytes: Int64? = nil, cpuPercent: Double? = nil, thermalState: ThermalState? = nil) {
        self.memoryFootprintBytes = memoryFootprintBytes
        self.cpuPercent = cpuPercent
        self.thermalState = thermalState
    }
}

/// Samples memory, CPU and thermal state with public APIs only:
/// `task_info(TASK_VM_INFO)` for the physical footprint (the number jetsam
/// compares against the process limit), `task_threads` + `thread_info` for
/// CPU, and `ProcessInfo.thermalState`.
public enum ProcessMetrics {
    public static func sample() -> ProcessMetricsSample {
        #if canImport(Darwin)
        return ProcessMetricsSample(
            memoryFootprintBytes: memoryFootprint(),
            cpuPercent: cpuPercent(),
            thermalState: thermalState()
        )
        #else
        return ProcessMetricsSample()
        #endif
    }

    #if canImport(Darwin)
    static func memoryFootprint() -> Int64? {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
        let result = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        return result == KERN_SUCCESS ? Int64(info.phys_footprint) : nil
    }

    static func cpuPercent() -> Double? {
        var threads: thread_act_array_t?
        var threadCount = mach_msg_type_number_t(0)
        guard task_threads(mach_task_self_, &threads, &threadCount) == KERN_SUCCESS, let threads else { return nil }
        defer {
            vm_deallocate(mach_task_self_, vm_address_t(UInt(bitPattern: threads)),
                          vm_size_t(Int(threadCount) * MemoryLayout<thread_t>.stride))
        }
        var total = 0.0
        for index in 0..<Int(threadCount) {
            var info = thread_basic_info()
            var count = mach_msg_type_number_t(MemoryLayout<thread_basic_info>.size / MemoryLayout<integer_t>.size)
            let result = withUnsafeMutablePointer(to: &info) { pointer in
                pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                    thread_info(threads[index], thread_flavor_t(THREAD_BASIC_INFO), $0, &count)
                }
            }
            if result == KERN_SUCCESS, info.flags & TH_FLAGS_IDLE == 0 {
                total += Double(info.cpu_usage) / Double(TH_USAGE_SCALE) * 100
            }
            mach_port_deallocate(mach_task_self_, threads[index])
        }
        return total
    }

    static func thermalState() -> ThermalState? {
        switch ProcessInfo.processInfo.thermalState {
        case .nominal: return .nominal
        case .fair: return .fair
        case .serious: return .serious
        case .critical: return .critical
        @unknown default: return nil
        }
    }
    #endif
}

/// Host clock in seconds, the clock ReplayKit and ScreenCaptureKit stamp
/// sample buffers with (`CMClockGetHostTimeClock` is `mach_absolute_time`).
/// nil where unavailable, in which case latency is simply not measured.
public enum HostClock {
    #if canImport(Darwin)
    private static let secondsPerTick: Double = {
        var timebase = mach_timebase_info_data_t()
        mach_timebase_info(&timebase)
        return Double(timebase.numer) / Double(timebase.denom) / 1_000_000_000
    }()
    #endif

    public static func now() -> Double? {
        #if canImport(Darwin)
        return Double(mach_absolute_time()) * secondsPerTick
        #else
        return nil
        #endif
    }
}
