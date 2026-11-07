import Foundation
import Testing
import TenderCore
@testable import TenderClient

private let mini = NodeID("mac-mini")
private let mini2 = NodeID("mac-mini-2")

private func api(node: NodeID? = mini, env: [String: String], files: [String: String] = [:]) -> ManifestItem {
    .service(ServiceSpec(name: "api", program: .executable("/opt/api"), environment: env, node: node, secretFiles: files))
}

private func local(_ name: String, on node: NodeID) -> SecretInfo {
    SecretInfo(name: name, scope: name.hasPrefix("shared/") ? .shared : .service, node: node, updatedAt: Date(), revision: 1, usedBy: ["api"])
}

@Suite struct SecretCheckTests {
    @Test func localSecretsSetOnTheNodeResolve() {
        let items = [api(env: ["A": "${secret:MONGO_PASSWORD}", "B": "${secret:shared/JWT}"])]
        let list = SecretList(secrets: [local("api/MONGO_PASSWORD", on: mini), local("shared/JWT", on: mini)])
        #expect(SecretCheck.warnings(for: items, in: list).isEmpty)
    }

    @Test func localSecretMissingOrOnAnotherNodeWarns() {
        let items = [api(env: ["A": "${secret:MONGO_PASSWORD}"], files: ["/opt/api/key.json": "shared/KEY"])]
        let list = SecretList(secrets: [local("api/MONGO_PASSWORD", on: mini2)])
        let warnings = SecretCheck.warnings(for: items, in: list)
        #expect(warnings.map(\.secret) == ["api/MONGO_PASSWORD", "shared/KEY"])
        #expect(warnings.allSatisfy { $0.problem == .notSet && !$0.isNote })
        #expect(warnings[0].description.contains("tender secret set api/MONGO_PASSWORD --node mac-mini"))
    }

    @Test func serviceWithoutNodeAcceptsAnyNode() {
        let items = [api(node: nil, env: ["A": "${secret:MONGO_PASSWORD}"])]
        let list = SecretList(secrets: [local("api/MONGO_PASSWORD", on: mini2)])
        #expect(SecretCheck.warnings(for: items, in: list).isEmpty)
    }

    @Test func unreachableNodesAreSkipped() {
        let items = [api(env: ["A": "${secret:MONGO_PASSWORD}"])]
        let list = SecretList(secrets: [], unreachableNodes: ["mac-mini"])
        #expect(SecretCheck.warnings(for: items, in: list).isEmpty)
    }

    @Test func gcpStatusesBecomeWarnings() {
        let items = [api(env: ["A": "${secret:gcp:jwt}", "B": "${secret:gcp:stripe@3}", "C": "${secret:gcp:projects/p/secrets/maps}"])]
        let list = SecretList(secrets: [], gcp: [
            GCPSecretInfo(name: "projects/p/secrets/jwt@latest", node: mini, cached: true, usedBy: ["api"]),
            GCPSecretInfo(name: "projects/p/secrets/stripe@3", node: mini, cached: true, usedBy: ["api"], fetchError: "HTTP 503"),
            GCPSecretInfo(name: "projects/p/secrets/maps@latest", node: mini, cached: false, usedBy: ["api"],
                          fetchError: "HTTP 403: grant roles/secretmanager.secretAccessor"),
        ])
        let warnings = SecretCheck.warnings(for: items, in: list)
        #expect(warnings.map(\.problem) == [.gcpStale("HTTP 503"), .gcpNotFetched("HTTP 403: grant roles/secretmanager.secretAccessor")])
        #expect(warnings[1].description.contains("exit 78"))
    }

    @Test func gcpReferenceTheNodeHasntSeenIsANote() {
        let items = [api(env: ["A": "${secret:gcp:jwt}", "B": "${secret:gcp:new-one}"])]
        let list = SecretList(secrets: [], gcp: [GCPSecretInfo(name: "projects/p/secrets/jwt@latest", node: mini, cached: true, usedBy: ["api"])])
        let warnings = SecretCheck.warnings(for: items, in: list)
        #expect(warnings.map(\.secret) == ["gcp:new-one"])
        #expect(warnings.first?.isNote == true)
    }

    @Test func adoptedItemsAndPlainServicesAreIgnored() {
        let items: [ManifestItem] = [api(env: ["LOG_LEVEL": "info"])]
        #expect(SecretCheck.warnings(for: items, in: SecretList(secrets: [])).isEmpty)
    }
}

@Test func namedSourceStatusesMatchOnlyTheirOwnSource() {
    let items = [api(env: ["A": "${secret:billing:STRIPE_KEY}"])]
    let list = SecretList(secrets: [], gcp: [
        GCPSecretInfo(name: "projects/billing-123/secrets/STRIPE_KEY@latest", node: mini, cached: true, usedBy: ["api"]),
    ])
    #expect(SecretCheck.warnings(for: items, in: list).map(\.problem) == [.gcpUnchecked],
            "the default source's copy isn't the named source's")
    let named = SecretList(secrets: [], gcp: [
        GCPSecretInfo(name: "billing:projects/billing-123/secrets/STRIPE_KEY@latest", node: mini, cached: true, usedBy: ["api"]),
    ])
    #expect(SecretCheck.warnings(for: items, in: named).isEmpty)
}
