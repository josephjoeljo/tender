import Foundation

/// Detailed resource use of one process, sampled by its node. Every field is optional:
/// a reading the node couldn't take is left out rather than reported as zero.
public struct ProcessStats: Codable, Sendable, Equatable {
    /// Memory as Activity Monitor's "Memory" column shows it (physical footprint), in bytes.
    public var footprint: UInt64?
    /// Highest footprint since the process started.
    public var peakFootprint: UInt64?
    public var threads: Int?
    public var openFiles: Int?
    /// Bytes read and written to storage since the process started.
    public var diskReadBytes: UInt64?
    public var diskWriteBytes: UInt64?
    /// Bytes per second since the previous sample.
    public var diskReadRate: Double?
    public var diskWriteRate: Double?
    /// Percent of the GPU's time used by this process since the previous sample.
    public var gpuPercent: Double?
    /// GPU time since the process opened the GPU, in seconds.
    public var gpuSeconds: Double?
    /// Memory attributed to the Neural Engine, in bytes. Nonzero means the process has ANE work loaded.
    public var neuralFootprint: UInt64?
    /// Average power since the previous sample, in watts.
    public var power: Double?
    /// Idle and interrupt wakeups per second, the main cause of energy use on an idle Mac.
    public var wakeupsPerSecond: Double?

    public init(footprint: UInt64? = nil, peakFootprint: UInt64? = nil, threads: Int? = nil, openFiles: Int? = nil,
                diskReadBytes: UInt64? = nil, diskWriteBytes: UInt64? = nil,
                diskReadRate: Double? = nil, diskWriteRate: Double? = nil,
                gpuPercent: Double? = nil, gpuSeconds: Double? = nil, neuralFootprint: UInt64? = nil,
                power: Double? = nil, wakeupsPerSecond: Double? = nil) {
        self.footprint = footprint
        self.peakFootprint = peakFootprint
        self.threads = threads
        self.openFiles = openFiles
        self.diskReadBytes = diskReadBytes
        self.diskWriteBytes = diskWriteBytes
        self.diskReadRate = diskReadRate
        self.diskWriteRate = diskWriteRate
        self.gpuPercent = gpuPercent
        self.gpuSeconds = gpuSeconds
        self.neuralFootprint = neuralFootprint
        self.power = power
        self.wakeupsPerSecond = wakeupsPerSecond
    }
}

/// EXPERIMENTAL. Average power by domain, in watts, from IOReport (a private macOS API).
/// The Neural Engine figure is the only ANE signal Apple exposes: there's no occupancy counter.
public struct PowerStats: Codable, Sendable, Equatable {
    public var cpu: Double?
    public var gpu: Double?
    public var neuralEngine: Double?
    public var dram: Double?
    /// Sum of the domains above. Not whole-system power: it leaves out display, SSD, fans and so on.
    public var total: Double?

    public init(cpu: Double? = nil, gpu: Double? = nil, neuralEngine: Double? = nil, dram: Double? = nil,
                total: Double? = nil) {
        self.cpu = cpu
        self.gpu = gpu
        self.neuralEngine = neuralEngine
        self.dram = dram
        self.total = total
    }
}

public enum MemoryPressure: String, Codable, Sendable {
    case normal, warning, critical
}

/// A node's whole-machine resource use, sent with each heartbeat.
public struct NodeStats: Codable, Sendable, Equatable {
    /// The node's clock when this was sampled.
    public var sampledAt: Date
    /// Whole-machine CPU busy, 0–100, since the previous sample.
    public var cpuPercent: Double?
    public var cpuCores: Int
    public var performanceCores: Int?
    public var efficiencyCores: Int?
    /// 1, 5 and 15 minute load averages.
    public var loadAverage: [Double]
    public var memoryTotal: UInt64
    /// App memory + wired + compressed, as Activity Monitor's "Memory Used".
    public var memoryUsed: UInt64?
    public var memoryWired: UInt64?
    public var memoryCompressed: UInt64?
    public var swapUsed: UInt64?
    public var memoryPressure: MemoryPressure?
    /// The boot volume's container.
    public var diskTotal: UInt64?
    public var diskFree: UInt64?
    /// Bytes per second across all block storage, since the previous sample.
    public var diskReadRate: Double?
    public var diskWriteRate: Double?
    /// Bytes per second across physical (Ethernet and Wi-Fi) interfaces, since the previous sample.
    public var networkInRate: Double?
    public var networkOutRate: Double?
    /// GPU busy, 0–100, as the GPU driver reports it.
    public var gpuPercent: Double?
    public var gpuMemoryUsed: UInt64?
    /// `nominal`, `fair`, `serious` or `critical`.
    public var thermalState: String?
    public var bootTime: Date?
    /// Only from nodes running with `--experimental-power`.
    public var power: PowerStats?

    public init(sampledAt: Date, cpuPercent: Double? = nil, cpuCores: Int, performanceCores: Int? = nil,
                efficiencyCores: Int? = nil, loadAverage: [Double] = [], memoryTotal: UInt64,
                memoryUsed: UInt64? = nil, memoryWired: UInt64? = nil, memoryCompressed: UInt64? = nil,
                swapUsed: UInt64? = nil, memoryPressure: MemoryPressure? = nil,
                diskTotal: UInt64? = nil, diskFree: UInt64? = nil,
                diskReadRate: Double? = nil, diskWriteRate: Double? = nil,
                networkInRate: Double? = nil, networkOutRate: Double? = nil,
                gpuPercent: Double? = nil, gpuMemoryUsed: UInt64? = nil,
                thermalState: String? = nil, bootTime: Date? = nil, power: PowerStats? = nil) {
        self.power = power
        self.sampledAt = sampledAt
        self.cpuPercent = cpuPercent
        self.cpuCores = cpuCores
        self.performanceCores = performanceCores
        self.efficiencyCores = efficiencyCores
        self.loadAverage = loadAverage
        self.memoryTotal = memoryTotal
        self.memoryUsed = memoryUsed
        self.memoryWired = memoryWired
        self.memoryCompressed = memoryCompressed
        self.swapUsed = swapUsed
        self.memoryPressure = memoryPressure
        self.diskTotal = diskTotal
        self.diskFree = diskFree
        self.diskReadRate = diskReadRate
        self.diskWriteRate = diskWriteRate
        self.networkInRate = networkInRate
        self.networkOutRate = networkOutRate
        self.gpuPercent = gpuPercent
        self.gpuMemoryUsed = gpuMemoryUsed
        self.thermalState = thermalState
        self.bootTime = bootTime
    }
}
