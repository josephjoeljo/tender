import Foundation
import GRDB
import Testing
import TenderCore
@testable import TenderAgent

private func makeStore() throws -> (StateStore, TenderEnvironment) {
    let env = try makeTestEnvironment()
    return (try StateStore(environment: env), env)
}

@Test func createsAllTablesInWALMode() throws {
    let (store, env) = try makeStore()
    defer { try? FileManager.default.removeItem(at: env.root) }
    let (tables, journalMode) = try store.pool.read { db throws -> ([Bool], String?) in
        let tables = try ["services", "instances", "releases", "adopted_jobs"].map { try db.tableExists($0) }
        return (tables, try String.fetchOne(db, sql: "PRAGMA journal_mode"))
    }
    #expect(tables == [true, true, true, true])
    #expect(journalMode == "wal")
    // Re-opening migrates nothing and keeps working.
    _ = try StateStore(environment: env)
}

@Test func upsertScalesInstancesAndPersists() throws {
    let (store, env) = try makeStore()
    defer { try? FileManager.default.removeItem(at: env.root) }
    try store.upsert(ServiceSpec(name: "api", program: .executable("/bin/sleep"), instances: 2))
    #expect(try store.instances().map(\.desired) == [.running, .running])

    try store.upsert(ServiceSpec(name: "api", program: .executable("/bin/sleep"), instances: 1))
    #expect(try store.instances().map(\.desired) == [.running, .absent])

    let reopened = try StateStore(environment: env)
    #expect(try reopened.service("api")?.spec.instances == 1)
    #expect(try reopened.services().count == 1)
}

@Test func stopAndDeleteAreIdempotent() throws {
    let (store, env) = try makeStore()
    defer { try? FileManager.default.removeItem(at: env.root) }
    try store.upsert(ServiceSpec(name: "api", program: .executable("/bin/sleep")))

    #expect(try store.setDesired(.stopped, service: "api"))
    #expect(try store.setDesired(.stopped, service: "api"))
    #expect(try store.instances().first?.desired == .stopped)
    #expect(try !store.setDesired(.stopped, service: "nope"))

    #expect(try store.deleteService("api"))
    #expect(try !store.deleteService("api"))
    #expect(try store.instances().first?.desired == .absent)
    try store.removeInstance(service: "api", instance: 0)
    #expect(try store.instances().isEmpty)
}
