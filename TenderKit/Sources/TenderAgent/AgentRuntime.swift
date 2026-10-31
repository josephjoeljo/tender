import Foundation
import Hummingbird
import LaunchdKit
import Logging
import ServiceLifecycle
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

/// Composes the worker: StateStore → Reconciler → API server. Stopping it leaves
/// managed jobs running: launchd supervises them, not this process.
public struct AgentRuntime: Sendable {
    private let environment: TenderEnvironment
    private let launchd: any LaunchdControlling
    private let sweepInterval: Duration
    private let shutdownSignals: [UnixSignal]
    private let logger: Logger

    public init(
        environment: TenderEnvironment,
        launchd: (any LaunchdControlling)? = nil,
        sweepInterval: Duration = .seconds(10),
        shutdownSignals: [UnixSignal] = [.sigterm, .sigint],
        logger: Logger = Logger(label: "tenderd")
    ) {
        self.environment = environment
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
        let reconciler = Reconciler(environment: environment, store: store, launchd: launchd)
        let controller = ProcessController(environment: environment, store: store, reconciler: reconciler)
        let socketPath = environment.socketPath.path(percentEncoded: false)
        let logger = self.logger

        let server = Application(
            router: makeRouter(controller: controller),
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
                server,
            ],
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
