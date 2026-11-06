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
    /// The descendants last seen under each root pid, so `retain` keeps their baselines too.
    private var trees: [Int32: Set<Int32>] = [:]
    /// One IORegistry walk serves every pid sampled in the same pass.
    private var gpuSnapshot: (at: Date, times: [Int32: UInt64]?)?

    public init() {}

    /// Usage of `pid` and every process under it. A service started through a wrapper script
    /// (`bash run.sh` → `java …`) does its work in the children, so the root pid alone says little.
    /// Each process keeps its own baseline, so children starting or exiting never make a rate
    /// jump or go negative; the counters of a child that has exited drop out of the totals.
    public func usage(pid: Int32, now: Date = Date()) -> ProcessUsage? {
        guard let sample = ProcessSample.read(pid: pid) else {
            previous[pid] = nil
            trees[pid] = nil
            return nil
        }
        let root = usage(pid: pid, sample: sample, gpuNanoseconds: gpuTime(pid: pid, now: now), now: now)
        var children: [ProcessUsage] = []
        var seen: Set<Int32> = []
        for child in ProcessTree.descendants(of: pid) {
            guard let childSample = ProcessSample.read(pid: child) else { previous[child] = nil; continue }
            seen.insert(child)
            children.append(usage(pid: child, sample: childSample,
                                  gpuNanoseconds: gpuTime(pid: child, now: now), now: now))
        }
        for gone in (trees[pid] ?? []).subtracting(seen) { previous[gone] = nil }
        trees[pid] = seen
        return ProcessUsage.combined(root: root, children: children)
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

    /// Forgets root pids that are no longer of interest, and their descendants, so the tables
    /// can't grow forever.
    public func retain(pids: Set<Int32>) {
        trees = trees.filter { pids.contains($0.key) }
        let keep = trees.values.reduce(pids) { $0.union($1) }
        previous = previous.filter { keep.contains($0.key) }
    }

    var baselineCount: Int { previous.count }
}

extension ProcessUsage {
    /// One process tree's usage: counters, rates and sizes add up; uptime is the root's.
    /// Peak footprint is the sum of each process's own peak, an upper bound for the tree.
    static func combined(root: ProcessUsage, children: [ProcessUsage]) -> ProcessUsage {
        guard !children.isEmpty else { return root }
        let all = [root] + children
        func sum<T: AdditiveArithmetic>(_ value: (ProcessStats) -> T?) -> T? {
            let values = all.compactMap { value($0.stats) }
            return values.isEmpty ? nil : values.reduce(.zero, +)
        }
        let stats = ProcessStats(
            footprint: sum(\.footprint),
            peakFootprint: sum(\.peakFootprint),
            threads: sum(\.threads),
            openFiles: sum(\.openFiles),
            diskReadBytes: sum(\.diskReadBytes),
            diskWriteBytes: sum(\.diskWriteBytes),
            diskReadRate: sum(\.diskReadRate),
            diskWriteRate: sum(\.diskWriteRate),
            gpuPercent: sum(\.gpuPercent).map { min($0, 100) },
            gpuSeconds: sum(\.gpuSeconds),
            neuralFootprint: sum(\.neuralFootprint),
            power: sum(\.power),
            wakeupsPerSecond: sum(\.wakeupsPerSecond)
        )
        return ProcessUsage(cpu: all.reduce(0) { $0 + $1.cpu },
                            rss: all.reduce(0) { $0 + $1.rss },
                            uptime: root.uptime,
                            cpuSeconds: all.reduce(0) { $0 + $1.cpuSeconds },
                            stats: stats)
    }
}

/// Walks a process's children through libproc.
public enum ProcessTree {
    /// Every descendant of `pid`, breadth first, at most `limit` of them (a fork bomb shouldn't
    /// stall a heartbeat). Processes of other users are listed too; reading them may still fail.
    public static func descendants(of pid: Int32, limit: Int = 256) -> [Int32] {
        var found: [Int32] = []
        var queue = [pid]
        var visited: Set<Int32> = [pid]
        while !queue.isEmpty, found.count < limit {
            let parent = queue.removeFirst()
            for child in children(of: parent) where visited.insert(child).inserted {
                found.append(child)
                queue.append(child)
                if found.count == limit { break }
            }
        }
        return found
    }

    static func children(of pid: Int32) -> [Int32] {
        // With no buffer, proc_listpids returns the bytes needed; leave room for new children.
        let needed = proc_listpids(UInt32(PROC_PPID_ONLY), UInt32(bitPattern: pid), nil, 0)
        guard needed > 0 else { return [] }
        var buffer = [Int32](repeating: 0, count: Int(needed) / MemoryLayout<Int32>.stride + 16)
        let used = buffer.withUnsafeMutableBytes {
            proc_listpids(UInt32(PROC_PPID_ONLY), UInt32(bitPattern: pid), $0.baseAddress, Int32($0.count))
        }
        guard used > 0 else { return [] }
        return buffer.prefix(Int(used) / MemoryLayout<Int32>.stride).filter { $0 > 0 && $0 != pid }
    }
}
