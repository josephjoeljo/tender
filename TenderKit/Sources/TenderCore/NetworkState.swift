import Foundation

/// Where a node's listeners are, as `tender status` and the head report it.
public struct NetworkState: Codable, Sendable, Equatable {
    public enum Kind: String, Codable, Sendable {
        /// Bound to a tailnet (or explicitly chosen) address.
        case listening
        /// Bound to a loopback address: other nodes can't reach it.
        case loopbackOnly
        /// No tailnet address yet and none was given. Nothing is listening for peers.
        case waitingForTailscale
    }

    public var kind: Kind
    public var address: String?

    public init(kind: Kind, address: String? = nil) {
        self.kind = kind
        self.address = address
    }

    public static let waiting = NetworkState(kind: .waitingForTailscale)

    /// Whether other nodes can reach this one.
    public var isReachable: Bool { kind == .listening }

    public var summary: String {
        switch kind {
        case .listening: "listening on \(address ?? "?")"
        case .loopbackOnly: "loopback only (\(address ?? "127.0.0.1")): other nodes can't reach this one"
        case .waitingForTailscale: "waiting for Tailscale: not listening yet"
        }
    }

    public static func isLoopback(_ host: String) -> Bool {
        host == "localhost" || host == "::1" || host.hasPrefix("127.")
    }
}
