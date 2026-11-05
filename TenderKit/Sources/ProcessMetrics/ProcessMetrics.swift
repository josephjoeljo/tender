import Darwin
import Foundation
import TenderCore

/// One libproc reading of a process.
public struct ProcessSample: Sendable, Equatable {
    /// User + system CPU time since the process started.
    public var cpuNanoseconds: UInt64
    public var residentBytes: UInt64
    public var startTime: Date
    /// Physical footprint: what Activity Monitor shows as the process's memory.
    public var footprintBytes: UInt64?
    public var peakFootprintBytes: UInt64?
    public var diskReadBytes: UInt64?
    public var diskWriteBytes: UInt64?
    public var energyNanojoules: UInt64?
    public var neuralFootprintBytes: UInt64?
    /// Package idle wakeups plus interrupt wakeups since the process started.
    public var wakeups: UInt64?
    public var threads: Int?
    public var openFiles: Int?

    public init(cpuNanoseconds: UInt64, residentBytes: UInt64, startTime: Date,
                footprintBytes: UInt64? = nil, peakFootprintBytes: UInt64? = nil,
                diskReadBytes: UInt64? = nil, diskWriteBytes: UInt64? = nil,
                energyNanojoules: UInt64? = nil, neuralFootprintBytes: UInt64? = nil,
                wakeups: UInt64? = nil, threads: Int? = nil, openFiles: Int? = nil) {
        self.cpuNanoseconds = cpuNanoseconds
        self.residentBytes = residentBytes
        self.startTime = startTime
        self.footprintBytes = footprintBytes
        self.peakFootprintBytes = peakFootprintBytes
        self.diskReadBytes = diskReadBytes
        self.diskWriteBytes = diskWriteBytes
        self.energyNanojoules = energyNanojoules
        self.neuralFootprintBytes = neuralFootprintBytes
        self.wakeups = wakeups
        self.threads = threads
        self.openFiles = openFiles
    }

    /// Returns nil if the process is gone or belongs to another user.
    public static func read(pid: Int32) -> ProcessSample? {
        var usage = rusage_info_v6()
        let usageResult = withUnsafeMutablePointer(to: &usage) {
            $0.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) {
                proc_pid_rusage(pid, RUSAGE_INFO_V6, $0)
            }
        }
        guard usageResult == 0 else { return nil }

        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size else { return nil }

        // ri_*_time is in mach absolute time units on Apple Silicon, not nanoseconds.
        var timebase = mach_timebase_info_data_t()
        mach_timebase_info(&timebase)
        let ticks = usage.ri_user_time &+ usage.ri_system_time
        let nanoseconds = ticks.multipliedReportingOverflow(by: UInt64(timebase.numer)).partialValue
            / UInt64(max(timebase.denom, 1))

        var task = proc_taskinfo()
        let taskSize = Int32(MemoryLayout<proc_taskinfo>.size)
        let threads = proc_pidinfo(pid, PROC_PIDTASKINFO, 0, &task, taskSize) == taskSize
            ? Int(task.pti_threadnum) : nil

        return ProcessSample(
            cpuNanoseconds: nanoseconds,
            residentBytes: usage.ri_resident_size,
            startTime: Date(timeIntervalSince1970: TimeInterval(info.pbi_start_tvsec)
                + TimeInterval(info.pbi_start_tvusec) / 1_000_000),
            footprintBytes: usage.ri_phys_footprint,
            peakFootprintBytes: usage.ri_lifetime_max_phys_footprint,
            diskReadBytes: usage.ri_diskio_bytesread,
            diskWriteBytes: usage.ri_diskio_byteswritten,
            // Zero means the kernel doesn't account energy for this process, not that it used none.
            energyNanojoules: usage.ri_energy_nj == 0 ? nil : usage.ri_energy_nj,
            neuralFootprintBytes: usage.ri_neural_footprint,
            wakeups: usage.ri_pkg_idle_wkups &+ usage.ri_interrupt_wkups,
            threads: threads,
            openFiles: openFileCount(pid: pid)
        )
    }

    static func openFileCount(pid: Int32) -> Int? {
        // With no buffer, libproc returns a size with room to spare; the second call returns the real one.
        let estimate = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, nil, 0)
        guard estimate > 0 else { return nil }
        let stride = MemoryLayout<proc_fdinfo>.stride
        var buffer = [proc_fdinfo](repeating: proc_fdinfo(), count: Int(estimate) / stride + 1)
        let used = buffer.withUnsafeMutableBytes {
            proc_pidinfo(pid, PROC_PIDLISTFDS, 0, $0.baseAddress, Int32($0.count))
        }
        return used > 0 ? Int(used) / stride : nil
    }
}

public struct ProcessUsage: Sendable, Equatable {
    /// Percent of one core.
    public var cpu: Double
    public var rss: UInt64
    public var uptime: TimeInterval
    public var cpuSeconds: Double
    public var stats: ProcessStats
}

/// Turns cumulative counters (CPU, disk, energy, GPU) into rates. Rates are measured since
/// the previous reading of that pid, or over the process's lifetime on the first one.
public actor UsageSampler {
    private struct Baseline {
        var sample: ProcessSample
        var gpuNanoseconds: UInt64?
        var at: Date
    }

    private var previous: [Int32: Baseline] = [:]
    /// One IORegistry walk serves every pid sampled in the same pass.
    private var gpuSnapshot: (at: Date, times: [Int32: UInt64]?)?

    public init() {}

    public func usage(pid: Int32, now: Date = Date()) -> ProcessUsage? {
        guard let sample = ProcessSample.read(pid: pid) else {
            previous[pid] = nil
            return nil
        }
        return usage(pid: pid, sample: sample, gpuNanoseconds: gpuTime(pid: pid, now: now), now: now)
    }

    func usage(pid: Int32, sample: ProcessSample, gpuNanoseconds: UInt64? = nil, now: Date) -> ProcessUsage {
        let uptime = max(now.timeIntervalSince(sample.startTime), 0)
        var base = previous[pid]
        // A new start time means the pid was reused; CPU going backwards means the same.
        if let old = base, old.sample.startTime != sample.startTime
            || sample.cpuNanoseconds < old.sample.cpuNanoseconds
            || now.timeIntervalSince(old.at) <= 0.1 {
            base = nil
        }
        previous[pid] = Baseline(sample: sample, gpuNanoseconds: gpuNanoseconds, at: now)
        let elapsed = base.map { now.timeIntervalSince($0.at) } ?? uptime
        let hasBase = base != nil

        /// Per second since the baseline, or since the process started when there's none.
        func rate(_ current: UInt64?, _ before: UInt64?) -> Double? {
            guard let current, elapsed > 0 else { return nil }
            let start: UInt64? = hasBase ? before : 0
            guard let start, current >= start else { return nil }
            return Double(current - start) / elapsed
        }

        let cpu = (rate(sample.cpuNanoseconds, base?.sample.cpuNanoseconds) ?? 0) / 1e9 * 100
        let stats = ProcessStats(
            footprint: sample.footprintBytes,
            peakFootprint: sample.peakFootprintBytes,
            threads: sample.threads,
            openFiles: sample.openFiles,
            diskReadBytes: sample.diskReadBytes,
            diskWriteBytes: sample.diskWriteBytes,
            diskReadRate: rate(sample.diskReadBytes, base?.sample.diskReadBytes),
            diskWriteRate: rate(sample.diskWriteBytes, base?.sample.diskWriteBytes),
            gpuPercent: rate(gpuNanoseconds, base?.gpuNanoseconds).map { min($0 / 1e9 * 100, 100) },
            gpuSeconds: gpuNanoseconds.map { Double($0) / 1e9 },
            neuralFootprint: sample.neuralFootprintBytes,
            power: rate(sample.energyNanojoules, base?.sample.energyNanojoules).map { $0 / 1e9 },
            wakeupsPerSecond: rate(sample.wakeups, base?.sample.wakeups)
        )
        return ProcessUsage(cpu: cpu, rss: sample.residentBytes, uptime: uptime,
                            cpuSeconds: Double(sample.cpuNanoseconds) / 1e9, stats: stats)
    }

    /// GPU nanoseconds for a pid: 0 if it never opened the GPU, nil if the GPU can't be read.
    private func gpuTime(pid: Int32, now: Date) -> UInt64? {
        if gpuSnapshot == nil || now.timeIntervalSince(gpuSnapshot!.at) > 1 {
            gpuSnapshot = (now, GPUClients.timeByPID())
        }
        guard let times = gpuSnapshot?.times else { return nil }
        return times[pid] ?? 0
    }

    /// Forgets pids that are no longer of interest, so the table can't grow forever.
    public func retain(pids: Set<Int32>) {
        previous = previous.filter { pids.contains($0.key) }
    }
}
