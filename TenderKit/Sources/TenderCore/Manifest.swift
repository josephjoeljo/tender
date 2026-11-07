import Foundation

extension ProgramSource {
    /// `binary:` in a service file: the release the node already runs, else its newest.
    /// Only ever in transit: the node pins a real sha12 before it stores the spec, so that
    /// applying a file again never moves a service off a release it was rolled back to.
    public static let nodeRelease = ProgramSource.release(sha12: "")

    public var isNodeRelease: Bool { self == .nodeRelease }
}

/// A launchd job a service file asks Tender to manage.
public struct AdoptedItem: Codable, Sendable, Equatable {
    public var label: String
    /// Nil means the node the file is applied through.
    public var node: NodeID?
    /// Replaces the job's own `StandardOutPath`/`StandardErrorPath`.
    public var logPath: String?

    public init(label: String, node: NodeID? = nil, logPath: String? = nil) {
        self.label = label
        self.node = node
        self.logPath = logPath
    }

    public var request: AdoptRequest { AdoptRequest(label: label, logPath: logPath) }
}

public enum ManifestItemKind: String, Codable, Sendable {
    case service, adopted
}

/// One document of a service file, after `env_file` was merged in on the CLI side.
public enum ManifestItem: Codable, Sendable, Equatable {
    case service(ServiceSpec)
    case adopted(AdoptedItem)

    public var kind: ManifestItemKind {
        switch self {
        case .service: .service
        case .adopted: .adopted
        }
    }

    /// The service's name, or the adopted job's label.
    public var name: String {
        switch self {
        case .service(let spec): spec.name
        case .adopted(let item): item.label
        }
    }

    public var node: NodeID? {
        get {
            switch self {
            case .service(let spec): spec.node
            case .adopted(let item): item.node
            }
        }
        set {
            switch self {
            case .service(var spec):
                spec.node = newValue
                self = .service(spec)
            case .adopted(var item):
                item.node = newValue
                self = .adopted(item)
            }
        }
    }
}

public struct ManifestError: Error, Equatable, CustomStringConvertible {
    public var message: String
    public init(_ message: String) { self.message = message }
    public var description: String { message }
}

/// The items of a service file.
public struct Manifest: Codable, Sendable, Equatable {
    public var items: [ManifestItem]

    public init(items: [ManifestItem]) { self.items = items }

    /// What can be checked without a node: names, counts, paths and references. A node
    /// checks the rest (executables exist, users exist) when the file is applied.
    /// `knownNodes` nil skips the node check. `defaultNode` is where items without a node
    /// go, so that one listed without `node:` and once with that node is a duplicate too.
    public func validate(knownNodes: Set<NodeID>? = nil, defaultNode: NodeID? = nil) throws {
        var seen = Set<String>()
        for item in items {
            let what = "\(item.kind.rawValue) '\(item.name)'"
            switch item {
            case .service(let spec): try Self.validate(spec, what: what)
            case .adopted(let adopted): try Self.validate(adopted, what: what)
            }
            if let node = item.node, let knownNodes, !knownNodes.contains(node) {
                throw ManifestError("\(what): there's no node named '\(node)'. `tender nodes` lists them.")
            }
            let key = "\(item.kind.rawValue)/\(item.name)@\((item.node ?? defaultNode)?.rawValue ?? "")"
            guard seen.insert(key).inserted else {
                throw ManifestError("\(what) appears twice for the same node.")
            }
        }
    }

    private static func validate(_ spec: ServiceSpec, what: String) throws {
        guard ServiceSpec.isValidName(spec.name) else {
            throw ManifestError("\(what): names may only use letters, digits, '-' and '_', up to 64 characters.")
        }
        guard spec.name != "shared" else {
            throw ManifestError("\(what): 'shared' is reserved for shared secrets; pick another service name.")
        }
        guard (1...64).contains(spec.instances) else {
            throw ManifestError("\(what): instances must be between 1 and 64.")
        }
        if case .executable(let path) = spec.program, !path.hasPrefix("/") {
            throw ManifestError("\(what): exec must be an absolute path, not '\(path)'.")
        }
        if let cwd = spec.workingDirectory, !cwd.hasPrefix("/") {
            throw ManifestError("\(what): cwd must be an absolute path, not '\(cwd)'.")
        }
        guard spec.user != "root", !spec.user.isEmpty else {
            throw ManifestError("\(what): managed processes never run as root.")
        }
        for (path, ref) in spec.secretFiles {
            guard path.hasPrefix("/") else {
                throw ManifestError("\(what): secret_files paths must be absolute, not '\(path)'.")
            }
            guard SecretRef(reference: ref) != nil else {
                throw ManifestError("\(what): secret_files '\(path)': '\(ref)' isn't NAME, shared/NAME, gcp:NAME or <source>:NAME.")
            }
        }
        do {
            _ = try spec.secretRefs()
        } catch let error as SecretTemplateError {
            throw ManifestError("\(what): \(error.description)")
        }
        for key in spec.environment.keys where !SecretName.isValidName(key) {
            throw ManifestError("\(what): '\(key)' isn't a valid environment variable name.")
        }
    }

    private static func validate(_ item: AdoptedItem, what: String) throws {
        guard !item.label.isEmpty, item.label.allSatisfy({ !$0.isWhitespace && $0 != "/" }) else {
            throw ManifestError("\(what) isn't a valid launchd label.")
        }
        if let path = item.logPath, !path.hasPrefix("/") {
            throw ManifestError("\(what): log_path must be an absolute path, not '\(path)'.")
        }
    }
}

extension SecretRef {
    /// What goes between `${secret:` and `}`, written on its own, as in `secret_files`.
    public init?(reference: String) {
        guard !reference.contains("}"), !reference.contains("$"),
              let refs = try? SecretTemplate.references(in: "${secret:\(reference)}"), refs.count == 1 else { return nil }
        self = refs[0]
    }
}

/// What one node runs, in full: the input of a diff and of `tender export`. Specs can
/// hold literal values from an `env_file`, so reading them takes a write token.
public struct NodeSpecs: Codable, Sendable, Equatable {
    public var node: NodeID
    public var services: [ServiceSpec]
    /// `logPath` is set only when the job's own log paths were overridden.
    public var adopted: [AdoptedItem]

    public init(node: NodeID, services: [ServiceSpec] = [], adopted: [AdoptedItem] = []) {
        self.node = node
        self.services = services
        self.adopted = adopted
    }
}

/// Response of `GET /v1/specs`.
public struct SpecList: Codable, Sendable, Equatable {
    public var nodes: [NodeSpecs]
    /// Down, or the call didn't get through.
    public var unreachableNodes: [String]
    /// Reached, but reading the specs failed there.
    public var failedNodes: [NodeFailure]

    public init(nodes: [NodeSpecs], unreachableNodes: [String] = [], failedNodes: [NodeFailure] = []) {
        self.nodes = nodes
        self.unreachableNodes = unreachableNodes
        self.failedNodes = failedNodes
    }

    /// Heads from before `failedNodes` don't send it.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        nodes = try container.decode([NodeSpecs].self, forKey: .nodes)
        unreachableNodes = try container.decode([String].self, forKey: .unreachableNodes)
        failedNodes = try container.decodeIfPresent([NodeFailure].self, forKey: .failedNodes) ?? []
    }

    /// Every service and adopted job, in a stable order, each with its node set.
    public func items(service: String? = nil, node: String? = nil) -> [ManifestItem] {
        var items: [ManifestItem] = []
        for specs in nodes.sorted(by: { $0.node.rawValue < $1.node.rawValue }) where node == nil || specs.node.rawValue == node {
            for var spec in specs.services.sorted(by: { $0.name < $1.name }) where service == nil || spec.name == service {
                spec.node = specs.node
                items.append(.service(spec))
            }
            for var job in specs.adopted.sorted(by: { $0.label < $1.label }) where service == nil || job.label == service {
                job.node = specs.node
                items.append(.adopted(job))
            }
        }
        return items
    }
}

/// Body of `POST /v1/apply`.
public struct ApplyRequest: Codable, Sendable, Equatable {
    public var items: [ManifestItem]
    /// Also removes services and adopted jobs that the file doesn't list, on the nodes the
    /// file names: each item's `node`, and the head (or the local node) for items without
    /// one. A file for one node can't empty another by mistake.
    public var prune: Bool
    /// Prunes every node that's up, including the ones the file doesn't name. Implies `prune`.
    public var pruneAll: Bool
    public var dryRun: Bool
    /// Of the file the items came from, for the audit log.
    public var sha256: String?

    public init(items: [ManifestItem], prune: Bool = false, pruneAll: Bool = false, dryRun: Bool = false, sha256: String? = nil) {
        self.items = items
        self.prune = prune
        self.pruneAll = pruneAll
        self.dryRun = dryRun
        self.sha256 = sha256
    }

    /// Clients from before `pruneAll` don't send it.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        items = try container.decode([ManifestItem].self, forKey: .items)
        prune = try container.decode(Bool.self, forKey: .prune)
        pruneAll = try container.decodeIfPresent(Bool.self, forKey: .pruneAll) ?? false
        dryRun = try container.decode(Bool.self, forKey: .dryRun)
        sha256 = try container.decodeIfPresent(String.self, forKey: .sha256)
    }

    /// Whether this node, asked with these items, prunes: a node the file doesn't name
    /// gets no items, and is pruned only with `pruneAll`.
    public var prunesHere: Bool { pruneAll || (prune && !items.isEmpty) }
}

public enum ManifestAction: String, Codable, Sendable {
    case create, update, unchanged, prune
}

/// One field that differs. Environment values are never shown, since they can be
/// literal credentials: only that a variable was added, removed or changed.
public struct FieldChange: Codable, Sendable, Equatable {
    public var field: String
    public var from: String?
    public var to: String?

    public init(field: String, from: String?, to: String?) {
        self.field = field
        self.from = from
        self.to = to
    }
}

public struct ManifestChange: Codable, Sendable, Equatable {
    public var action: ManifestAction
    public var kind: ManifestItemKind
    public var name: String
    public var node: NodeID
    /// Only for `update`.
    public var fields: [FieldChange]

    public init(action: ManifestAction, kind: ManifestItemKind, name: String, node: NodeID, fields: [FieldChange] = []) {
        self.action = action
        self.kind = kind
        self.name = name
        self.node = node
        self.fields = fields
    }
}

public struct ManifestDiff: Codable, Sendable, Equatable {
    public var changes: [ManifestChange]
    /// The nodes where what the file doesn't list is pruned. Empty without `--prune`.
    public var prunedNodes: [NodeID]

    public init(changes: [ManifestChange] = [], prunedNodes: [NodeID] = []) {
        self.changes = changes
        self.prunedNodes = prunedNodes
    }

    /// Nodes from before `prunedNodes` don't send it.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        changes = try container.decode([ManifestChange].self, forKey: .changes)
        prunedNodes = try container.decodeIfPresent([NodeID].self, forKey: .prunedNodes) ?? []
    }

    public var hasChanges: Bool { changes.contains { $0.action != .unchanged } }

    public func count(_ action: ManifestAction) -> Int { changes.filter { $0.action == action }.count }

    /// `1 to create, 2 to update, 3 unchanged, 0 to prune`.
    public var summary: String {
        "\(count(.create)) to create, \(count(.update)) to update, \(count(.unchanged)) unchanged, \(count(.prune)) to prune"
    }

    /// Compares the file with what the nodes in `current` run. Items without a node go
    /// to `defaultNode`. Pruning considers only the nodes in `current`.
    public static func compute(items: [ManifestItem], current: [NodeSpecs], defaultNode: NodeID, prune: Bool) -> ManifestDiff {
        var changes: [ManifestChange] = []
        var listed = Set<String>()
        let byNode = Dictionary(current.map { ($0.node, $0) }, uniquingKeysWith: { first, _ in first })
        for item in items {
            let node = item.node ?? defaultNode
            listed.insert("\(item.kind.rawValue)/\(item.name)@\(node)")
            let specs = byNode[node]
            switch item {
            case .service(let spec):
                guard let existing = specs?.services.first(where: { $0.name == spec.name }) else {
                    changes.append(ManifestChange(action: .create, kind: .service, name: spec.name, node: node))
                    continue
                }
                let fields = fieldChanges(from: existing, to: spec)
                changes.append(ManifestChange(action: fields.isEmpty ? .unchanged : .update, kind: .service,
                                              name: spec.name, node: node, fields: fields))
            case .adopted(let job):
                guard let existing = specs?.adopted.first(where: { $0.label == job.label }) else {
                    changes.append(ManifestChange(action: .create, kind: .adopted, name: job.label, node: node))
                    continue
                }
                let fields = existing.logPath == job.logPath
                    ? [] : [FieldChange(field: "log_path", from: existing.logPath, to: job.logPath)]
                changes.append(ManifestChange(action: fields.isEmpty ? .unchanged : .update, kind: .adopted,
                                              name: job.label, node: node, fields: fields))
            }
        }
        if prune {
            for specs in current {
                for spec in specs.services where !listed.contains("service/\(spec.name)@\(specs.node)") {
                    changes.append(ManifestChange(action: .prune, kind: .service, name: spec.name, node: specs.node))
                }
                for job in specs.adopted where !listed.contains("adopted/\(job.label)@\(specs.node)") {
                    changes.append(ManifestChange(action: .prune, kind: .adopted, name: job.label, node: specs.node))
                }
            }
        }
        return ManifestDiff(changes: changes, prunedNodes: prune ? current.map(\.node).sorted { $0.rawValue < $1.rawValue } : [])
    }

    /// Everything a service file can set. `node` is where the spec is, not a field, and
    /// `logPaths` isn't in the file format.
    public static func fieldChanges(from old: ServiceSpec, to new: ServiceSpec) -> [FieldChange] {
        var fields: [FieldChange] = []
        func add(_ field: String, _ from: String?, _ to: String?) {
            if from != to { fields.append(FieldChange(field: field, from: from, to: to)) }
        }
        let keepsRelease = if case .release = old.program { new.program.isNodeRelease } else { false }
        if !keepsRelease {
            add("program", describe(old.program, service: old.name), describe(new.program, service: new.name))
        }
        add("args", quoted(old.arguments), quoted(new.arguments))
        add("cwd", old.workingDirectory, new.workingDirectory)
        add("instances", String(old.instances), String(new.instances))
        add("user", old.user, new.user)
        for key in Set(old.environment.keys).union(new.environment.keys).sorted() {
            switch (old.environment[key], new.environment[key]) {
            case (nil, _?): fields.append(FieldChange(field: "env.\(key)", from: nil, to: "added"))
            case (_?, nil): fields.append(FieldChange(field: "env.\(key)", from: "removed", to: nil))
            case (let from?, let to?) where from != to: fields.append(FieldChange(field: "env.\(key)", from: "changed", to: "changed"))
            default: break
            }
        }
        for path in Set(old.secretFiles.keys).union(new.secretFiles.keys).sorted() {
            add("secret_files.\(path)", old.secretFiles[path], new.secretFiles[path])
        }
        return fields
    }

    private static func describe(_ program: ProgramSource, service: String) -> String {
        switch program {
        case .executable(let path): "exec \(path)"
        case .release(let sha12) where sha12.isEmpty: "binary \(service)"
        case .release(let sha12): "binary \(service) (release \(sha12))"
        }
    }

    private static func quoted(_ arguments: [String]) -> String {
        "[" + arguments.map { "\"\($0)\"" }.joined(separator: ", ") + "]"
    }
}

/// How one change went.
public struct ApplyItemResult: Codable, Sendable, Equatable {
    public var action: ManifestAction
    public var kind: ManifestItemKind
    public var name: String
    public var node: NodeID
    /// Nil when it worked.
    public var error: String?

    public init(action: ManifestAction, kind: ManifestItemKind, name: String, node: NodeID, error: String? = nil) {
        self.action = action
        self.kind = kind
        self.name = name
        self.node = node
        self.error = error
    }
}

/// A node that couldn't be asked. Nothing on it changed, and nothing elsewhere was undone.
public struct NodeFailure: Codable, Sendable, Equatable {
    public var node: NodeID
    public var error: String

    public init(node: NodeID, error: String) {
        self.node = node
        self.error = error
    }
}

/// Response of `POST /v1/apply`.
public struct ApplyResponse: Codable, Sendable, Equatable {
    public var diff: ManifestDiff
    /// One per create, update and prune. Empty on a dry run.
    public var results: [ApplyItemResult]
    public var failedNodes: [NodeFailure]
    public var dryRun: Bool

    public init(diff: ManifestDiff, results: [ApplyItemResult] = [], failedNodes: [NodeFailure] = [], dryRun: Bool) {
        self.diff = diff
        self.results = results
        self.failedNodes = failedNodes
        self.dryRun = dryRun
    }

    public var succeeded: Bool { failedNodes.isEmpty && results.allSatisfy { $0.error == nil } }
}
