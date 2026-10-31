import Foundation
import GRDB
import TenderCore

/// What should be true of a service or instance. `absent` marks an instance that
/// is being removed: the reconciler boots it out, then forgets the row.
public enum DesiredState: String, Sendable {
    case running, stopped, absent
}

public struct ServiceRecord: Sendable, Equatable {
    public var spec: ServiceSpec
    public var desired: DesiredState
}

public struct InstanceRecord: Sendable, Equatable {
    public var service: String
    public var instance: Int
    public var label: String
    public var desired: DesiredState
}

/// Desired state of this node, in `state.db` (WAL). Source of truth for the node.
public struct StateStore: Sendable {
    let pool: DatabasePool
    private let labelFor: @Sendable (String, Int) -> String

    public init(environment: TenderEnvironment) throws {
        try FileManager.default.createDirectory(at: environment.root, withIntermediateDirectories: true)
        pool = try DatabasePool(path: environment.stateDB.path(percentEncoded: false))
        labelFor = { environment.serviceLabel(service: $0, instance: $1) }
        try Self.migrator.migrate(pool)
    }

    private static var migrator: DatabaseMigrator {
        var migrator = DatabaseMigrator()
        migrator.registerMigration("v1") { db in
            try db.execute(sql: """
                CREATE TABLE services (
                    name TEXT PRIMARY KEY,
                    spec TEXT NOT NULL,
                    desired TEXT NOT NULL,
                    created_at REAL NOT NULL,
                    updated_at REAL NOT NULL
                );
                CREATE TABLE instances (
                    service TEXT NOT NULL,
                    instance INTEGER NOT NULL,
                    label TEXT NOT NULL UNIQUE,
                    desired TEXT NOT NULL,
                    PRIMARY KEY (service, instance)
                );
                CREATE TABLE releases (
                    service TEXT NOT NULL,
                    sha12 TEXT NOT NULL,
                    path TEXT NOT NULL,
                    created_at REAL NOT NULL,
                    PRIMARY KEY (service, sha12)
                );
                CREATE TABLE adopted_jobs (
                    label TEXT PRIMARY KEY,
                    domain TEXT NOT NULL,
                    plist_path TEXT,
                    stdout_path TEXT,
                    stderr_path TEXT,
                    adopted_at REAL NOT NULL
                );
                """)
        }
        return migrator
    }

    /// Creates or replaces a service and wants it running. Instances beyond
    /// `spec.instances` are marked absent.
    public func upsert(_ spec: ServiceSpec) throws {
        let json = String(decoding: try JSONEncoder().encode(spec), as: UTF8.self)
        let now = Date().timeIntervalSince1970
        let labels = (0..<spec.instances).map { labelFor(spec.name, $0) }
        try pool.write { db in
            try db.execute(sql: """
                INSERT INTO services (name, spec, desired, created_at, updated_at) VALUES (?, ?, 'running', ?, ?)
                ON CONFLICT (name) DO UPDATE SET spec = excluded.spec, desired = 'running', updated_at = excluded.updated_at
                """, arguments: [spec.name, json, now, now])
            for (instance, label) in labels.enumerated() {
                try db.execute(sql: """
                    INSERT INTO instances (service, instance, label, desired) VALUES (?, ?, ?, 'running')
                    ON CONFLICT (service, instance) DO UPDATE SET desired = 'running'
                    """, arguments: [spec.name, instance, label])
            }
            try db.execute(sql: "UPDATE instances SET desired = 'absent' WHERE service = ? AND instance >= ?",
                           arguments: [spec.name, spec.instances])
        }
    }

    /// Returns false if the service does not exist.
    @discardableResult
    public func setDesired(_ desired: DesiredState, service: String) throws -> Bool {
        try pool.write { db in
            try db.execute(sql: "UPDATE services SET desired = ?, updated_at = ? WHERE name = ?",
                           arguments: [desired.rawValue, Date().timeIntervalSince1970, service])
            guard db.changesCount > 0 else { return false }
            try db.execute(sql: "UPDATE instances SET desired = ? WHERE service = ? AND desired != 'absent'",
                           arguments: [desired.rawValue, service])
            return true
        }
    }

    /// Removes the service and marks its instances absent. Returns false if it did not exist.
    @discardableResult
    public func deleteService(_ name: String) throws -> Bool {
        try pool.write { db in
            try db.execute(sql: "DELETE FROM services WHERE name = ?", arguments: [name])
            let existed = db.changesCount > 0
            try db.execute(sql: "UPDATE instances SET desired = 'absent' WHERE service = ?", arguments: [name])
            return existed
        }
    }

    public func removeInstance(service: String, instance: Int) throws {
        try pool.write { db in
            try db.execute(sql: "DELETE FROM instances WHERE service = ? AND instance = ?",
                           arguments: [service, instance])
        }
    }

    public func services() throws -> [ServiceRecord] {
        try pool.read { db in
            try Row.fetchAll(db, sql: "SELECT spec, desired FROM services ORDER BY name").map(Self.serviceRecord)
        }
    }

    public func service(_ name: String) throws -> ServiceRecord? {
        try pool.read { db in
            try Row.fetchOne(db, sql: "SELECT spec, desired FROM services WHERE name = ?", arguments: [name])
                .map(Self.serviceRecord)
        }
    }

    public func instances() throws -> [InstanceRecord] {
        try pool.read { db in
            try Row.fetchAll(db, sql: "SELECT * FROM instances ORDER BY service, instance").map { row in
                InstanceRecord(service: row["service"], instance: row["instance"], label: row["label"],
                               desired: DesiredState(rawValue: row["desired"]) ?? .absent)
            }
        }
    }

    private static func serviceRecord(_ row: Row) throws -> ServiceRecord {
        let json: String = row["spec"]
        return ServiceRecord(spec: try JSONDecoder().decode(ServiceSpec.self, from: Data(json.utf8)),
                             desired: DesiredState(rawValue: row["desired"]) ?? .stopped)
    }
}
