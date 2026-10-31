import Darwin
import Foundation

/// One libproc reading of a process.
public struct ProcessSample: Sendable, Equatable {
    /// User + system CPU time since the process started.
    public var cpuNanoseconds: UInt64
    public var residentBytes: UInt64
    public var startTime: Date

    public init(cpuNanoseconds: UInt64, residentBytes: UInt64, startTime: Date) {
        self.cpuNanoseconds = cpuNanoseconds
        self.residentBytes = residentBytes
        self.startTime = startTime
    }

    /// Returns nil if the process is gone or belongs to another user.
    public static func read(pid: Int32) -> ProcessSample? {
        var usage = rusage_info_v4()
        let usageResult = withUnsafeMutablePointer(to: &usage) {
            $0.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) {
                proc_pid_rusage(pid, RUSAGE_INFO_V4, $0)
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

        return ProcessSample(
            cpuNanoseconds: nanoseconds,
            residentBytes: usage.ri_resident_size,
            startTime: Date(timeIntervalSince1970: TimeInterval(info.pbi_start_tvsec)
                + TimeInterval(info.pbi_start_tvusec) / 1_000_000)
        )
    }
}

public struct ProcessUsage: Sendable, Equatable {
    /// Percent of one core.
    public var cpu: Double
    public var rss: UInt64
    public var uptime: TimeInterval
    public var cpuSeconds: Double
}

/// Turns cumulative CPU time into a rate. CPU is measured since the previous
/// reading of that pid, or over the process's lifetime on the first one.
public actor UsageSampler {
    private var previous: [Int32: (cpu: UInt64, at: Date)] = [:]

    public init() {}

    public func usage(pid: Int32, now: Date = Date()) -> ProcessUsage? {
        guard let sample = ProcessSample.read(pid: pid) else {
            previous[pid] = nil
            return nil
        }
        return usage(pid: pid, sample: sample, now: now)
    }

    func usage(pid: Int32, sample: ProcessSample, now: Date) -> ProcessUsage {
        let uptime = max(now.timeIntervalSince(sample.startTime), 0)
        let base = previous[pid]
        previous[pid] = (sample.cpuNanoseconds, now)

        var cpuDelta = sample.cpuNanoseconds
        var elapsed = uptime
        if let base, sample.cpuNanoseconds >= base.cpu, now.timeIntervalSince(base.at) > 0.1 {
            cpuDelta = sample.cpuNanoseconds - base.cpu
            elapsed = now.timeIntervalSince(base.at)
        }
        let cpu = elapsed > 0 ? Double(cpuDelta) / 1e9 / elapsed * 100 : 0
        return ProcessUsage(cpu: cpu, rss: sample.residentBytes, uptime: uptime,
                            cpuSeconds: Double(sample.cpuNanoseconds) / 1e9)
    }

    /// Forgets pids that are no longer of interest, so the table can't grow forever.
    public func retain(pids: Set<Int32>) {
        previous = previous.filter { pids.contains($0.key) }
    }
}
