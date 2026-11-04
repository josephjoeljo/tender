import Foundation
import Testing
import TenderCore

private let mac1 = NodeID("mac-1")
private let mac2 = NodeID("mac-2")
private let api = ServiceSpec(name: "api", program: .executable("/bin/sleep"), arguments: ["1000"],
                              environment: ["LOG_LEVEL": "info", "MONGO_URL": "mongodb://app:${secret:MONGO_PASSWORD}@db"])

@Test func diffSortsItemsIntoCreateUpdateUnchangedAndPrune() {
    var worker = api
    worker.name = "worker"
    var changed = api
    changed.instances = 2
    let current = [NodeSpecs(node: mac1, services: [api, worker], adopted: [AdoptedItem(label: "homebrew.mxcl.redis")]),
                   NodeSpecs(node: mac2, services: [worker])]
    var web = api
    web.name = "web"
    web.node = mac2
    let items: [ManifestItem] = [.service(changed), .service(worker), .service(web)]

    let kept = ManifestDiff.compute(items: items, current: current, defaultNode: mac1, prune: false)
    #expect(kept.changes.map(\.action) == [.update, .unchanged, .create])
    #expect(kept.changes.map(\.node) == [mac1, mac1, mac2])
    #expect(kept.changes[0].fields == [FieldChange(field: "instances", from: "1", to: "2")])
    #expect(kept.summary == "1 to create, 1 to update, 1 unchanged, 0 to prune")

    let pruned = ManifestDiff.compute(items: items, current: current, defaultNode: mac1, prune: true)
    let prunes = pruned.changes.filter { $0.action == .prune }
    #expect(prunes.map { "\($0.kind.rawValue) \($0.name)@\($0.node)" } == ["adopted homebrew.mxcl.redis@mac-1", "service worker@mac-2"])
}

@Test func applyingTheCurrentStateIsANoOp() {
    let current = [NodeSpecs(node: mac1, services: [api], adopted: [AdoptedItem(label: "homebrew.mxcl.mongodb-community", logPath: "/var/log/m.log")])]
    let items = SpecList(nodes: current).items()
    let diff = ManifestDiff.compute(items: items, current: current, defaultNode: mac2, prune: true)
    #expect(!diff.hasChanges)
    #expect(diff.changes.map(\.action) == [.unchanged, .unchanged])
}

@Test func diffShowsWhichVariablesChangedButNeverTheirValues() {
    var new = api
    new.environment = ["LOG_LEVEL": "debug", "TOKEN": "hunter2"]
    new.arguments = ["2000"]
    let fields = ManifestDiff.fieldChanges(from: api, to: new)
    #expect(fields.map(\.field) == ["args", "env.LOG_LEVEL", "env.MONGO_URL", "env.TOKEN"])
    #expect(fields.first == FieldChange(field: "args", from: #"["1000"]"#, to: #"["2000"]"#))
    let text = "\(fields)"
    #expect(!text.contains("hunter2") && !text.contains("debug") && !text.contains("mongodb"))
}

@Test func aNodeReleaseMatchesWhicheverReleaseTheNodeRuns() {
    var pinned = api
    pinned.program = .release(sha12: "abcdef012345")
    var file = api
    file.program = .nodeRelease
    #expect(ManifestDiff.fieldChanges(from: pinned, to: file).isEmpty)
    #expect(ManifestDiff.fieldChanges(from: api, to: file) == [FieldChange(field: "program", from: "exec /bin/sleep", to: "binary api")])
    var other = pinned
    other.program = .release(sha12: "999999999999")
    #expect(ManifestDiff.fieldChanges(from: pinned, to: other).map(\.field) == ["program"])
}

@Test func nodeAndLogPathsAreNotFields() {
    var moved = api
    moved.node = mac2
    moved.logPaths = LogPaths(stdout: "/tmp/x")
    #expect(ManifestDiff.fieldChanges(from: api, to: moved).isEmpty)
}

@Test func adoptedJobsDiffOnTheirLogPath() {
    let current = [NodeSpecs(node: mac1, adopted: [AdoptedItem(label: "homebrew.mxcl.postgresql@18")])]
    let diff = ManifestDiff.compute(items: [.adopted(AdoptedItem(label: "homebrew.mxcl.postgresql@18", logPath: "/var/log/pg.log"))],
                                    current: current, defaultNode: mac1, prune: false)
    #expect(diff.changes.map(\.action) == [.update])
    #expect(diff.changes[0].fields == [FieldChange(field: "log_path", from: nil, to: "/var/log/pg.log")])
}

@Test func validationNamesTheItem() {
    func message(_ items: [ManifestItem], nodes: Set<NodeID>? = nil) -> String? {
        do {
            try Manifest(items: items).validate(knownNodes: nodes)
            return nil
        } catch {
            return (error as? ManifestError)?.message
        }
    }
    #expect(message([.service(api)]) == nil)
    var bad = api
    bad.name = "shared"
    #expect(message([.service(bad)])?.contains("reserved") == true)
    bad = api
    bad.environment["X"] = "${secret:not-valid}"
    #expect(message([.service(bad)])?.hasPrefix("service 'api': ") == true)
    bad = api
    bad.secretFiles = ["/etc/key.json": "a/b"]
    #expect(message([.service(bad)])?.contains("secret_files") == true)
    bad.secretFiles = ["relative.json": "KEY"]
    #expect(message([.service(bad)])?.contains("absolute") == true)
    bad = api
    bad.program = .executable("bin/api")
    #expect(message([.service(bad)])?.contains("absolute") == true)
    bad = api
    bad.instances = 0
    #expect(message([.service(bad)])?.contains("instances") == true)
    #expect(message([.service(api), .service(api)])?.contains("twice") == true)
    var placed = api
    placed.node = mac2
    #expect(message([.service(placed)], nodes: [mac1])?.contains("no node named 'mac-2'") == true)
    #expect(message([.adopted(AdoptedItem(label: "has space"))]) != nil)
}

@Test func secretFileReferencesParseLikeTemplates() {
    #expect(SecretRef(reference: "GCP_KEY") == SecretRef(name: "GCP_KEY"))
    #expect(SecretRef(reference: "shared/GCP_KEY") == SecretRef(name: "GCP_KEY", shared: true))
    for bad in ["", "a/b", "1X", "X}", "X}${secret:Y", "api/X"] {
        #expect(SecretRef(reference: bad) == nil, "\(bad)")
    }
}

@Test func manifestItemsRoundTripThroughJSON() throws {
    let items: [ManifestItem] = [.service(api), .adopted(AdoptedItem(label: "homebrew.mxcl.redis", node: mac1, logPath: "/x"))]
    let request = ApplyRequest(items: items, prune: true, dryRun: true, sha256: "abc")
    #expect(try JSONDecoder().decode(ApplyRequest.self, from: JSONEncoder().encode(request)) == request)
}
