import Foundation
import LaunchdKit
import Testing
import TenderCore
@testable import TenderAgent
@testable import TenderClient

private let file = """
    kind: Service
    name: api
    exec: /bin/sleep
    args: ["1000"]
    instances: 2
    env:
      LOG_LEVEL: info
    ---
    kind: Service
    name: worker
    exec: /bin/sleep
    args: ["2000"]
    ---
    kind: Adopted
    label: homebrew.mxcl.mongodb-community
    log_path: /tmp/mongo.log
    """

private func apply(_ client: TenderClient, _ yaml: String, prune: Bool = false, dryRun: Bool = false) async throws -> ApplyResponse {
    try await client.apply(ApplyRequest(items: try ServiceFile.parse(yaml).items, prune: prune, dryRun: dryRun))
}

private func actions(_ response: ApplyResponse) -> [String] {
    response.diff.changes.map { "\($0.action.rawValue) \($0.name)" }
}

@Test func applyOverTheSocketIsIdempotent() async throws {
    let launchd = MemoryLaunchd()
    try await launchd.bootstrap(plistURL: URL(filePath: "/tmp/homebrew.mxcl.mongodb-community.plist"))
    try await withDaemon(launchd: launchd) { client, _ async throws in
        let preview = try await apply(client, file, dryRun: true)
        #expect(actions(preview) == ["create api", "create worker", "create homebrew.mxcl.mongodb-community"])
        #expect(preview.results.isEmpty)
        #expect(try await client.list().processes.isEmpty, "a dry run changes nothing")

        let first = try await apply(client, file)
        #expect(first.succeeded)
        #expect(first.results.count == 3)
        #expect(try await client.list().processes.count == 4)
        let started = await launchd.bootstraps

        let second = try await apply(client, file)
        #expect(actions(second) == ["unchanged api", "unchanged worker", "unchanged homebrew.mxcl.mongodb-community"])
        #expect(second.results.isEmpty)
        #expect(await launchd.bootstraps == started, "applying the same file again restarts nothing")

        // A stopped service stays stopped while its spec doesn't change.
        _ = try await client.stop(service: "worker")
        _ = try await apply(client, file)
        #expect(try await client.list().processes.first { $0.service == "worker" }?.state == .stopped)

        let edited = file.replacingOccurrences(of: "instances: 2", with: "instances: 3")
        let third = try await apply(client, edited)
        #expect(actions(third).first == "update api")
        #expect(third.diff.changes.first?.fields == [FieldChange(field: "instances", from: "2", to: "3")])
        #expect(try await client.list().processes.filter { $0.service == "api" }.count == 3)
    }
}

@Test func pruneRemovesWhatTheFileDoesNotList() async throws {
    let launchd = MemoryLaunchd()
    try await launchd.bootstrap(plistURL: URL(filePath: "/tmp/homebrew.mxcl.mongodb-community.plist"))
    try await withDaemon(launchd: launchd) { client, _ async throws in
        _ = try await apply(client, file)
        let only = "kind: Service\nname: api\nexec: /bin/sleep\nargs: [\"1000\"]\ninstances: 2\nenv:\n  LOG_LEVEL: info\n"

        #expect(actions(try await apply(client, only)) == ["unchanged api"], "without --prune, the rest is left alone")
        #expect(try await client.list().processes.count == 4)

        let pruned = try await apply(client, only, prune: true)
        #expect(actions(pruned) == ["unchanged api", "prune worker", "prune homebrew.mxcl.mongodb-community"])
        #expect(pruned.succeeded)
        let left = try await client.list().processes
        #expect(Set(left.map(\.service)) == ["api"])
        #expect(await launchd.loaded.contains("homebrew.mxcl.mongodb-community"), "abandoning leaves the job running")
    }
}

@Test func exportAppliesAsANoOp() async throws {
    let launchd = MemoryLaunchd()
    try await launchd.bootstrap(plistURL: URL(filePath: "/tmp/homebrew.mxcl.mongodb-community.plist"))
    try await launchd.bootstrap(plistURL: URL(filePath: "/tmp/homebrew.mxcl.redis.plist"))
    try await withDaemon(launchd: launchd) { client, _ async throws in
        _ = try await apply(client, file)
        // Started by hand, the old way, with a secret reference.
        _ = try await client.adopt(label: "homebrew.mxcl.redis")
        let exported = try ServiceFile.render(try await client.specs().items())
        #expect(exported.contains("node: "), "every item names its node")
        #expect(exported.contains("log_path: /tmp/mongo.log"))
        #expect(!exported.contains("homebrew.mxcl.redis\nlog_path"), "only overridden log paths are exported")

        let again = try await apply(client, exported, prune: true)
        #expect(!again.diff.hasChanges, "\(again.diff.changes)")
        #expect(again.diff.changes.count == 4)
    }
}

/// launchd forgets a booted-out job, so whether its log path was overridden has to come
/// from the record. Redis logs to stdout only, which looks just like an override.
@Test func aStoppedAdoptedJobStaysUnchanged() async throws {
    let launchd = MemoryLaunchd()
    try await launchd.bootstrap(plistURL: URL(filePath: "/tmp/homebrew.mxcl.mongodb-community.plist"))
    try await launchd.bootstrap(plistURL: URL(filePath: "/tmp/homebrew.mxcl.redis.plist"))
    await launchd.setStdoutPath("/tmp/redis.log", label: "homebrew.mxcl.redis")
    try await withDaemon(launchd: launchd) { client, _ async throws in
        let yaml = file + "\n---\nkind: Adopted\nlabel: homebrew.mxcl.redis\n"
        _ = try await apply(client, yaml)
        let exported = try ServiceFile.render(try await client.specs().items())
        _ = try await client.stop(service: "homebrew.mxcl.mongodb-community")
        _ = try await client.stop(service: "homebrew.mxcl.redis")
        #expect(!(await launchd.loaded.contains("homebrew.mxcl.mongodb-community")))

        #expect(try ServiceFile.render(try await client.specs().items()) == exported, "export doesn't depend on whether the job runs")
        let again = try await apply(client, yaml)
        #expect(!again.diff.hasChanges, "\(again.diff.changes)")
        #expect(again.results.isEmpty)
        #expect(try await client.specs().nodes.first?.adopted.map(\.logPath) == ["/tmp/mongo.log", nil])
    }
}

@Test func aServiceListedWithAndWithoutTheLocalNodeIsADuplicate() async throws {
    try await withDaemon { client, _ async throws in
        let node = try #require(try await client.specs().nodes.first?.node)
        let yaml = "kind: Service\nname: api\nexec: /bin/sleep\n---\nkind: Service\nname: api\nexec: /bin/cat\nnode: \(node)\n"
        do {
            _ = try await apply(client, yaml)
            Issue.record("expected an error")
        } catch let error as TenderClientError {
            #expect(error.code == "invalid_manifest")
            #expect(error.description.contains("twice"))
        }
        #expect(try await client.list().processes.isEmpty)
    }
}

/// The specs are stored by then, so the items say so rather than the call failing as
/// if nothing had changed.
@Test func aReconcileThatFailsIsReportedOnTheItems() async throws {
    let launchd = MemoryLaunchd()
    try await withDaemon(launchd: launchd) { client, _ async throws in
        await launchd.setListingFails(true)
        let response = try await apply(client, "kind: Service\nname: api\nexec: /bin/sleep\nargs: [\"1000\"]\n")
        #expect(response.results.count == 1)
        #expect(response.results.first?.error?.contains("launchd wasn't updated yet") == true)
        #expect(try await client.specs().nodes.first?.services.map(\.name) == ["api"])
        await launchd.setListingFails(false)
    }
}

@Test func concurrentAppliesSeeEachOthersChanges() async throws {
    try await withDaemon { client, _ async throws in
        let yaml = "kind: Service\nname: api\nexec: /bin/sleep\nargs: [\"1000\"]\n"
        async let first = apply(client, yaml)
        async let second = apply(client, yaml)
        let both = try await [first, second].map(actions)
        #expect(both.sorted { $0.joined() < $1.joined() } == [["create api"], ["unchanged api"]])
    }
}

@Test func binaryUsesTheNodesReleaseAndKeepsItAcrossApplies() async throws {
    try await withDaemon { client, env async throws in
        let yaml = "kind: Service\nname: api\nbinary: api\nargs: [\"1000\"]\n"
        let missing = try await apply(client, yaml)
        #expect(missing.results.first?.error?.contains("has no release on this node yet") == true)

        let store = try StateStore(environment: env)
        for sha12 in ["aaaaaaaaaaaa", "bbbbbbbbbbbb"] {
            let binary = env.releaseBinary(service: "api", sha12: sha12)
            try FileManager.default.createDirectory(at: binary.deletingLastPathComponent(), withIntermediateDirectories: true)
            try FileManager.default.copyItem(at: URL(filePath: "/bin/sleep"), to: binary)
            try store.recordRelease(Release(service: "api", sha12: sha12, path: binary.path(percentEncoded: false), createdAt: Date()))
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(try await apply(client, yaml).succeeded)
        #expect(try await client.specs().nodes.first?.services.first?.program == .release(sha12: "bbbbbbbbbbbb"))

        // A rollback holds: the file says "the node's release", not "the newest".
        _ = try await client.rollback(service: "api", to: "aaaaaaaaaaaa")
        #expect(!(try await apply(client, yaml).diff.hasChanges))
        #expect(try await client.specs().nodes.first?.services.first?.program == .release(sha12: "aaaaaaaaaaaa"))
        #expect(try ServiceFile.render(try await client.specs().items()).contains("binary: api"))
    }
}

@Test func applyReportsEachFailureAndGoesOn() async throws {
    try await withDaemon { client, _ async throws in
        let yaml = """
            kind: Service
            name: broken
            exec: /does/not/exist
            ---
            kind: Service
            name: api
            exec: /bin/sleep
            ---
            kind: Adopted
            label: homebrew.mxcl.nothing
            """
        let response = try await apply(client, yaml)
        #expect(!response.succeeded)
        #expect(response.results.map(\.name) == ["broken", "api", "homebrew.mxcl.nothing"])
        #expect(response.results.map { $0.error == nil } == [false, true, false])
        #expect(try await client.list().processes.map(\.service) == ["api"])
    }
}

@Test func aWorkerRefusesItemsForOtherNodes() async throws {
    try await withDaemon { client, _ async throws in
        do {
            _ = try await apply(client, "kind: Service\nname: api\nexec: /bin/sleep\nnode: elsewhere\n")
            Issue.record("expected an error")
        } catch let error as TenderClientError {
            #expect(error.code == "unknown_node")
            #expect(error.description.contains("through the head"))
        }
        let request = ApplyRequest(items: [.service(ServiceSpec(name: "shared", program: .executable("/bin/sleep")))])
        do {
            _ = try await client.apply(request)
            Issue.record("expected an error")
        } catch let error as TenderClientError {
            #expect(error.code == "invalid_manifest")
        }
        // An unpinned release can't be stored through the old start endpoint either.
        do {
            _ = try await client.start(ServiceSpec(name: "api", program: .nodeRelease))
            Issue.record("expected an error")
        } catch let error as TenderClientError {
            #expect(error.code == "invalid_release")
        }
    }
}
