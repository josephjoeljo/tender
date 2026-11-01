import Foundation
import Testing
import TenderClient
import TenderCore

/// Refuses reads and deletes of its locked names, like a Keychain item owned by another build.
private struct LockedSecretStore: SecretStore {
    let inner: FileSecretStore
    let locked: @Sendable (String) -> Bool

    func read(_ name: String) throws -> Data? {
        if locked(name) { throw SecretStoreError.keychain(operation: "read", status: -25293) }
        return try inner.read(name)
    }

    func write(_ name: String, _ value: Data) throws {
        if locked(name) { throw SecretStoreError.keychain(operation: "delete", status: -25244) }
        try inner.write(name, value)
    }

    func delete(_ name: String) throws {
        if locked(name) { throw SecretStoreError.keychain(operation: "delete", status: -25244) }
        try inner.delete(name)
    }
}

private func makeDirectory() -> URL {
    FileManager.default.temporaryDirectory.appending(path: "tender-connections-\(UUID().uuidString)")
}

private func makeStore(_ directory: URL = makeDirectory(), locked: @escaping @Sendable (String) -> Bool = { _ in false }) -> ConnectionStore {
    let secrets = FileSecretStore(directory: directory.appending(path: "secrets"))
    return ConnectionStore(directory: directory, secrets: LockedSecretStore(inner: secrets, locked: locked))
}

private func context(_ head: String) -> ClientContext { ClientContext(head: head, caPEM: "ca-\(head)") }

@Test func startsWithNoConnections() throws {
    let store = makeStore()
    #expect(try store.load() == ConnectionList())
    #expect(try store.activeCredentials() == nil)
}

@Test func addingMakesAConnectionActiveAndSwitchingChangesIt() throws {
    let store = makeStore()
    let first = try store.add(name: "Mini", context: context("mini:7071"), token: "one")
    let second = try store.add(name: "", context: context("studio:7071"), token: "two")
    #expect(second.name == "studio:7071")
    #expect(try store.activeCredentials()?.token == "two")

    try store.activate(id: first.id)
    let active = try #require(try store.activeCredentials())
    #expect(active.connection == first)
    #expect(active.token == "one")
    #expect(try store.load().connections.count == 2)
}

@Test func addingTheSameHeadReplacesItsConnection() throws {
    let store = makeStore()
    let old = try store.add(name: "Mini", context: context("mini:7071"), token: "old")
    try store.add(name: "Mini", context: context("mini:7071"), token: "new")
    #expect(try store.load().connections.count == 1)
    #expect(try store.activeCredentials()?.token == "new")
    #expect(throws: ConnectionStoreError.unreadableToken("Mini")) { try store.token(for: old) }
}

@Test func removingTheActiveConnectionActivatesAnother() throws {
    let store = makeStore()
    let first = try store.add(name: "Mini", context: context("mini:7071"), token: "one")
    let second = try store.add(name: "Studio", context: context("studio:7071"), token: "two")
    try store.remove(id: second.id)
    #expect(try store.load().activeID == first.id)
    try store.remove(id: first.id)
    #expect(try store.load() == ConnectionList())
}

@Test func anUnreadableTokenOnlyAffectsItsOwnConnection() throws {
    let directory = makeDirectory()
    let good = try makeStore(directory).add(name: "Good", context: context("good:7071"), token: "good")
    let stuck = try makeStore(directory).add(name: "Stuck", context: context("stuck:7071"), token: "stuck")
    let stuckName = "token-\(stuck.id.uuidString)"
    let store = makeStore(directory) { $0 == stuckName }

    #expect(throws: ConnectionStoreError.unreadableToken("Stuck")) { try store.activeCredentials() }
    #expect(try store.token(for: good) == "good")

    // A token that can't be deleted doesn't stop the connection being removed and added again.
    try store.remove(id: stuck.id)
    #expect(try store.load().connections == [good])
    try store.add(name: "Stuck", context: context("stuck:7071"), token: "fresh")
    #expect(try store.activeCredentials()?.token == "fresh")
}

@Test func movesAnOlderSavedConnection() throws {
    let directory = makeDirectory()
    let secrets = FileSecretStore(directory: directory.appending(path: "secrets"))
    try ClientContextStore(directory: directory, secrets: secrets).save(context("mini:7071"), token: "legacy")

    let store = makeStore(directory)
    let active = try #require(try store.activeCredentials())
    #expect(active.connection.context == context("mini:7071"))
    #expect(active.token == "legacy")
    #expect(!FileManager.default.fileExists(atPath: directory.appending(path: "context.json").path(percentEncoded: false)))
    #expect(try secrets.read("api-token") == nil)
}

@Test func movesAnOlderConnectionWhoseTokenCantBeRead() throws {
    let directory = makeDirectory()
    let secrets = FileSecretStore(directory: directory.appending(path: "secrets"))
    try ClientContextStore(directory: directory, secrets: secrets).save(context("mini:7071"), token: "legacy")

    let store = makeStore(directory) { $0 == "api-token" }
    #expect(try store.load().connections.map(\.context.head) == ["mini:7071"])
    #expect(throws: ConnectionStoreError.unreadableToken("mini:7071")) { try store.activeCredentials() }
    let old = try #require(try store.load().active)
    try store.remove(id: old.id)
    try store.add(name: "Mini", context: context("mini:7071"), token: "fresh")
    #expect(try store.activeCredentials()?.token == "fresh")
}
