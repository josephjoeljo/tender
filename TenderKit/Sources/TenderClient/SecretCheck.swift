import Foundation
import TenderCore

/// A secret a service in a service file references that won't resolve, or resolves only
/// from a cache, on the node that runs it. Built from the file and `GET /v1/secrets`, so
/// `tender apply` can say so instead of leaving instances to exit 78.
public struct SecretWarning: Sendable, Equatable, CustomStringConvertible {
    public enum Problem: Sendable, Equatable {
        /// A node-local secret that isn't set: instances exit 78 until it is.
        case notSet
        /// A GCP reference with nothing cached: instances exit 78 until a fetch works.
        case gcpNotFetched(String?)
        /// A GCP reference whose refresh failed: instances start from the cached value.
        case gcpStale(String?)
        /// A GCP reference the node hasn't seen yet, which only a start fetches.
        case gcpUnchecked
    }

    public var service: String
    public var node: NodeID?
    /// What goes between `${secret:` and `}`, or for GCP the resolved name when known.
    public var secret: String
    public var problem: Problem

    /// Unchecked GCP references are worth saying, but aren't known to be broken.
    public var isNote: Bool { problem == .gcpUnchecked }

    public var description: String {
        let on = node.map { " on \($0)" } ?? ""
        switch problem {
        case .notSet:
            let target = node.map { " --node \($0)" } ?? ""
            return "\(service): secret \(secret) isn't set\(on), so its instances exit 78. Set it with `tender secret set \(secret)\(target)`."
        case .gcpNotFetched(let error):
            return "\(service): GCP secret \(secret) couldn't be fetched\(on)\(error.map { " (\($0))" } ?? ""), so its instances exit 78 until it is."
        case .gcpStale(let error):
            return "\(service): GCP secret \(secret) couldn't be refreshed\(on)\(error.map { " (\($0))" } ?? ""). Instances start from the cached value."
        case .gcpUnchecked:
            return "\(service): GCP secret \(secret) is fetched when the service starts, so it can't be checked before applying."
        }
    }
}

public enum SecretCheck {
    /// What won't resolve for the file's services, given what their nodes report. A service
    /// without `node:` runs on the head, so any node's copy counts for it. Nodes that didn't
    /// answer are left out: there's nothing to check them against.
    public static func warnings(for items: [ManifestItem], in list: SecretList) -> [SecretWarning] {
        let unreachable = Set(list.unreachableNodes)
        var warnings: [SecretWarning] = []
        for case .service(let spec) in items {
            if let node = spec.node, unreachable.contains(node.rawValue) { continue }
            guard let refs = try? spec.secretRefs(), !refs.isEmpty else { continue }
            let onNode = { (node: NodeID) in spec.node == nil || spec.node == node }

            for ref in refs {
                guard let name = ref.secretName(service: spec.name)?.description else { continue }
                if !list.secrets.contains(where: { $0.name == name && onNode($0.node) }) {
                    warnings.append(SecretWarning(service: spec.name, node: spec.node, secret: name, problem: .notSet))
                }
            }

            let gcpRefs = refs.filter { $0.gcp != nil }
            guard !gcpRefs.isEmpty else { continue }
            let known = list.gcp.filter { $0.usedBy.contains(spec.name) && onNode($0.node) }
            for info in known {
                if info.stale {
                    warnings.append(SecretWarning(service: spec.name, node: info.node, secret: info.name, problem: .gcpStale(info.fetchError)))
                } else if !info.cached {
                    warnings.append(SecretWarning(service: spec.name, node: info.node, secret: info.name, problem: .gcpNotFetched(info.fetchError)))
                }
            }
            // A node reports only references its stored specs use, so a new service's (or a
            // newly added reference's) can't be matched until it starts.
            for ref in gcpRefs where !known.contains(where: { matches($0.name, ref) }) {
                warnings.append(SecretWarning(service: spec.name, node: spec.node, secret: ref.description, problem: .gcpUnchecked))
            }
        }
        return warnings
    }

    /// `projects/P/secrets/S@V` against a reference that may leave out the project or version.
    private static func matches(_ resolved: String, _ ref: SecretRef) -> Bool {
        guard let gcp = ref.gcp else { return false }
        let version = gcp.version ?? "latest"
        // A named source's are `<source>:projects/…`; the default source's have no prefix.
        let prefix = gcp.source.map { "\($0):" } ?? ""
        guard resolved.hasPrefix(prefix + "projects/") else { return false }
        if let project = gcp.project { return resolved == "\(prefix)projects/\(project)/secrets/\(gcp.secret)@\(version)" }
        return resolved.hasSuffix("/secrets/\(gcp.secret)@\(version)")
    }
}
