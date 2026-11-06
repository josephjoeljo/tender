import Foundation
import Testing

@testable import TenderCore

private func makeEnvironment() -> TenderEnvironment {
    let root = URL(filePath: "/tmp/tender-test-\(UUID().uuidString.prefix(8))")
    return TenderEnvironment(mode: .development, root: root, logsDirectory: root.appending(path: "logs"),
                             plistDirectory: root.appending(path: "agents"), serviceLabelPrefix: "com.olympsis.tender.test.svc.x")
}

@Suite struct NodeIdentityTests {
    @Test func firstRunMakesAUUIDAndKeepsIt() throws {
        let env = makeEnvironment()
        defer { try? FileManager.default.removeItem(at: env.root) }
        let first = try NodeIdentity.load(environment: env)
        #expect(UUID(uuidString: first.rawValue) != nil)
        #expect(first.rawValue == first.rawValue.lowercased())
        #expect(try String(contentsOf: NodeIdentity.fileURL(env), encoding: .utf8) == first.rawValue + "\n")
    }

    @Test func aRestartReadsTheSameID() throws {
        let env = makeEnvironment()
        defer { try? FileManager.default.removeItem(at: env.root) }
        let first = try NodeIdentity.load(environment: env)
        // A new process has an empty cache: simulate it with a copy of the file's value.
        try Data("0b6f1c9e-0000-4000-8000-000000000001\n".utf8).write(to: NodeIdentity.fileURL(env))
        #expect(first != NodeID("0b6f1c9e-0000-4000-8000-000000000001"))
        let other = makeEnvironment()
        defer { try? FileManager.default.removeItem(at: other.root) }
        try FileManager.default.createDirectory(at: other.root, withIntermediateDirectories: true)
        try Data("0b6f1c9e-0000-4000-8000-000000000001\n".utf8).write(to: NodeIdentity.fileURL(other))
        #expect(try NodeIdentity.load(environment: other) == NodeID("0b6f1c9e-0000-4000-8000-000000000001"))
    }

    @Test func overrideDoesNotTouchTheFile() throws {
        let env = makeEnvironment()
        defer { try? FileManager.default.removeItem(at: env.root) }
        let persisted = try NodeIdentity.load(environment: env)
        NodeIdentity.override(NodeID("mac-mini"), environment: env)
        #expect(NodeIdentity.current(environment: env) == NodeID("mac-mini"))
        #expect(try String(contentsOf: NodeIdentity.fileURL(env), encoding: .utf8).trimmingCharacters(in: .newlines) == persisted.rawValue)
    }

    @Test func adoptReplacesThePersistedID() throws {
        let env = makeEnvironment()
        defer { try? FileManager.default.removeItem(at: env.root) }
        try NodeIdentity.adopt(NodeID("chosen"), environment: env)
        #expect(try String(contentsOf: NodeIdentity.fileURL(env), encoding: .utf8) == "chosen\n")
        #expect(NodeIdentity.current(environment: env) == NodeID("chosen"))
    }

    @Test func hostnameIsAShortLowercaseLabel() {
        let name = NodeIdentity.hostname()
        #expect(!name.isEmpty && !name.contains(".") && name == name.lowercased())
    }

    @Test func infoShowsTheHostnameWhenThereIsOne() {
        let id = NodeID("0b6f1c9e-0000-4000-8000-000000000001")
        #expect(NodeInfo(id: id, version: "1", macOS: "x", hardware: "y").displayName == id.rawValue)
        #expect(NodeInfo(id: id, version: "1", macOS: "x", hardware: "y", hostname: "mac-mini").displayName == "mac-mini")
    }
}
