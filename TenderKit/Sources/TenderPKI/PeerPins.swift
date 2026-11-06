import Foundation
import Synchronization
import TenderCore

/// Which Tailscale machine each node ID connects from, remembered at its first connection
/// (trust on first use). The certificate says who the node is; this says it is still on the
/// machine it started on, so a copied certificate is no use from anywhere else.
public final class PeerPins: Sendable {
    private let url: URL
    private let pins: Mutex<[String: String]>

    private static let shared = Mutex<[String: PeerPins]>([:])

    /// One instance per file in a process, so that the head's and the transport's writes
    /// don't overwrite each other.
    public static func at(_ url: URL) -> PeerPins {
        shared.withLock { shared in
            let key = url.path(percentEncoded: false)
            if let existing = shared[key] { return existing }
            let created = PeerPins(url: url)
            shared[key] = created
            return created
        }
    }

    public static func standard(_ environment: TenderEnvironment) -> PeerPins {
        at(environment.root.appending(path: "peer-pins.json"))
    }

    private init(url: URL) {
        self.url = url
        let stored = (try? Data(contentsOf: url)).flatMap { try? JSONDecoder().decode([String: String].self, from: $0) }
        pins = Mutex(stored ?? [:])
    }

    /// True if `node` is new (and now pinned to `stableID`) or was pinned to it already.
    public func pinOrCheck(node: NodeID, stableID: String) -> Bool {
        pins.withLock { pins in
            if let pinned = pins[node.rawValue] { return pinned == stableID }
            pins[node.rawValue] = stableID
            save(pins)
            return true
        }
    }

    public func pinned(_ node: NodeID) -> String? { pins.withLock { $0[node.rawValue] } }

    /// Forgets a node, so that it can connect from a different machine.
    public func forget(_ node: NodeID) {
        pins.withLock { pins in
            if pins.removeValue(forKey: node.rawValue) != nil { save(pins) }
        }
    }

    private func save(_ pins: [String: String]) {
        guard let data = try? JSONEncoder().encode(pins) else { return }
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: url, options: .atomic)
    }
}
