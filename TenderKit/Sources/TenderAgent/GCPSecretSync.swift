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
    private let source: @Sendable () throws -> GCPSecretSource
    private let logger: Logger
    private var statuses: [GCPSecretVersion: Status] = [:]
    /// Failed fetches since the daemon started, for `tender_secret_fetch_errors_total`.
    public private(set) var fetchErrors = 0

    /// `source` is called for each round of fetches, so credentials added later are used
    /// without a restart.
    public init(vault: SecretVault, source: @escaping @Sendable () throws -> GCPSecretSource,
                logger: Logger = Logger(label: "tender.secrets.gcp")) {
        self.vault = vault
        self.source = source
        self.logger = logger
    }

    /// The versions `spec` references, with the node's default project filled in. A
    /// reference that has no project, on a node with no default, maps to nil.
    nonisolated func versions(in spec: ServiceSpec) -> [(ref: SecretRef, version: GCPSecretVersion?)] {
        let project = vault.gcpProject()
        return ((try? spec.secretRefs()) ?? []).compactMap { ref in
            ref.gcp.map { (ref, $0.resolved(defaultProject: project)) }
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
        let source: GCPSecretSource
        do {
            source = try self.source()
        } catch {
            let failure = error as? SecretFetchError ?? .notConfigured("\(error)")
            for version in due { record(failure, for: version, now: now) }
            return Dictionary(uniqueKeysWithValues: due.map { ($0, failure) })
        }
        for version in due {
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

    /// Why `version` has no cached value, if a fetch failed.
    func failure(_ version: GCPSecretVersion) -> SecretFetchError? { statuses[version]?.error }
}
