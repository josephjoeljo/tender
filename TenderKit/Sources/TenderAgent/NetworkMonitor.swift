import Foundation
import Logging
import Synchronization
import TenderCore
import TenderPKI

public struct NetworkWaitError: Error, CustomStringConvertible {
    public let waited: Duration

    public var description: String {
        "No Tailscale address (100.64.0.0/10) after \(waited.components.seconds)s, and --listen wasn't given. "
            + "Exiting so launchd restarts tenderd."
    }
}

/// Finds the address this node listens on, and notices when it appears or changes.
/// `tenderd` may start before Tailscale has an address (at boot), so nothing binds
/// until there is one, and everything that bound rebinds when it changes.
public final class NetworkMonitor: Sendable {
    private let explicitHost: String?
    private let probe: @Sendable () async -> String?
    private let pollInterval: Duration
    private let current = Mutex(NetworkState.waiting)

    /// `explicitHost` is `--listen`: it's used as given and never waited for.
    public init(explicitHost: String? = nil, pollInterval: Duration = .seconds(2),
                probe: @escaping @Sendable () async -> String? = { await TailscaleCLI.localIPv4() }) {
        self.explicitHost = explicitHost
        self.pollInterval = pollInterval
        self.probe = probe
        if let explicitHost { current.withLock { $0 = Self.state(for: explicitHost) } }
    }

    private static func state(for host: String) -> NetworkState {
        NetworkState(kind: NetworkState.isLoopback(host) ? .loopbackOnly : .listening, address: host)
    }

    /// The last state anyone saw. Cheap; doesn't probe.
    public var state: NetworkState { current.withLock { $0 } }

    /// The address to listen on right now, or nil while waiting for Tailscale.
    @discardableResult
    public func resolve() async -> String? {
        let host: String?
        if let explicitHost { host = explicitHost } else { host = await probe() }
        current.withLock { $0 = host.map(Self.state(for:)) ?? .waiting }
        return host
    }

    /// Polls with backoff until there is an address, logging each retry. With a `timeout`,
    /// throws `NetworkWaitError` if there is still none. Returns nil only if cancelled.
    public func waitForHost(timeout: Duration?, logger: Logger?) async throws -> String? {
        let clock = ContinuousClock()
        let start = clock.now
        var delay: Duration = .seconds(1)
        var attempt = 0
        while !Task.isCancelled {
            if let host = await resolve() { return host }
            let waited = clock.now - start
            if let timeout, waited >= timeout { throw NetworkWaitError(waited: waited) }
            attempt += 1
            logger?.warning("waiting for a Tailscale address", metadata: [
                "attempt": "\(attempt)", "waited": "\(waited.components.seconds)s", "retryIn": "\(delay.components.seconds)s",
            ])
            do { try await Task.sleep(for: delay) } catch { return nil }
            delay = min(delay * 2, .seconds(15))
        }
        return nil
    }

    /// Returns once the address is no longer `host` (a new one, or nil if it went away),
    /// or when cancelled.
    public func waitForChange(from host: String?) async -> String? {
        while !Task.isCancelled {
            do { try await Task.sleep(for: pollInterval) } catch { return host }
            let now = await resolve()
            if now != host { return now }
        }
        return host
    }
}
