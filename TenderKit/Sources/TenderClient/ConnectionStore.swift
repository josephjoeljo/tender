import Foundation
import TenderCore

/// A head the app can talk to. The token is in the secret store, not in this file.
public struct SavedConnection: Codable, Sendable, Equatable, Identifiable {
    public var id: UUID
    public var name: String
    public var context: ClientContext

    public init(id: UUID = UUID(), name: String, context: ClientContext) {
        self.id = id
        self.name = name
        self.context = context
    }
}

public struct ConnectionList: Codable, Sendable, Equatable {
    public var connections: [SavedConnection] = []
    public var activeID: UUID?

    public init() {}

    public var active: SavedConnection? { connections.first { $0.id == activeID } }
}

public enum ConnectionStoreError: Error, Equatable, CustomStringConvertible {
    case unreadableToken(String)
    case unknownConnection

    public var description: String {
        switch self {
        case .unreadableToken(let name):
            "Can't read the token for \(name). Remove this connection in Settings and add it again."
        case .unknownConnection:
            "That connection no longer exists."
        }
    }
}

/// The heads the app knows, one of them active. Each connection has its own token
/// item, so a token that can't be read or deleted only affects its own connection.
public struct ConnectionStore: Sendable {
    public let directory: URL
    public let secrets: any SecretStore

    public init(directory: URL, secrets: any SecretStore) {
        self.directory = directory
        self.secrets = secrets
    }

    private var file: URL { directory.appending(path: "connections.json") }
    private var legacyFile: URL { directory.appending(path: "context.json") }

    private func tokenName(_ id: UUID) -> String { "token-\(id.uuidString)" }

    public func load() throws -> ConnectionList {
        try migrateLegacyConnection()
        guard let data = try? Data(contentsOf: file) else { return ConnectionList() }
        return try JSONDecoder().decode(ConnectionList.self, from: data)
    }

    private func save(_ list: ConnectionList) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try JSONEncoder().encode(list).write(to: file, options: .atomic)
    }

    /// Adds a connection and makes it active. It replaces any connection to the same head.
    @discardableResult
    public func add(name: String, context: ClientContext, token: String) throws -> SavedConnection {
        var list = try load()
        let connection = SavedConnection(name: name.isEmpty ? context.head : name, context: context)
        try secrets.write(tokenName(connection.id), Data(token.utf8))
        let replaced = list.connections.filter { $0.context.head == context.head }
        list.connections.removeAll { $0.context.head == context.head }
        list.connections.append(connection)
        list.activeID = connection.id
        try save(list)
        for old in replaced { try? secrets.delete(tokenName(old.id)) }
        return connection
    }

    public func activate(id: UUID) throws {
        var list = try load()
        guard list.connections.contains(where: { $0.id == id }) else { throw ConnectionStoreError.unknownConnection }
        list.activeID = id
        try save(list)
    }

    /// Removes a connection even if its token can't be deleted. A token left behind
    /// isn't used again, because every connection gets a new item.
    public func remove(id: UUID) throws {
        var list = try load()
        list.connections.removeAll { $0.id == id }
        if list.activeID == id { list.activeID = list.connections.first?.id }
        try save(list)
        try? secrets.delete(tokenName(id))
    }

    public func token(for connection: SavedConnection) throws -> String {
        guard let token = try? secrets.read(tokenName(connection.id)) else {
            throw ConnectionStoreError.unreadableToken(connection.name)
        }
        return String(decoding: token, as: UTF8.self)
    }

    public func activeCredentials() throws -> (connection: SavedConnection, token: String)? {
        guard let connection = try load().active else { return nil }
        return (connection, try token(for: connection))
    }

    /// Moves the single connection that older builds saved. If its token can't be read,
    /// the connection still appears, and it says so when used.
    private func migrateLegacyConnection() throws {
        let files = FileManager.default
        guard !files.fileExists(atPath: file.path(percentEncoded: false)),
              let data = try? Data(contentsOf: legacyFile),
              let context = try? JSONDecoder().decode(ClientContext.self, from: data)
        else { return }
        let connection = SavedConnection(name: context.head, context: context)
        let token = try? secrets.read(ClientContextStore.tokenName)
        if let token { try secrets.write(tokenName(connection.id), token) }
        var list = ConnectionList()
        list.connections = [connection]
        list.activeID = connection.id
        try save(list)
        try? files.removeItem(at: legacyFile)
        if token != nil { try? secrets.delete(ClientContextStore.tokenName) }
    }
}
