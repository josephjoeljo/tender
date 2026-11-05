import Foundation
import LaunchdKit
import ProcessMetrics
import TenderCore

public enum AdoptionError: Error, Equatable, CustomStringConvertible {
    case jobNotFound(String)
    case ownLabel(String)
    case invalidLabel(String)
    case noPlist(String)
    case systemJob(String)
    case notAdopted(String)

    public var description: String {
        switch self {
        case .jobNotFound(let label): "launchd has no job '\(label)' in this domain."
        case .ownLabel(let label): "'\(label)' is Tender's own job and can't be adopted."
        case .invalidLabel(let label): "'\(label)' isn't a valid launchd label."
        case .systemJob(let label): "'\(label)' belongs to macOS and can't be adopted."
        case .noPlist(let label): "'\(label)' has no plist on record, so Tender can't bootstrap it."
        case .notAdopted(let label): "Tender isn't managing a job labeled '\(label)'. `tender list` shows adopted jobs."
        }
    }
}

/// Lists and controls launchd jobs Tender didn't create. It only ever calls
/// launchctl: an adopted job's plist is never rewritten, its logs are never
/// rotated, and the reconciler doesn't touch it, so a stopped job stays stopped.
public struct Adoption: Sendable {
    let environment: TenderEnvironment
    let store: StateStore
    let launchd: any LaunchdControlling
    private let sampler = UsageSampler()

    public init(environment: TenderEnvironment, store: StateStore, launchd: any LaunchdControlling) {
        self.environment = environment
        self.store = store
        self.launchd = launchd
    }

    /// Records a loaded job. Adopting again refreshes the record.
    @discardableResult
    public func adopt(label: String, logPath: String? = nil) async throws -> AdoptedJob {
        guard !label.isEmpty, label.allSatisfy({ !$0.isWhitespace && $0 != "/" }) else {
            throw AdoptionError.invalidLabel(label)
        }
        guard !label.hasPrefix("\(environment.labelPrefix).") else { throw AdoptionError.ownLabel(label) }
        guard !label.hasPrefix("com.apple.") else { throw AdoptionError.systemJob(label) }
        guard let job = try await launchd.print(label: label) else { throw AdoptionError.jobNotFound(label) }
        let adopted = AdoptedJob(
            label: label,
            domain: LaunchdDomain.forEnvironment(environment).target,
            plistPath: job.plistPath,
            stdoutPath: logPath ?? job.stdoutPath,
            stderrPath: logPath == nil ? job.stderrPath : nil,
            logPath: logPath
        )
        try store.saveAdopted(adopted)
        return adopted
    }

    /// Stops managing the job and leaves it exactly as it is. An unknown label is an
    /// error rather than a no-op: it is usually a typo, or the wrong node.
    public func forget(label: String) throws {
        guard try store.removeAdopted(label: label) else { throw AdoptionError.notAdopted(label) }
    }

    public func start(_ job: AdoptedJob) async throws {
        guard let plist = job.plistPath else {
            if try await launchd.print(label: job.label) != nil { return }
            throw AdoptionError.noPlist(job.label)
        }
        try await launchd.enable(label: job.label)
        do {
            try await launchd.bootstrap(plistURL: URL(filePath: plist))
        } catch LaunchctlError.alreadyLoaded {
            // Already running, which is what was asked for.
        }
    }

    public func stop(_ job: AdoptedJob) async throws {
        do {
            try await launchd.bootout(label: job.label)
        } catch LaunchctlError.notFound {
            // Already stopped.
        }
    }

    public func restart(_ job: AdoptedJob) async throws {
        if try await launchd.print(label: job.label) == nil {
            try await start(job)
        } else {
            try await launchd.kickstart(label: job.label, kill: true)
        }
    }

    public func statuses() async throws -> [InstanceStatus] {
        let node = NodeID(ProcessInfo.processInfo.hostName)
        var statuses: [InstanceStatus] = []
        for adopted in try store.adoptedJobs() {
            let job = try await launchd.print(label: adopted.label)
            let usage: ProcessUsage?
            if let pid = job?.pid { usage = await sampler.usage(pid: pid) } else { usage = nil }
            statuses.append(InstanceStatus(
                service: adopted.label,
                instance: 0,
                node: node,
                state: job?.instanceState ?? .stopped,
                pid: job?.pid,
                lastExitCode: job?.lastExitCode,
                uptime: usage?.uptime,
                restarts: job?.restarts ?? 0,
                cpu: usage?.cpu,
                rss: usage?.rss,
                cpuSeconds: usage?.cpuSeconds,
                adopted: true,
                stats: usage?.stats,
                kind: .guess(from: adopted.label)
            ))
        }
        return statuses
    }
}
