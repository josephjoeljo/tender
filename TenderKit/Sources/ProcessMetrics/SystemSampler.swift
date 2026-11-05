import Darwin
import Foundation
import TenderCore

/// Samples the whole machine for the heartbeat. Rates (CPU, disk, network) are measured
/// since the previous call; the first call reports CPU since boot and no rates.
public actor SystemSampler {
    private struct Counters {
        /// user, system, idle, nice ticks summed over all cores. 32-bit, so they wrap.
        var cpuTicks: [UInt32]?
        var disk: (read: UInt64, write: UInt64)?
        var interfaces: [String: (inBytes: UInt32, outBytes: UInt32)]
        var at: Date
    }

    private var previous: Counters?
    private let host = mach_host_self()
    private let power: PowerSampler?

    /// `experimentalPower` turns on IOReport power readings (CPU, GPU, Neural Engine, DRAM).
    public init(experimentalPower: Bool = false) {
        power = experimentalPower ? PowerSampler() : nil
    }

    public func sample(now: Date = Date()) -> NodeStats {
        let current = Counters(cpuTicks: Self.cpuTicks(host: host), disk: BlockStorage.totals(),
                               interfaces: Self.interfaceCounters(), at: now)
        let before = previous
        previous = current
        let elapsed = before.map { now.timeIntervalSince($0.at) } ?? 0

        func perSecond(_ delta: UInt64) -> Double? { elapsed > 0.1 ? Double(delta) / elapsed : nil }
        func rate(_ now: UInt64?, _ then: UInt64?) -> Double? {
            guard let now, let then, now >= then else { return nil }
            return perSecond(now - then)
        }

        var networkIn: Double?
        var networkOut: Double?
        if let before {
            var received: UInt64 = 0
            var sent: UInt64 = 0
            for (name, counters) in current.interfaces {
                guard let old = before.interfaces[name] else { continue }
                received += UInt64(counters.inBytes &- old.inBytes)
                sent += UInt64(counters.outBytes &- old.outBytes)
            }
            networkIn = perSecond(received)
            networkOut = perSecond(sent)
        }

        let memory = Self.memory(host: host)
        let gpu = GPUClients.utilization()
        let volume = try? URL(filePath: "/").resourceValues(forKeys: [
            .volumeTotalCapacityKey, .volumeAvailableCapacityForImportantUsageKey, .volumeAvailableCapacityKey,
        ])
        var loads = [Double](repeating: 0, count: 3)
        let loadCount = getloadavg(&loads, 3)
        let perfLevels = Self.sysctl("hw.nperflevels", Int32(0)) ?? 0

        return NodeStats(
            sampledAt: now,
            cpuPercent: Self.cpuPercent(now: current.cpuTicks, then: before?.cpuTicks),
            cpuCores: ProcessInfo.processInfo.activeProcessorCount,
            performanceCores: perfLevels >= 2 ? Self.sysctl("hw.perflevel0.logicalcpu", Int32(0)).map(Int.init) : nil,
            efficiencyCores: perfLevels >= 2 ? Self.sysctl("hw.perflevel1.logicalcpu", Int32(0)).map(Int.init) : nil,
            loadAverage: loadCount == 3 ? loads : [],
            memoryTotal: ProcessInfo.processInfo.physicalMemory,
            memoryUsed: memory?.used,
            memoryWired: memory?.wired,
            memoryCompressed: memory?.compressed,
            swapUsed: Self.sysctl("vm.swapusage", xsw_usage()).map { UInt64($0.xsu_used) },
            memoryPressure: Self.memoryPressure(),
            diskTotal: volume?.volumeTotalCapacity.map { UInt64(max($0, 0)) },
            diskFree: volume?.volumeAvailableCapacityForImportantUsage.map { UInt64(max($0, 0)) }
                ?? volume?.volumeAvailableCapacity.map { UInt64(max($0, 0)) },
            diskReadRate: rate(current.disk?.read, before?.disk?.read),
            diskWriteRate: rate(current.disk?.write, before?.disk?.write),
            networkInRate: networkIn,
            networkOutRate: networkOut,
            gpuPercent: gpu?.percent,
            gpuMemoryUsed: gpu?.memory,
            thermalState: Self.thermalState(),
            bootTime: Self.sysctl("kern.boottime", timeval()).map {
                Date(timeIntervalSince1970: TimeInterval($0.tv_sec) + TimeInterval($0.tv_usec) / 1_000_000)
            },
            power: power?.sample(now: now)?.stats
        )
    }

    // MARK: - Readings

    static func cpuTicks(host: mach_port_t) -> [UInt32]? {
        var load = host_cpu_load_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<host_cpu_load_info_data_t>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &load) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics(host, HOST_CPU_LOAD_INFO, $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return nil }
        let ticks = load.cpu_ticks
        return [ticks.0, ticks.1, ticks.2, ticks.3]
    }

    /// Busy share of all ticks. With no earlier reading, since boot.
    static func cpuPercent(now: [UInt32]?, then: [UInt32]?) -> Double? {
        guard let now, now.count == 4 else { return nil }
        let base = then?.count == 4 ? then! : [0, 0, 0, 0]
        let delta = zip(now, base).map { UInt64($0 &- $1) }
        let busy = delta[0] + delta[1] + delta[3]
        let total = busy + delta[2]
        return total > 0 ? Double(busy) / Double(total) * 100 : nil
    }

    /// Activity Monitor's "Memory Used": app memory (anonymous, minus purgeable) + wired + compressed.
    static func memory(host: mach_port_t) -> (used: UInt64, wired: UInt64, compressed: UInt64)? {
        var stats = vm_statistics64_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64_data_t>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &stats) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(host, HOST_VM_INFO64, $0, &count)
            }
        }
        var pageSize: vm_size_t = 0
        guard result == KERN_SUCCESS, host_page_size(host, &pageSize) == KERN_SUCCESS else { return nil }
        let page = UInt64(pageSize)
        let anonymous = UInt64(stats.internal_page_count)
        let app = anonymous - min(UInt64(stats.purgeable_count), anonymous)
        let wired = UInt64(stats.wire_count) * page
        let compressed = UInt64(stats.compressor_page_count) * page
        return (app * page + wired + compressed, wired, compressed)
    }

    static func memoryPressure() -> MemoryPressure? {
        switch Self.sysctl("kern.memorystatus_vm_pressure_level", Int32(0)) {
        case 1: .normal
        case 2: .warning
        case 4: .critical
        default: nil
        }
    }

    static func thermalState() -> String? {
        switch ProcessInfo.processInfo.thermalState {
        case .nominal: "nominal"
        case .fair: "fair"
        case .serious: "serious"
        case .critical: "critical"
        @unknown default: nil
        }
    }

    /// Byte counters of physical interfaces (Ethernet and Wi-Fi). Tunnels like Tailscale's
    /// utun are left out, since their traffic also crosses a physical interface.
    static func interfaceCounters() -> [String: (inBytes: UInt32, outBytes: UInt32)] {
        var result: [String: (inBytes: UInt32, outBytes: UInt32)] = [:]
        var first: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&first) == 0 else { return result }
        defer { freeifaddrs(first) }
        var cursor = first
        while let entry = cursor {
            cursor = entry.pointee.ifa_next
            let flags = Int32(bitPattern: entry.pointee.ifa_flags)
            guard let address = entry.pointee.ifa_addr, address.pointee.sa_family == UInt8(AF_LINK),
                  flags & IFF_UP != 0, flags & IFF_LOOPBACK == 0,
                  let data = entry.pointee.ifa_data?.assumingMemoryBound(to: if_data.self).pointee,
                  data.ifi_type == 0x06 // IFT_ETHER
            else { continue }
            result[String(cString: entry.pointee.ifa_name)] = (data.ifi_ibytes, data.ifi_obytes)
        }
        return result
    }

    static func sysctl<T>(_ name: String, _ initial: T) -> T? {
        var value = initial
        var size = MemoryLayout<T>.size
        guard sysctlbyname(name, &value, &size, nil, 0) == 0 else { return nil }
        return value
    }
}
