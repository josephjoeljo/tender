import Foundation
import GRDB
import TenderCore
import TenderPKI

/// The head's own small database. Everything in it is cheap to lose: nodes re-register,
/// tokens get re-issued. The CA key, which isn't, lives in the secret store.
public struct HeadStore: Sendable {
    let pool: DatabasePool

    public init(environment: TenderEnvironment) throws {
        try FileManager.default.createDirectory(at: environment.root, withIntermediateDirectories: true)
        let path = environment.root.appending(path: "head.db").path(percentEncoded: false)
        close(open(path, O_CREAT | O_RDWR | O_CLOEXEC, 0o600))
        chmod(path, 0o600)
        pool = try DatabasePool(path: path)
        var migrator = DatabaseMigrator()
        migrator.registerMigration("v1") { db in
            try db.execute(sql: """
                CREATE TABLE join_tokens (hash TEXT PRIMARY KEY, expires_at REAL NOT NULL, used_at REAL);
                CREATE TABLE api_tokens (hash TEXT PRIMARY KEY, name TEXT NOT NULL UNIQUE, scope TEXT NOT NULL, created_at REAL NOT NULL);
                CREATE TABLE revoked_nodes (node TEXT PRIMARY KEY, revoked_at REAL NOT NULL);
                CREATE TABLE nodes (id TEXT PRIMARY KEY, info TEXT NOT NULL);
                """)
        }
        try migrator.migrate(pool)
    }

    // MARK: Join tokens

    /// Stores only the hash, so a leaked database can't be used to join.
    public func addJoinToken(secret: String, expiresAt: Date) throws {
        try pool.write { db in
            try db.execute(sql: "INSERT INTO join_tokens (hash, expires_at) VALUES (?, ?)",
                           arguments: [JoinToken.hash(secret), expiresAt.timeIntervalSince1970])
        }
    }

    /// Atomically spends a token. True at most once per token, and never once expired.
    public func consumeJoinToken(secret: String, now: Date = Date()) throws -> Bool {
        try pool.write { db in
            try db.execute(sql: "UPDATE join_tokens SET used_at = ? WHERE hash = ? AND used_at IS NULL AND expires_at > ?",
                           arguments: [now.timeIntervalSince1970, JoinToken.hash(secret), now.timeIntervalSince1970])
            return db.changesCount == 1
        }
    }

    // MARK: API tokens

    public func addAPIToken(secret: String, name: String, scope: APIScope, now: Date = Date()) throws -> APITokenInfo? {
        try pool.write { db in
            if try Bool.fetchOne(db, sql: "SELECT 1 FROM api_tokens WHERE name = ?", arguments: [name]) == true { return nil }
            try db.execute(sql: "INSERT INTO api_tokens (hash, name, scope, created_at) VALUES (?, ?, ?, ?)",
                           arguments: [JoinToken.hash(secret), name, scope.rawValue, now.timeIntervalSince1970])
            return APITokenInfo(name: name, scope: scope, createdAt: now)
        }
    }

    public func apiToken(secret: String) throws -> APITokenInfo? {
        try pool.read { db in
            try Row.fetchOne(db, sql: "SELECT * FROM api_tokens WHERE hash = ?", arguments: [JoinToken.hash(secret)])
                .map(Self.tokenInfo)
        }
    }

    public func apiTokens() throws -> [APITokenInfo] {
        try pool.read { db in
            try Row.fetchAll(db, sql: "SELECT * FROM api_tokens ORDER BY name").map(Self.tokenInfo)
        }
    }

    @discardableResult
    public func removeAPIToken(name: String) throws -> Bool {
        try pool.write { db in
            try db.execute(sql: "DELETE FROM api_tokens WHERE name = ?", arguments: [name])
            return db.changesCount > 0
        }
    }

    private static func tokenInfo(_ row: Row) -> APITokenInfo {
        APITokenInfo(name: row["name"], scope: APIScope(rawValue: row["scope"]) ?? .read,
                     createdAt: Date(timeIntervalSince1970: row["created_at"]))
    }

    // MARK: Nodes

    public func revoke(node: NodeID) throws {
        try pool.write { db in
            try db.execute(sql: "INSERT OR REPLACE INTO revoked_nodes (node, revoked_at) VALUES (?, ?)",
                           arguments: [node.rawValue, Date().timeIntervalSince1970])
            try db.execute(sql: "DELETE FROM nodes WHERE id = ?", arguments: [node.rawValue])
        }
    }

    /// Whether the head has any record of the node: registered, or revoked earlier.
    public func knows(node: NodeID) throws -> Bool {
        try pool.read { db in
            try Bool.fetchOne(db, sql: """
                SELECT EXISTS (SELECT 1 FROM nodes WHERE id = ?1 UNION ALL SELECT 1 FROM revoked_nodes WHERE node = ?1)
                """, arguments: [node.rawValue]) == true
        }
    }

    /// A join token minted after the revocation is an admin letting the node back in.
    public func clearRevocation(node: NodeID) throws {
        try pool.write { db in
            try db.execute(sql: "DELETE FROM revoked_nodes WHERE node = ?", arguments: [node.rawValue])
        }
    }

    public func isRevoked(node: NodeID) throws -> Bool {
        try pool.read { db in
            try Bool.fetchOne(db, sql: "SELECT 1 FROM revoked_nodes WHERE node = ?", arguments: [node.rawValue]) == true
        }
    }

    public func saveNode(_ info: NodeInfo) throws {
        let json = String(decoding: try JSONEncoder().encode(info), as: UTF8.self)
        try pool.write { db in
            try db.execute(sql: "INSERT OR REPLACE INTO nodes (id, info) VALUES (?, ?)", arguments: [info.id.rawValue, json])
        }
    }

    public func nodes() throws -> [NodeInfo] {
        try pool.read { db in
            try String.fetchAll(db, sql: "SELECT info FROM nodes ORDER BY id").compactMap {
                try? JSONDecoder().decode(NodeInfo.self, from: Data($0.utf8))
            }
        }
    }
}
