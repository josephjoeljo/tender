import Foundation
import TenderCore

/// The node's half of `tender apply`: the head splits a file by node and each node
/// diffs and applies its own part, against its own state, which is the source of truth.
extension ProcessController {
    func localNode() throws -> NodeID {
        try identities?.config()?.nodeID ?? NodeID(defaultNodeID())
    }

    func specs() async throws -> NodeSpecs {
        var adopted: [AdoptedItem] = []
        for job in try store.adoptedJobs() {
            adopted.append(AdoptedItem(label: job.label, logPath: try await adoption.logPathOverride(job)))
        }
        return NodeSpecs(node: try localNode(), services: try store.services().map(\.spec), adopted: adopted)
    }

    /// Unchanged items aren't touched at all, so applying the same file again restarts
    /// nothing, and leaves a service someone stopped stopped.
    func applyManifest(_ request: ApplyRequest) async throws -> ApplyResponse {
        let node = try localNode()
        do {
            try Manifest(items: request.items).validate()
        } catch let error as ManifestError {
            throw APIFailure(status: .badRequest, code: "invalid_manifest", message: error.message)
        }
        if let other = request.items.first(where: { $0.node != nil && $0.node != node }), let target = other.node {
            throw APIFailure(status: .badRequest, code: "unknown_node",
                             message: "\(other.kind.rawValue) '\(other.name)' is for node '\(target)', but this daemon is '\(node)' and not a head. Apply the file through the head.")
        }
        let current = try await specs()
        let diff = ManifestDiff.compute(items: request.items, current: [current], defaultNode: node, prune: request.prune)
        guard !request.dryRun else { return ApplyResponse(diff: diff, dryRun: true) }

        var results: [ApplyItemResult] = []
        var reconcile = false
        // Specs replaced or pruned, as they were: their secret files go once the reconcile is done.
        var replaced: [(old: ServiceSpec, new: ServiceSpec?)] = []
        for change in diff.changes where change.action != .unchanged {
            var result = ApplyItemResult(action: change.action, kind: change.kind, name: change.name, node: node)
            let item = request.items.first { $0.kind == change.kind && $0.name == change.name }
            do {
                switch (change.action, item) {
                case (.create, .service(var spec)?), (.update, .service(var spec)?):
                    spec.program = try pinned(spec, current: current)
                    try validate(spec)
                    try await fetchGCPSecrets(for: spec, force: true)
                    if let old = try store.service(spec.name)?.spec { replaced.append((old, spec)) }
                    try store.upsert(spec)
                    reconcile = true
                case (.create, .adopted(let job)?), (.update, .adopted(let job)?):
                    _ = try await adopt(job.request)
                case (.prune, _) where change.kind == .service:
                    if let old = try store.service(change.name)?.spec { replaced.append((old, nil)) }
                    try store.deleteService(change.name)
                    reconcile = true
                case (.prune, _):
                    try adoption.forget(label: change.name)
                default:
                    continue
                }
            } catch let failure as APIFailure {
                result.error = failure.message
            } catch {
                result.error = "\(error)"
            }
            results.append(result)
        }
        // One pass for the whole file. A label that fails is retried by the next sweep.
        if reconcile {
            let report = try await reconciler.reconcile()
            for index in results.indices where results[index].kind == .service && results[index].error == nil {
                let prefix = "\(environment.serviceLabelPrefix).\(results[index].name)."
                if let failure = report.failures.first(where: { $0.label.hasPrefix(prefix) }) {
                    results[index].error = "\(failure.label): \(failure.message)"
                }
            }
            for (old, new) in replaced { removeSecretFiles(of: old, keeping: new) }
        }
        return ApplyResponse(diff: diff, results: results, dryRun: false)
    }

    /// `binary:` keeps the release the service runs, so that a rollback survives the next
    /// apply. A new service, or one that ran an executable, gets the newest release.
    private func pinned(_ spec: ServiceSpec, current: NodeSpecs) throws -> ProgramSource {
        guard spec.program.isNodeRelease else { return spec.program }
        if case .release(let sha12)? = current.services.first(where: { $0.name == spec.name })?.program {
            return .release(sha12: sha12)
        }
        guard let newest = try store.releases(service: spec.name).first else {
            let bin = environment.binDirectory.appending(path: spec.name).path(percentEncoded: false)
            throw APIFailure(status: .conflict, code: "no_release",
                             message: "'\(spec.name)' has no release on this node yet. Put its binary in \(bin)/ first.")
        }
        return .release(sha12: newest.sha12)
    }
}
