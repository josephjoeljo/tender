import Foundation
import Synchronization

/// A node's ID: a UUID made on first run and kept in `<root>/node-id`, so it survives
/// restarts and renames. The hostname is only a label (`NodeInfo.hostname`).
public enum NodeIdentity {
    private static let cache = Mutex<[String: NodeID]>([:])

    public static func fileURL(_ environment: TenderEnvironment) -> URL {
        environment.root.appending(path: "node-id")
    }

    /// The persisted ID, created on first use. Throws if it can't be read or saved.
    @discardableResult
    public static func load(environment: TenderEnvironment) throws -> NodeID {
        let key = environment.root.path(percentEncoded: false)
        if let known = cache.withLock({ $0[key] }) { return known }
        let url = fileURL(environment)
        let id: NodeID
        if let data = try? Data(contentsOf: url),
           let text = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty {
            id = NodeID(text)
        } else {
            id = NodeID(UUID().uuidString.lowercased())
            try FileManager.default.createDirectory(at: environment.root, withIntermediateDirectories: true)
            try Data((id.rawValue + "\n").utf8).write(to: url, options: .atomic)
        }
        cache.withLock { $0[key] = id }
        return id
    }

    /// The ID this process uses. Falls back to one that lasts only until exit if the file
    /// can't be written; `tenderd` calls `load` at start, which fails loudly instead.
    public static func current(environment: TenderEnvironment) -> NodeID {
        if let id = try? load(environment: environment) { return id }
        let key = environment.root.path(percentEncoded: false)
        return cache.withLock { cache in
            if let known = cache[key] { return known }
            let id = NodeID(UUID().uuidString.lowercased())
            cache[key] = id
            return id
        }
    }

    /// Uses `id` for this process: `tenderd run --node-id`. Nothing is written, so the
    /// persisted ID is unchanged when the flag goes away.
    public static func override(_ id: NodeID, environment: TenderEnvironment) {
        cache.withLock { $0[environment.root.path(percentEncoded: false)] = id }
    }

    /// Replaces the persisted ID, for `tender join --node-id`.
    public static func adopt(_ id: NodeID, environment: TenderEnvironment) throws {
        try FileManager.default.createDirectory(at: environment.root, withIntermediateDirectories: true)
        try Data((id.rawValue + "\n").utf8).write(to: fileURL(environment), options: .atomic)
        override(id, environment: environment)
    }

    /// What people call this machine. It can change at any time.
    public static func hostname() -> String {
        let name = ProcessInfo.processInfo.hostName.split(separator: ".").first.map(String.init) ?? "node"
        return name.lowercased()
    }
}
