import AsyncHTTPClient
import Foundation
import Testing
@testable import TenderClient
import TenderCore
import TenderLogStore
@testable import TenderHead

private let file = """
    kind: Service
    name: api
    exec: /bin/sleep
    args: ["1000"]
    env:
      MONGO_URL: "mongodb://app:literal-password@db"
    ---
    kind: Service
    name: web
    exec: /bin/sleep
    args: ["2000"]
    node: worker
    ---
    kind: Adopted
    label: homebrew.mxcl.postgresql@18
    node: worker
    """

private func request(_ yaml: String, prune: Bool = false, pruneAll: Bool = false, dryRun: Bool = false) throws -> ApplyRequest {
    ApplyRequest(items: try ServiceFile.parse(yaml).items, prune: prune, pruneAll: pruneAll, dryRun: dryRun, sha256: "feedface")
}

private func actions(_ response: ApplyResponse) -> [String] {
    response.diff.changes.map { "\($0.action.rawValue) \($0.name)@\($0.node)" }
}

@Test func applyThroughTheHeadFansOutPerNode() async throws {
    try await withCluster { head, worker async throws in
        try await worker.launchd.bootstrap(plistURL: URL(filePath: "/tmp/homebrew.mxcl.postgresql@18.plist"))

        let preview = try await head.client.apply(try request(file, dryRun: true))
        #expect(actions(preview) == ["create api@head", "create web@worker", "create homebrew.mxcl.postgresql@18@worker"])
        #expect(try await head.client.list().processes.isEmpty)

        let applied = try await head.client.apply(try request(file))
        #expect(applied.succeeded, "\(applied)")
        let processes = try await head.client.list().processes
        #expect(Set(processes.map { "\($0.service)@\($0.node)" }) == ["api@head", "web@worker", "homebrew.mxcl.postgresql@18@worker"])
        let started = (await head.launchd.bootstraps, await worker.launchd.bootstraps)

        let again = try await head.client.apply(try request(file))
        #expect(!again.diff.hasChanges)
        #expect(again.results.isEmpty)
        #expect((await head.launchd.bootstraps, await worker.launchd.bootstraps) == started, "nothing restarts")

        // Export through the head names every node and applies as a no-op.
        let exported = try ServiceFile.render(try await head.client.specs().items())
        #expect(exported.contains("node: head") && exported.contains("node: worker"))
        #expect(!(try await head.client.apply(try request(exported, prune: true))).diff.hasChanges)

        let onlyAPI = "kind: Service\nname: api\nexec: /bin/sleep\nargs: [\"1000\"]\nenv:\n  MONGO_URL: \"mongodb://app:literal-password@db\"\n"
        let pruned = try await head.client.apply(try request(onlyAPI, pruneAll: true))
        #expect(actions(pruned) == ["unchanged api@head", "prune web@worker", "prune homebrew.mxcl.postgresql@18@worker"])
        #expect(pruned.diff.prunedNodes == [NodeID("head"), NodeID("worker")])
        #expect(pruned.succeeded)
        #expect(try await head.client.list().processes.map(\.service) == ["api"])

        // One record per apply, with the file's hash and counts but no values.
        let audit = head.env.root.appending(path: "logstore/audit-\(LogStore.dayName(Date())).jsonl")
        let records = try String(contentsOf: audit, encoding: .utf8).split(separator: "\n").filter { $0.contains(#"\/v1\/apply"#) }
        #expect(records.count == 5)
        #expect(records.allSatisfy { $0.contains("sha256=feedface") })
        #expect(records.last?.contains("prune service web@worker") == true)
        #expect(!records.contains { $0.contains("literal-password") })
    }
}

@Test func headApplyRejectsUnknownNodesBeforeChangingAnything() async throws {
    try await withCluster { head, _ async throws in
        let yaml = file + "\n---\nkind: Service\nname: ghost\nexec: /bin/sleep\nnode: nowhere\n"
        do {
            _ = try await head.client.apply(try request(yaml))
            Issue.record("expected an error")
        } catch let error as TenderClientError {
            #expect(error.code == "invalid_manifest")
            #expect(error.description.contains("no node named 'nowhere'"))
        }
        #expect(try await head.client.list().processes.isEmpty)
    }
}

@Test func aNodeThatFailsIsReportedAndTheOthersGoAhead() async throws {
    try await withCluster { head, worker async throws in
        await worker.stop()
        let response = try await head.client.apply(try request(file))
        #expect(!response.succeeded)
        #expect(response.failedNodes.map(\.node) == [NodeID("worker")])
        #expect(actions(response) == ["create api@head"])
        #expect(response.results.map(\.error) == [nil])
        #expect(try await head.client.list().processes.map(\.service) == ["api"])
    }
}

@Test func readingSpecsRemotelyTakesAWriteToken() async throws {
    try await withCluster { head, _ async throws in
        _ = try await head.client.apply(try request(file.components(separatedBy: "---")[0]))
        let reader = try await head.client.createAPIToken(name: "reader", scope: .read)
        let writer = try await head.client.createAPIToken(name: "writer", scope: .write)
        let address = "127.0.0.1:\(head.apiPort)"
        let caPEM = try await ClientPinning.fetchCA(head: address, credential: reader.token)
        do {
            _ = try await TenderClient(head: address, caPEM: caPEM, token: reader.token).specs()
            Issue.record("specs can hold literal credentials")
        } catch let error as TenderClientError {
            #expect(error.code == "forbidden")
        }
        let specs = try await TenderClient(head: address, caPEM: caPEM, token: writer.token).specs()
        #expect(specs.items().map(\.name) == ["api"])
    }
}

/// The router drops empty path segments, so every spelling of `/v1/specs` reaches the
/// handler and has to meet the same check.
@Test func readingSpecsRemotelyTakesAWriteTokenHoweverThePathIsSpelled() async throws {
    try await withCluster { head, _ async throws in
        _ = try await head.client.apply(try request(file.components(separatedBy: "---")[0]))
        let reader = try await head.client.createAPIToken(name: "reader", scope: .read)
        let writer = try await head.client.createAPIToken(name: "writer", scope: .write)
        let address = "127.0.0.1:\(head.apiPort)"
        let client = try PinnedClients.client(caPEM: try await ClientPinning.fetchCA(head: address, credential: reader.token))
        func get(_ path: String, _ token: String) async throws -> (UInt, String) {
            var request = HTTPClientRequest(url: "https://\(address)\(path)")
            request.headers.add(name: "Authorization", value: "Bearer \(token)")
            let response = try await client.execute(request, timeout: .seconds(30))
            let body = try await response.body.collect(upTo: 1 << 20)
            return (response.status.code, String(buffer: body))
        }
        for path in ["/v1/specs", "/v1/specs/", "//v1/specs", "/v1//specs", "/v1/specs?node=head"] {
            let (status, body) = try await get(path, reader.token)
            #expect(status == 403, "\(path)")
            #expect(!body.contains("literal-password"), "\(path)")
        }
        let (status, body) = try await get("/v1//specs/", writer.token)
        #expect(status == 200)
        #expect(body.contains("literal-password"))
        // Other reads still take a read token.
        #expect(try await get("//v1/processes/", reader.token).0 == 200)
    }
}

/// A file for one node can't empty another: `prune` stays on the nodes the file names.
@Test func pruneOnlyTouchesTheNodesTheFileNames() async throws {
    try await withCluster { head, worker async throws in
        try await worker.launchd.bootstrap(plistURL: URL(filePath: "/tmp/homebrew.mxcl.postgresql@18.plist"))
        #expect(try await head.client.apply(try request(file)).succeeded)
        let extra = "kind: Service\nname: extra\nexec: /bin/sleep\nargs: [\"3000\"]\n"
        _ = try await head.client.apply(try request(extra))

        // api has no node, so the file names the head only.
        let onlyAPI = file.components(separatedBy: "---")[0]
        let pruned = try await head.client.apply(try request(onlyAPI, prune: true))
        #expect(actions(pruned) == ["unchanged api@head", "prune extra@head"])
        #expect(pruned.diff.prunedNodes == [NodeID("head")])
        #expect(ManifestDiffRenderer.render(pruned.diff).hasPrefix("Pruning on head: "))
        #expect(Set(try await head.client.list().processes.map { "\($0.service)@\($0.node)" })
                == ["api@head", "web@worker", "homebrew.mxcl.postgresql@18@worker"])

        // Naming the worker prunes it too, and only what that file doesn't list there.
        let workerOnly = "kind: Service\nname: web\nexec: /bin/sleep\nargs: [\"2000\"]\nnode: worker\n"
        let second = try await head.client.apply(try request(workerOnly, prune: true, dryRun: true))
        #expect(actions(second) == ["unchanged web@worker", "prune homebrew.mxcl.postgresql@18@worker"])
        #expect(second.diff.prunedNodes == [NodeID("worker")])

        let all = try await head.client.apply(try request(workerOnly, pruneAll: true, dryRun: true))
        #expect(actions(all) == ["prune api@head", "unchanged web@worker", "prune homebrew.mxcl.postgresql@18@worker"])
        #expect(all.diff.prunedNodes == [NodeID("head"), NodeID("worker")])
    }
}
