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
        migrator.registerMigration("v2") { db in
            // A node's stats history at a few resolutions (`StatsTier`); `ts` is the bucket's
            // last heartbeat, in Unix seconds.
            try db.execute(sql: """
                CREATE TABLE node_stats (
                    node TEXT NOT NULL, tier INTEGER NOT NULL, ts REAL NOT NULL, point TEXT NOT NULL,
                    PRIMARY KEY (node, tier, ts)
                ) WITHOUT ROWID;
                """)
        }
        migrator.registerMigration("v3") { db in
            // Each instance's stats history, like `node_stats`. Keyed by service and instance,
            // never PID, so a restarted process continues its series.
            try db.execute(sql: """
                CREATE TABLE process_stats (
                    node TEXT NOT NULL, service TEXT NOT NULL, instance INTEGER NOT NULL,
                    tier INTEGER NOT NULL, ts REAL NOT NULL, point TEXT NOT NULL,
                    PRIMARY KEY (node, service, instance, tier, ts)
                ) WITHOUT ROWID;
                CREATE INDEX process_stats_by_age ON process_stats (node, tier, ts);
                """)
        }
        migrator.registerMigration("v4") { db in
            // Head-wide settings changed through the API, as JSON per key.
            try db.execute(sql: "CREATE TABLE settings (key TEXT PRIMARY KEY, value TEXT NOT NULL);")
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

    // MARK: Stats history

    public func saveStats(node: NodeID, tier: StatsTier, point: NodeStatsPoint) throws {
        let json = String(decoding: try JSONEncoder().encode(point), as: UTF8.self)
        try pool.write { db in
            try db.execute(sql: "INSERT OR REPLACE INTO node_stats (node, tier, ts, point) VALUES (?, ?, ?, ?)",
                           arguments: [node.rawValue, tier.rawValue, point.date.timeIntervalSince1970, json])
        }
    }

    /// Oldest first, from `since` on.
    public func stats(node: NodeID, tier: StatsTier, since: Date?) throws -> [NodeStatsPoint] {
        try pool.read { db in
            try String.fetchAll(db, sql: "SELECT point FROM node_stats WHERE node = ? AND tier = ? AND ts >= ? ORDER BY ts",
                                arguments: [node.rawValue, tier.rawValue, since?.timeIntervalSince1970 ?? 0])
                .compactMap { try? JSONDecoder().decode(NodeStatsPoint.self, from: Data($0.utf8)) }
        }
    }

    /// Drops each tier's points older than its retention.
    public func pruneStats(node: NodeID, keepingDays days: Int = HistoryRetention.defaultDays, now: Date = Date()) throws {
        try pool.write { db in
            for tier in StatsTier.allCases {
                try db.execute(sql: "DELETE FROM node_stats WHERE node = ? AND tier = ? AND ts < ?",
                               arguments: [node.rawValue, tier.rawValue, now.timeIntervalSince1970 - tier.retention(keepingDays: days)])
            }
        }
    }

    public func deleteStats(node: NodeID) throws {
        try pool.write { db in
            try db.execute(sql: "DELETE FROM node_stats WHERE node = ?", arguments: [node.rawValue])
            try db.execute(sql: "DELETE FROM process_stats WHERE node = ?", arguments: [node.rawValue])
        }
    }

    // MARK: Settings

    /// The saved retention, else the default.
    public func historyRetention() throws -> HistoryRetention {
        try pool.read { db in
            try String.fetchOne(db, sql: "SELECT value FROM settings WHERE key = 'history_retention'")
                .flatMap { try? JSONDecoder().decode(HistoryRetention.self, from: Data($0.utf8)) }
        } ?? HistoryRetention()
    }

    public func saveHistoryRetention(_ retention: HistoryRetention) throws {
        let json = String(decoding: try JSONEncoder().encode(retention), as: UTF8.self)
        try pool.write { db in
            try db.execute(sql: "INSERT OR REPLACE INTO settings (key, value) VALUES ('history_retention', ?)", arguments: [json])
        }
    }

    // MARK: Process stats history

    public struct ClosedProcessPoint: Sendable {
        public var service: String
        public var instance: Int
        public var tier: StatsTier
        public var point: ProcessStatsPoint

        public init(service: String, instance: Int, tier: StatsTier, point: ProcessStatsPoint) {
            self.service = service
            self.instance = instance
            self.tier = tier
            self.point = point
        }
    }

    /// One transaction for a heartbeat's worth of closed buckets.
    public func saveProcessStats(node: NodeID, _ points: [ClosedProcessPoint]) throws {
        guard !points.isEmpty else { return }
        let encoder = JSONEncoder()
        let rows = try points.map { ($0, String(decoding: try encoder.encode($0.point), as: UTF8.self)) }
        try pool.write { db in
            for (closed, json) in rows {
                try db.execute(sql: """
                    INSERT OR REPLACE INTO process_stats (node, service, instance, tier, ts, point) VALUES (?, ?, ?, ?, ?, ?)
                    """, arguments: [node.rawValue, closed.service, closed.instance, closed.tier.rawValue,
                                     closed.point.date.timeIntervalSince1970, json])
            }
        }
    }

    /// Oldest first, from `since` on.
    public func processStats(node: NodeID, service: String, instance: Int, tier: StatsTier,
                             since: Date?) throws -> [ProcessStatsPoint] {
        try pool.read { db in
            try String.fetchAll(db, sql: """
                SELECT point FROM process_stats
                WHERE node = ? AND service = ? AND instance = ? AND tier = ? AND ts >= ? ORDER BY ts
                """, arguments: [node.rawValue, service, instance, tier.rawValue, since?.timeIntervalSince1970 ?? 0])
                .compactMap { try? JSONDecoder().decode(ProcessStatsPoint.self, from: Data($0.utf8)) }
        }
    }

    /// Drops each tier's points older than its retention, for every instance on the node,
    /// deleted services included.
    public func pruneProcessStats(node: NodeID, keepingDays days: Int = HistoryRetention.defaultDays,
                                  now: Date = Date()) throws {
        try pool.write { db in
            for tier in StatsTier.allCases {
                try db.execute(sql: "DELETE FROM process_stats WHERE node = ? AND tier = ? AND ts < ?",
                               arguments: [node.rawValue, tier.rawValue, now.timeIntervalSince1970 - tier.retention(keepingDays: days)])
            }
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
