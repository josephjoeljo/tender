import Foundation
import Logging
import TenderCore

/// Keeps the `SecretVault`'s copies of GCP Secret Manager values fresh. Values are fetched
/// before instances need them and cached in the vault, so delivery, rotation and restarts
/// with GCP or the head away all work exactly as for node-local secrets.
///
/// - A reference with no cached value is fetched whenever it's needed, at most every
///   `retryInterval` after a failure.
/// - `latest` is re-checked every `recheckInterval`. A new value bumps its revision,
///   which restarts the services that use it.
/// - A pinned version is fetched once: versions don't change, only the spec does.
public actor GCPSecretSync {
    public static let recheckInterval: TimeInterval = 300
    public static let retryInterval: TimeInterval = 30
    /// A value fetched this recently is kept even if no stored spec uses it yet, because
    /// `start` fetches before it stores the spec.
    static let keepUnusedFor: TimeInterval = 600

    struct Status {
        var version: String?
        var checkedAt: Date?
        var failedAt: Date?
        var error: SecretFetchError?
    }

    private let vault: SecretVault
    /// By source name, nil for the default one.
    private let source: @Sendable (String?) throws -> GCPSecretSource
    private let logger: Logger
    private var statuses: [GCPSecretVersion: Status] = [:]
    /// Failed fetches since the daemon started, for `tender_secret_fetch_errors_total`.
    public private(set) var fetchErrors = 0

    /// `source` is called for each round of fetches, so credentials added later are used
    /// without a restart.
    public init(vault: SecretVault, sources source: @escaping @Sendable (String?) throws -> GCPSecretSource,
                logger: Logger = Logger(label: "tender.secrets.gcp")) {
        self.vault = vault
        self.source = source
        self.logger = logger
    }

    /// Every source fetches through `source`.
    public init(vault: SecretVault, source: @escaping @Sendable () throws -> GCPSecretSource,
                logger: Logger = Logger(label: "tender.secrets.gcp")) {
        self.init(vault: vault, sources: { _ in try source() }, logger: logger)
    }

    /// The versions `spec` references, with projects filled in. A reference the node's
    /// sources can't resolve for the service (no project, an unknown source, or one that
    /// doesn't allow it) maps to nil, and so is never fetched.
    nonisolated func versions(in spec: ServiceSpec) -> [(ref: SecretRef, version: GCPSecretVersion?)] {
        let sources = vault.sources()
        return ((try? spec.secretRefs()) ?? []).compactMap { ref in
            ref.gcp.map { (ref, try? sources.resolve($0, service: spec.name).get()) }
        }
    }

    /// Fetches what `specs` need now. `force` skips the intervals, for a `start`, except
    /// for pinned versions already cached. Returns the failures.
    @discardableResult
    public func refresh(_ specs: [ServiceSpec], force: Bool = false, now: Date = Date()) async -> [GCPSecretVersion: SecretFetchError] {
        var due: [GCPSecretVersion] = []
        for spec in specs {
            for case let (_, version?) in versions(in: spec) where !due.contains(version) {
                if isDue(version, force: force, now: now) { due.append(version) }
            }
        }
        guard !due.isEmpty else { return [:] }

        var failures: [GCPSecretVersion: SecretFetchError] = [:]
        // Each source with its own credentials: one without any fails only its own.
        var clients: [String?: Result<GCPSecretSource, SecretFetchError>] = [:]
        for version in due {
            if clients[version.source] == nil {
                clients[version.source] = Result { try self.source(version.source) }
                    .mapError { $0 as? SecretFetchError ?? .notConfigured("\($0)") }
            }
            let source: GCPSecretSource
            switch clients[version.source]! {
            case .success(let client): source = client
            case .failure(let failure):
                failures[version] = failure
                record(failure, for: version, now: now)
                continue
            }
            do {
                let fetched = try await source.access(version)
                do {
                    if try vault.cache(version, value: fetched.value) {
                        logger.info("fetched a new value", metadata: ["secret": "\(version)", "version": "\(fetched.version)"])
                    }
                } catch let error as SecretVaultError {
                    throw SecretFetchError.invalidResponse(version, error.description)
                }
                statuses[version] = Status(version: fetched.version, checkedAt: now)
            } catch {
                let failure = error as? SecretFetchError ?? .unreachable(version, "\(error)")
                failures[version] = failure
                record(failure, for: version, now: now)
            }
        }
        return failures
    }

    private func isDue(_ version: GCPSecretVersion, force: Bool, now: Date) -> Bool {
        let cached = (try? vault.cached(version)) != nil
        if cached && !version.isLatest { return false }
        if force { return true }
        let status = statuses[version]
        if let failedAt = status?.failedAt, now.timeIntervalSince(failedAt) < Self.retryInterval { return false }
        guard cached else { return true }
        guard let checkedAt = status?.checkedAt else { return true }
        return now.timeIntervalSince(checkedAt) >= Self.recheckInterval
    }

    private func record(_ failure: SecretFetchError, for version: GCPSecretVersion, now: Date) {
        fetchErrors += 1
        var status = statuses[version] ?? Status()
        status.failedAt = now
        status.error = failure
        statuses[version] = status
        let cached = (try? vault.cached(version)) != nil
        logger.warning(cached ? "fetch failed; instances start from the cached value" : "fetch failed; instances that need it can't start",
                       metadata: ["secret": "\(version)", "error": "\(failure)"])
    }

    /// Drops cached values that no spec references any more.
    func prune(keeping specs: [ServiceSpec], now: Date = Date()) {
        let used = Set(specs.flatMap { versions(in: $0).compactMap { $0.version?.itemName } })
        for item in (try? vault.cachedGCPItems()) ?? [] where !used.contains(item) {
            if let version = GCPSecretVersion(itemName: item), let checkedAt = statuses[version]?.checkedAt,
               now.timeIntervalSince(checkedAt) < Self.keepUnusedFor {
                continue
            }
            try? vault.forgetCached(item: item)
            if let version = GCPSecretVersion(itemName: item) { statuses[version] = nil }
        }
    }

    /// What `tender secret list` shows for the GCP references in `specs`.
    func infos(for specs: [ServiceSpec], node: NodeID) -> [GCPSecretInfo] {
        var users: [GCPSecretVersion: [String]] = [:]
        for spec in specs {
            for case let (_, version?) in versions(in: spec) where users[version]?.contains(spec.name) != true {
                users[version, default: []].append(spec.name)
            }
        }
        return users.keys.sorted { $0.description < $1.description }.map { version in
            let record = try? vault.cached(version)
            let status = statuses[version]
            // A failure older than the last success is history.
            let failing = status?.failedAt.map { failedAt in status?.checkedAt.map { failedAt > $0 } ?? true } ?? false
            return GCPSecretInfo(name: version.description, node: node, version: status?.version, cached: record != nil,
                                 updatedAt: record?.updatedAt, checkedAt: status?.checkedAt, revision: record?.revision ?? 0,
                                 usedBy: users[version] ?? [], fetchError: failing ? status?.error?.description : nil)
        }
    }

    /// Per source: distinct versions in use, how many of them are failing, and the most
    /// recent failure, for `SecretSourceStatus`.
    func sourceUsage(for specs: [ServiceSpec]) -> [String?: (users: [String], references: Int, failing: Int, lastError: String?)] {
        var usage: [String?: (users: [String], references: Int, failing: Int, lastError: String?)] = [:]
        var seen = Set<GCPSecretVersion>()
        var latestFailure: [String?: Date] = [:]
        for spec in specs {
            for (ref, version) in versions(in: spec) {
                let source = ref.gcp?.source
                var entry = usage[source] ?? ([], 0, 0, nil)
                if !entry.users.contains(spec.name) { entry.users.append(spec.name) }
                if let version, seen.insert(version).inserted {
                    entry.references += 1
                    let status = statuses[version]
                    if let failedAt = status?.failedAt, status?.checkedAt.map({ failedAt > $0 }) ?? true {
                        entry.failing += 1
                        if failedAt > latestFailure[source] ?? .distantPast {
                            latestFailure[source] = failedAt
                            entry.lastError = status?.error?.description
                        }
                    }
                }
                usage[source] = entry
            }
        }
        return usage
    }

    /// Why `version` has no cached value, if a fetch failed.
    func failure(_ version: GCPSecretVersion) -> SecretFetchError? { statuses[version]?.error }
}
