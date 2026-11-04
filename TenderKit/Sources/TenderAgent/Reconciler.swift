import Foundation
import LaunchdKit
import Logging
import LogTail
import ProcessMetrics
import ServiceLifecycle
import TenderCore

/// One step that moves launchd towards the desired state.
public enum ReconcileAction: Sendable, Equatable {
    /// Writes the plist, enables the label, and bootstraps it.
    case install(label: String, plist: Data)
    /// Boots out a loaded job whose plist changed, then installs the new one.
    case replace(label: String, plist: Data)
    case bootout(label: String)
    case removePlist(label: String)
    /// Removes the row of an instance that is gone from launchd.
    case forget(service: String, instance: Int)

    var label: String? {
        switch self {
        case .install(let label, _), .replace(let label, _), .bootout(let label), .removePlist(let label): label
        case .forget: nil
        }
    }
}

enum ReconcileApplyError: Error, CustomStringConvertible {
    case unknownUser(String)
    case noExecWrapper(String)

    var description: String {
        switch self {
        case .unknownUser(let user): "The account '\(user)' doesn't exist. Did `tender daemon install --system` run?"
        case .noExecWrapper(let service): "'\(service)' references secrets, but this daemon has no `tenderd exec` to start it with."
        }
    }
}

public struct ReconcileFailure: Sendable, Equatable {
    public var label: String
    public var message: String
}

public struct ReconcileReport: Sendable, Equatable {
    public var applied: [ReconcileAction] = []
    public var failures: [ReconcileFailure] = []
    /// Labels with our prefix that nothing in the desired state accounts for.
    /// Only reported: booting them out takes an explicit `tender gc`.
    public var orphans: [String] = []
}

public actor Reconciler {
    /// What launchd and the plist directory look like right now.
    public struct Observed: Sendable {
        public var loadedLabels: Set<String>
        public var plists: [String: Data]

        public init(loadedLabels: Set<String>, plists: [String: Data]) {
            self.loadedLabels = loadedLabels
            self.plists = plists
        }
    }

    public struct Desired: Sendable {
        public var record: InstanceRecord
        /// Rendered plist. Nil unless the instance should be running.
        public var plist: Data?

        public init(record: InstanceRecord, plist: Data?) {
            self.record = record
            self.plist = plist
        }
    }

    private let environment: TenderEnvironment
    private let store: StateStore
    private let launchd: any LaunchdControlling
    private let throttleInterval: Int?
    private let logger: Logger
    private let vault: SecretVault?
    /// `tenderd` itself, which services that reference secrets start through.
    private let execPath: String?
    private let sampler = UsageSampler()
    private var tail: Task<Void, Never>?

    public init(
        environment: TenderEnvironment,
        store: StateStore,
        launchd: any LaunchdControlling,
        vault: SecretVault? = nil,
        execPath: String? = nil,
        throttleInterval: Int? = nil,
        logger: Logger = Logger(label: "tender.reconciler")
    ) {
        self.environment = environment
        self.store = store
        self.launchd = launchd
        self.vault = vault
        self.execPath = execPath
        self.throttleInterval = throttleInterval
        self.logger = logger
    }

    // MARK: Planning

    /// Computes what to do. Pure, so that every combination is unit testable.
    public nonisolated static func plan(desired: [Desired], observed: Observed) -> [ReconcileAction] {
        var actions: [ReconcileAction] = []
        for item in desired {
            let label = item.record.label
            let loaded = observed.loadedLabels.contains(label)
            let onDisk = observed.plists[label]

            if item.record.desired == .running, let plist = item.plist {
                if !loaded {
                    actions.append(.install(label: label, plist: plist))
                } else if onDisk == nil || !plistsMatch(onDisk!, plist) {
                    actions.append(.replace(label: label, plist: plist))
                }
                continue
            }
            if loaded { actions.append(.bootout(label: label)) }
            if onDisk != nil { actions.append(.removePlist(label: label)) }
            if item.record.desired == .absent {
                actions.append(.forget(service: item.record.service, instance: item.record.instance))
            }
        }
        return actions
    }

    private nonisolated static func plistsMatch(_ lhs: Data, _ rhs: Data) -> Bool {
        if lhs == rhs { return true }
        guard let left = try? PropertyListSerialization.propertyList(from: lhs, format: nil) as? NSDictionary,
              let right = try? PropertyListSerialization.propertyList(from: rhs, format: nil) as? NSDictionary
        else { return false }
        return left.isEqual(right)
    }

    /// Renders the plist launchd should have for an instance.
    func renderPlist(spec: ServiceSpec, instance: Int) throws -> Data {
        let executable: String
        switch spec.program {
        case .executable(let path): executable = path
        case .release(let sha12):
            executable = environment.releaseBinary(service: spec.name, sha12: sha12).path(percentEncoded: false)
        }
        var programArguments = [executable] + spec.arguments
        var variables = spec.environment
        // The plist holds only templates. TENDER_SECRETS_REV changes whenever a referenced
        // secret does, so the plist differs and the job is replaced, which restarts it.
        if spec.usesSecretTemplates {
            guard let execPath, let vault else { throw ReconcileApplyError.noExecWrapper(spec.name) }
            programArguments = [execPath, "exec", "--service", spec.name, "--instance", String(instance),
                                "--secrets", environment.serviceSecretsFile(service: spec.name).path(percentEncoded: false),
                                "--"] + programArguments
            variables["TENDER_SECRETS_REV"] = try vault.revisionTag(for: spec)
        }
        return try PlistRenderer().render(
            label: environment.serviceLabel(service: spec.name, instance: instance),
            programArguments: programArguments,
            environment: variables,
            workingDirectory: spec.workingDirectory,
            stdoutPath: environment.stdoutLog(service: spec.name, instance: instance).path(percentEncoded: false),
            stderrPath: environment.stderrLog(service: spec.name, instance: instance).path(percentEncoded: false),
            userName: environment.mode == .production ? spec.user : nil,
            throttleInterval: throttleInterval
        )
    }

    // MARK: Running

    /// Runs operations one at a time. An actor alone is not enough: it would let
    /// a sweep interleave with a CLI command at every `await launchctl` point.
    private func exclusive<T: Sendable>(_ operation: @escaping @Sendable () async throws -> T) async throws -> T {
        let previous = tail
        let task = Task {
            await previous?.value
            return try await operation()
        }
        tail = Task { _ = await task.result }
        return try await task.value
    }

    /// Makes launchd match the desired state. Safe to call at any time; when
    /// nothing changed it applies nothing. One failing label does not stop the
    /// others, and it is retried by the next sweep.
    @discardableResult
    public func reconcile() async throws -> ReconcileReport {
        try await exclusive { try await self.reconcileNow() }
    }

    /// Reconciles, then restarts the instances of `service` that were already
    /// loaded (freshly installed ones have just started).
    @discardableResult
    public func restart(service: String) async throws -> ReconcileReport {
        try await exclusive {
            var report = try await self.reconcileNow()
            let fresh = Set(report.applied.compactMap { action -> String? in
                switch action {
                case .install(let label, _), .replace(let label, _): label
                default: nil
                }
            })
            for record in try self.store.instances()
            where record.service == service && record.desired == .running && !fresh.contains(record.label) {
                do {
                    try await self.launchd.kickstart(label: record.label, kill: true)
                } catch {
                    report.failures.append(ReconcileFailure(label: record.label, message: "\(error)"))
                }
            }
            return report
        }
    }

    /// Boots out orphans: labels with our prefix that aren't in the desired state.
    /// The one operation that removes jobs Tender has no record of, so it only
    /// runs when asked for (`tender gc`), never from a sweep.
    @discardableResult
    public func collectGarbage() async throws -> ReconcileReport {
        try await exclusive {
            var report = ReconcileReport()
            let known = Set(try self.store.instances().map(\.label))
            let loaded = try await self.launchd.listLabels(prefix: "\(self.environment.serviceLabelPrefix).")
            for label in loaded where !known.contains(label) {
                do {
                    try await self.apply(.bootout(label: label))
                    try await self.apply(.removePlist(label: label))
                    report.applied.append(.bootout(label: label))
                } catch {
                    report.failures.append(ReconcileFailure(label: label, message: "\(error)"))
                }
            }
            return report
        }
    }

    /// Current status of all instances, plus orphaned labels.
    public func status() async throws -> ProcessList {
        let node = NodeID(ProcessInfo.processInfo.hostName)
        let services = Dictionary(uniqueKeysWithValues: try store.services().map { ($0.spec.name, $0) })
        var processes: [InstanceStatus] = []
        let records = try store.instances().filter { $0.desired != .absent }
        for record in records {
            let job = try await launchd.print(label: record.label)
            var release: String?
            if case .release(let sha12) = services[record.service]?.spec.program { release = sha12 }

            let state: InstanceState
            if let job { state = job.instanceState }
            else { state = record.desired == .stopped ? .stopped : .unknown }

            let usage: ProcessUsage?
            if let pid = job?.pid { usage = await sampler.usage(pid: pid) } else { usage = nil }

            processes.append(InstanceStatus(
                service: record.service,
                instance: record.instance,
                node: node,
                state: state,
                pid: job?.pid,
                lastExitCode: job?.lastExitCode,
                uptime: usage?.uptime,
                restarts: job?.restarts ?? 0,
                release: release,
                cpu: usage?.cpu,
                rss: usage?.rss,
                cpuSeconds: usage?.cpuSeconds
            ))
        }
        await sampler.retain(pids: Set(processes.compactMap(\.pid)))
        let known = Set(try store.instances().map(\.label))
        let loaded = try await launchd.listLabels(prefix: "\(environment.serviceLabelPrefix).")
        return ProcessList(processes: processes, orphans: loaded.filter { !known.contains($0) })
    }

    private func reconcileNow() async throws -> ReconcileReport {
        let services = Dictionary(uniqueKeysWithValues: try store.services().map { ($0.spec.name, $0) })
        let records = try store.instances()

        var report = ReconcileReport()
        var broken = Set<String>()
        if let vault {
            let materializer = SecretMaterializer(environment: environment, vault: vault)
            let secretive = services.values.filter { $0.spec.usesSecretTemplates }
            for service in secretive {
                do {
                    try materializer.materialize(service.spec)
                } catch {
                    broken.insert(service.spec.name)
                    report.failures.append(ReconcileFailure(label: environment.serviceLabel(service: service.spec.name, instance: 0),
                                                            message: "can't write its secrets: \(error)"))
                }
            }
            materializer.removeStale(keeping: Set(secretive.map(\.spec.name)))
        }
        var desired: [Desired] = []
        // A service whose secrets file couldn't be written keeps its running jobs as they
        // are, but `stop` and `delete` still take effect: they need no secrets.
        for record in records where !(record.desired == .running && broken.contains(record.service)) {
            do {
                let plist = try services[record.service].map { try renderPlist(spec: $0.spec, instance: record.instance) }
                desired.append(Desired(record: record, plist: record.desired == .running ? plist : nil))
            } catch {
                report.failures.append(ReconcileFailure(label: record.label, message: "\(error)"))
            }
        }

        let loaded = Set(try await launchd.listLabels(prefix: "\(environment.serviceLabelPrefix)."))
        var plists: [String: Data] = [:]
        for record in records {
            plists[record.label] = try? Data(contentsOf: environment.plistPath(label: record.label))
        }

        var failedLabels = Set<String>()
        for action in Self.plan(desired: desired, observed: Observed(loadedLabels: loaded, plists: plists)) {
            // A `forget` must not run if removing that instance's job failed.
            if case .forget(let service, let instance) = action,
               failedLabels.contains(environment.serviceLabel(service: service, instance: instance)) {
                continue
            }
            do {
                try await apply(action)
                report.applied.append(action)
            } catch {
                let label = action.label ?? ""
                failedLabels.insert(label)
                report.failures.append(ReconcileFailure(label: label, message: "\(error)"))
                logger.error("reconcile action failed", metadata: ["label": "\(label)", "error": "\(error)"])
            }
        }

        let known = Set(records.map(\.label))
        report.orphans = loaded.filter { !known.contains($0) }.sorted()
        for orphan in report.orphans {
            logger.warning("orphaned launchd job; run `tender gc` to remove it", metadata: ["label": "\(orphan)"])
        }
        return report
    }

    private func apply(_ action: ReconcileAction) async throws {
        switch action {
        case .install(let label, let plist):
            try await install(label: label, plist: plist)
        case .replace(let label, let plist):
            try await bootoutIfLoaded(label: label)
            try await waitUntilUnloaded(label: label)
            try await install(label: label, plist: plist)
        case .bootout(let label):
            try await bootoutIfLoaded(label: label)
        case .removePlist(let label):
            do {
                try FileManager.default.removeItem(at: environment.plistPath(label: label))
            } catch CocoaError.fileNoSuchFile {
                // Already gone.
            }
        case .forget(let service, let instance):
            try store.removeInstance(service: service, instance: instance)
        }
    }

    private func install(label: String, plist: Data) async throws {
        let plistURL = environment.plistPath(label: label)
        let files = FileManager.default
        try files.createDirectory(at: environment.plistDirectory, withIntermediateDirectories: true)
        if let parsed = try PropertyListSerialization.propertyList(from: plist, format: nil) as? [String: Any],
           let stdout = parsed["StandardOutPath"] as? String {
            let logs = URL(filePath: stdout).deletingLastPathComponent()
            try files.createDirectory(at: logs, withIntermediateDirectories: true)
            if let user = parsed["UserName"] as? String { try giveOwnership(of: logs, to: user) }
        }
        try plist.write(to: plistURL, options: .atomic)
        // The plist holds the service's environment, which can include secrets.
        try files.setAttributes([.posixPermissions: 0o600], ofItemAtPath: plistURL.path(percentEncoded: false))
        // bootstrap refuses a label left disabled, for example by a manual `launchctl disable`.
        try await launchd.enable(label: label)
        do {
            try await launchd.bootstrap(plistURL: plistURL)
        } catch LaunchctlError.alreadyLoaded {
            // Someone else loaded it first. That is the state we wanted.
        }
    }

    /// launchd opens the log files as the job's user, who must be able to write there.
    private func giveOwnership(of url: URL, to user: String) throws {
        guard let account = getpwnam(user) else { throw ReconcileApplyError.unknownUser(user) }
        guard chown(url.path(percentEncoded: false), account.pointee.pw_uid, account.pointee.pw_gid) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
    }

    private func bootoutIfLoaded(label: String) async throws {
        do {
            try await launchd.bootout(label: label)
        } catch LaunchctlError.notFound {
            // Already gone.
        }
    }

    /// bootstrap fails while launchd is still tearing down the previous job.
    private func waitUntilUnloaded(label: String) async throws {
        for _ in 0..<50 {
            if try await launchd.print(label: label) == nil { return }
            try await Task.sleep(for: .milliseconds(100))
        }
    }
}

/// Periodic backstop for the reconciler. Stops on graceful shutdown and leaves
/// managed jobs running.
public struct ReconcilerSweep: Service {
    private let reconciler: Reconciler
    private let interval: Duration
    private let logger: Logger

    public init(reconciler: Reconciler, interval: Duration = .seconds(10),
                logger: Logger = Logger(label: "tender.sweep")) {
        self.reconciler = reconciler
        self.interval = interval
        self.logger = logger
    }

    public func run() async throws {
        await cancelWhenGracefulShutdown {
            while !Task.isCancelled {
                do {
                    try await reconciler.reconcile()
                } catch {
                    logger.error("sweep failed", metadata: ["error": "\(error)"])
                }
                try? await Task.sleep(for: interval)
            }
        }
    }
}

/// Rotates the logs of managed instances. Adopted jobs' logs are not ours to touch.
public struct LogRotationService: Service {
    private let environment: TenderEnvironment
    private let store: StateStore
    private let rotator: LogRotator
    private let interval: Duration
    private let logger: Logger

    public init(environment: TenderEnvironment, store: StateStore, rotator: LogRotator = LogRotator(),
                interval: Duration = .seconds(30), logger: Logger = Logger(label: "tender.logrotate")) {
        self.environment = environment
        self.store = store
        self.rotator = rotator
        self.interval = interval
        self.logger = logger
    }

    func rotateAll() throws {
        for record in try store.instances() where record.desired != .absent {
            for url in [environment.stdoutLog(service: record.service, instance: record.instance),
                        environment.stderrLog(service: record.service, instance: record.instance)] {
                do {
                    try rotator.rotateIfNeeded(url)
                } catch {
                    logger.error("rotation failed", metadata: ["file": "\(url.path())", "error": "\(error)"])
                }
            }
        }
    }

    public func run() async throws {
        await cancelWhenGracefulShutdown {
            while !Task.isCancelled {
                do {
                    try rotateAll()
                } catch {
                    logger.error("rotation sweep failed", metadata: ["error": "\(error)"])
                }
                try? await Task.sleep(for: interval)
            }
        }
    }
}
