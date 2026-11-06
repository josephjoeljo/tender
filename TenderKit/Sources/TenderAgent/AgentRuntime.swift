import Foundation
import Hummingbird
import LaunchdKit
import Logging
import ServiceLifecycle
import TenderActorSystem
import TenderCore
import UnixSignals

public enum AgentRuntimeError: Error, CustomStringConvertible {
    case alreadyRunning(lockPath: String)

    public var description: String {
        switch self {
        case .alreadyRunning(let path): "Another tenderd already holds \(path)."
        }
    }
}

/// What the head adds to the agent. The agent knows nothing about the head beyond this,
/// and `tenderd` connects the two.
public struct ClusterHooks: Sendable {
    public var resolver: any NodeResolver
    public var verifier: any PeerVerifier
    public var systemReady: @Sendable (TenderActorSystem) -> Void
    /// Replaces the socket's process routes with cluster-wide ones.
    public var installRoutes: @Sendable (Router<BasicRequestContext>) -> Void
    public var services: @Sendable () throws -> [any Service]
    /// Called with the node's address each time the transport is about to (re)bind to it,
    /// so the head can refresh what names that address, such as its certificate.
    public var addressReady: @Sendable (String) async -> Void

    public init(resolver: any NodeResolver, verifier: any PeerVerifier,
                systemReady: @escaping @Sendable (TenderActorSystem) -> Void,
                installRoutes: @escaping @Sendable (Router<BasicRequestContext>) -> Void,
                services: @escaping @Sendable () throws -> [any Service],
                addressReady: @escaping @Sendable (String) async -> Void = { _ in }) {
        self.addressReady = addressReady
        self.resolver = resolver
        self.verifier = verifier
        self.systemReady = systemReady
        self.installRoutes = installRoutes
        self.services = services
    }
}

/// Composes the worker: StateStore → Reconciler → API server. Stopping it leaves
/// managed jobs running: launchd supervises them, not this process.
public struct AgentRuntime: Sendable {
    private let environment: TenderEnvironment
    private let launchd: any LaunchdControlling
    private let sweepInterval: Duration
    private let shutdownSignals: [UnixSignal]
    private let logger: Logger
    private let secrets: any SecretStore
    private let cluster: ClusterOptions
    private let hooks: ClusterHooks?
    private let releaseSource: (any ReleaseSource)?
    private let execPath: String?

    /// `execPath` is the `tenderd` that services with secrets start through. It defaults
    /// to the installed copy in production, and to this executable in dev mode.
    public init(
        environment: TenderEnvironment,
        secrets: (any SecretStore)? = nil,
        cluster: ClusterOptions = ClusterOptions(),
        hooks: ClusterHooks? = nil,
        launchd: (any LaunchdControlling)? = nil,
        releaseSource: (any ReleaseSource)? = nil,
        execPath: String? = nil,
        sweepInterval: Duration = .seconds(10),
        shutdownSignals: [UnixSignal] = [.sigterm, .sigint],
        logger: Logger = Logger(label: "tenderd")
    ) {
        self.environment = environment
        self.secrets = secrets ?? environment.makeSecretStore()
        self.cluster = cluster
        self.hooks = hooks
        self.releaseSource = releaseSource
        self.execPath = execPath ?? (environment.mode == .production
            ? SystemInstallPlan(environment: environment).installedDaemon.path(percentEncoded: false)
            : Bundle.main.executablePath)
        self.launchd = launchd ?? Launchctl(domain: .forEnvironment(environment))
        self.sweepInterval = sweepInterval
        self.shutdownSignals = shutdownSignals
        self.logger = logger
    }

    public func run() async throws {
        let files = FileManager.default
        try files.createDirectory(at: environment.runDirectory, withIntermediateDirectories: true)
        try files.setAttributes([.posixPermissions: 0o700], ofItemAtPath: environment.runDirectory.path(percentEncoded: false))

        // Binding replaces an existing socket file, so a second daemon would
        // silently steal the socket from the first without this lock.
        let lock = try acquireLock()
        defer { close(lock) }

        let store = try StateStore(environment: environment)
        let cloud = CloudServices(environment: environment, secrets: secrets)
        let vault = SecretVault(secrets: secrets, store: store, gcpProject: { cloud.defaultSecretsProject() })
        let gcp = GCPSecretSync(vault: vault, source: { try cloud.secretSource() })
        let reconciler = Reconciler(environment: environment, store: store, launchd: launchd,
                                    vault: vault, gcp: gcp, execPath: execPath)
        let releases = ReleaseManager(environment: environment, store: store, reconciler: reconciler)
        let identities = ClusterIdentityStore(environment: environment, secrets: secrets)
        let controller = ProcessController(environment: environment, store: store, reconciler: reconciler,
                                           releases: releases,
                                           adoption: Adoption(environment: environment, store: store, launchd: launchd),
                                           identities: identities,
                                           cloud: cloud,
                                           releaseSourceOverride: releaseSource,
                                           vault: vault,
                                           gcp: gcp)
        let socketPath = environment.socketPath.path(percentEncoded: false)
        let logger = self.logger

        let router = makeRouter(controller: controller, identities: identities, network: cluster.network, clusterRoutes: hooks?.installRoutes)
        let server = Application(
            router: router,
            configuration: .init(address: .unixDomainSocket(path: socketPath), serverName: nil),
            onServerRunning: { _ in
                chmod(socketPath, 0o600)
                logger.info("listening", metadata: ["socket": "\(socketPath)"])
            },
            logger: logger
        )
        let group = ServiceGroup(
            services: [
                ReconcilerSweep(reconciler: reconciler, interval: sweepInterval),
                LogRotationService(environment: environment, store: store),
                ReleaseWatcher(environment: environment, manager: releases),
                server,
                ClusterLink(identities: identities, options: cluster, controller: controller, hooks: hooks, logger: logger),
            ] + (try hooks?.services() ?? []),
            gracefulShutdownSignals: shutdownSignals,
            logger: logger
        )
        defer { unlink(socketPath) }
        try await group.run()
    }

    private func acquireLock() throws -> Int32 {
        let path = environment.lockPath.path(percentEncoded: false)
        let descriptor = open(path, O_CREAT | O_RDWR | O_CLOEXEC, 0o600)
        guard descriptor >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else {
            close(descriptor)
            throw AgentRuntimeError.alreadyRunning(lockPath: path)
        }
        return descriptor
    }
}
