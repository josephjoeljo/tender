import Foundation

/// A service's own secret, or one any service on the node can use.
public enum SecretScope: String, Codable, Sendable {
    case service, shared
}

/// A stored secret: `api/MONGO_PASSWORD` or `shared/JWT_KEY`. No service may be named
/// `shared`, since its secrets' paths would mean the shared scope.
public struct SecretName: Hashable, Codable, Sendable, CustomStringConvertible {
    public var scope: SecretScope
    /// Nil for the shared scope.
    public var service: String?
    public var name: String

    public init(service: String, name: String) {
        scope = .service
        self.service = service
        self.name = name
    }

    public init(shared name: String) {
        scope = .shared
        service = nil
        self.name = name
    }

    /// Parses `<service>/<NAME>` or `shared/<NAME>`.
    public init?(path: String) {
        let parts = path.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        guard parts.count == 2, Self.isValidName(parts[1]) else { return nil }
        if parts[0] == "shared" {
            self.init(shared: parts[1])
        } else {
            guard ServiceSpec.isValidName(parts[0]) else { return nil }
            self.init(service: parts[0], name: parts[1])
        }
    }

    /// Parses a `SecretStore` item name, the inverse of `itemName`.
    public init?(itemName: String) {
        let parts = itemName.split(separator: ".", omittingEmptySubsequences: false).map(String.init)
        if parts.count == 2, parts[0] == "shared", Self.isValidName(parts[1]) {
            self.init(shared: parts[1])
        } else if parts.count == 3, parts[0] == "svc", ServiceSpec.isValidName(parts[1]), Self.isValidName(parts[2]) {
            self.init(service: parts[1], name: parts[2])
        } else {
            return nil
        }
    }

    public var description: String { "\(service ?? "shared")/\(name)" }

    /// The key in the node's `SecretStore`. Service names and secret names have no
    /// dots, so these can't collide with each other or with the cluster's own items.
    public var itemName: String {
        if let service { "svc.\(service).\(name)" } else { "shared.\(name)" }
    }

    /// Environment-variable style, so that a name can be used as one: letters, digits
    /// and `_`, not starting with a digit, up to 128 characters.
    public static func isValidName(_ name: String) -> Bool {
        guard let first = name.unicodeScalars.first, name.count <= 128, !("0"..."9").contains(first) else { return false }
        return name.unicodeScalars.allSatisfy {
            switch $0 {
            case "a"..."z", "A"..."Z", "0"..."9", "_": true
            default: false
            }
        }
    }
}

/// `${secret:NAME}` or `${secret:shared/NAME}` inside an environment value or argument,
/// `${secret:gcp:…}` for a secret in GCP Secret Manager through the node's default
/// source, or `${secret:<source>:…}` through one of its named sources.
public struct SecretRef: Hashable, Codable, Sendable, CustomStringConvertible {
    public var shared: Bool
    /// The secret's name, or a GCP reference's secret ID.
    public var name: String
    public var gcp: GCPSecretRef?

    public init(name: String, shared: Bool = false) {
        self.name = name
        self.shared = shared
    }

    public init(gcp: GCPSecretRef) {
        name = gcp.secret
        shared = false
        self.gcp = gcp
    }

    /// Parses what goes between `${secret:` and `}`, which is also what `secret_files` holds.
    /// A local name has no `:`, so anything before one names the source.
    public init?(parsing body: String) {
        if let colon = body.firstIndex(of: ":") {
            let prefix = String(body[..<colon])
            let source: String? = prefix == SecretSources.defaultName ? nil : prefix
            guard source.map(SecretSources.isValidName) ?? true,
                  var gcp = GCPSecretRef(parsing: String(body[body.index(after: colon)...])) else { return nil }
            gcp.source = source
            self.init(gcp: gcp)
            return
        }
        if body.hasPrefix("shared/") {
            self.init(name: String(body.dropFirst("shared/".count)), shared: true)
        } else {
            self.init(name: body)
        }
        guard SecretName.isValidName(name) else { return nil }
    }

    /// What goes between `${secret:` and `}`, and the key of its value in `secrets.json`.
    public var description: String {
        if let gcp { return "\(gcp.source ?? SecretSources.defaultName):\(gcp)" }
        return shared ? "shared/\(name)" : name
    }

    /// The node-local secret it names. Nil for a GCP reference.
    public func secretName(service: String) -> SecretName? {
        guard gcp == nil else { return nil }
        return shared ? SecretName(shared: name) : SecretName(service: service, name: name)
    }

    /// The key of its value in the node's `SecretStore`. Nil for a GCP reference without a
    /// project on a node without a default one.
    public func itemName(service: String, defaultProject: String?) -> String? {
        itemName(service: service, sources: SecretSources(defaultProject: defaultProject))
    }

    /// Nil for a GCP reference `sources` can't resolve for `service`: an unknown source,
    /// one that doesn't allow the service, or no project.
    public func itemName(service: String, sources: SecretSources) -> String? {
        if let gcp { return try? sources.resolve(gcp, service: service).get().itemName }
        return secretName(service: service)?.itemName
    }
}

/// `gcp:NAME`, `gcp:NAME@4`, `gcp:projects/P/secrets/S` or `gcp:projects/P/secrets/S@4`.
/// Without a version it means `latest`, which the node re-checks; a number is pinned.
public struct GCPSecretRef: Hashable, Codable, Sendable, CustomStringConvertible {
    /// The named source it's fetched through, `billing` in `${secret:billing:…}`. Nil for
    /// the default one, `gcp:`.
    public var source: String?
    /// Nil for the source's default project: `secrets.project`, or the named source's
    /// `project`, in `cloud.json`.
    public var project: String?
    public var secret: String
    /// Nil for `latest`.
    public var version: String?

    public init(source: String? = nil, project: String? = nil, secret: String, version: String? = nil) {
        self.source = source
        self.project = project
        self.secret = secret
        self.version = version
    }

    public init?(parsing text: String) {
        var path = Substring(text)
        var version: String?
        if let at = path.lastIndex(of: "@") {
            let raw = String(path[path.index(after: at)...])
            path = path[..<at]
            guard raw == "latest" || Self.isValidVersion(raw) else { return nil }
            version = raw == "latest" ? nil : raw
        }
        let parts = path.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        if parts.count == 4, parts[0] == "projects", parts[2] == "secrets", Self.isValidProject(parts[1]) {
            self.init(project: parts[1], secret: parts[3], version: version)
        } else if parts.count == 1 {
            self.init(secret: parts[0], version: version)
        } else {
            return nil
        }
        guard Self.isValidSecret(secret) else { return nil }
    }

    /// As written after the source, except that `@latest` is left out.
    public var description: String {
        (project.map { "projects/\($0)/secrets/" } ?? "") + secret + (version.map { "@\($0)" } ?? "")
    }

    public func resolved(defaultProject: String?) -> GCPSecretVersion? {
        guard let project = project ?? defaultProject, Self.isValidProject(project) else { return nil }
        return GCPSecretVersion(source: source, project: project, secret: secret, version: version ?? "latest")
    }

    /// Project IDs, or project numbers: lowercase letters, digits and `-`.
    public static func isValidProject(_ project: String) -> Bool {
        guard (1...30).contains(project.count), project.first != "-", project.last != "-" else { return false }
        return project.unicodeScalars.allSatisfy {
            switch $0 {
            case "a"..."z", "0"..."9", "-": true
            default: false
            }
        }
    }

    public static func isValidSecret(_ secret: String) -> Bool {
        guard (1...255).contains(secret.count) else { return false }
        return secret.unicodeScalars.allSatisfy {
            switch $0 {
            case "a"..."z", "A"..."Z", "0"..."9", "_", "-": true
            default: false
            }
        }
    }

    public static func isValidVersion(_ version: String) -> Bool {
        (1...18).contains(version.count) && version.first != "0" && version.unicodeScalars.allSatisfy { ("0"..."9").contains($0) }
    }
}

/// A GCP reference with its project filled in: what a node fetches and caches.
public struct GCPSecretVersion: Hashable, Sendable, CustomStringConvertible {
    /// Nil for the default source.
    public var source: String?
    public var project: String
    public var secret: String
    /// `latest` or a version number.
    public var version: String

    public init(source: String? = nil, project: String, secret: String, version: String) {
        self.source = source
        self.project = project
        self.secret = secret
        self.version = version
    }

    public var isLatest: Bool { version == "latest" }

    /// Its cache key in the node's `SecretStore`. Source names, project IDs, secret IDs and
    /// versions have no dots, so these can't collide with each other or with
    /// `SecretName.itemName`. Each source has its own copy, so a service a source doesn't
    /// allow never reads a value fetched through it.
    public var itemName: String {
        let path = "\(project).\(secret).\(version)"
        return source.map { "gcpsrc.\($0).\(path)" } ?? "gcp.\(path)"
    }

    public init?(itemName: String) {
        var parts = itemName.split(separator: ".", omittingEmptySubsequences: false).map(String.init)
        var source: String?
        if parts.count == 5, parts[0] == "gcpsrc", SecretSources.isValidName(parts[1]) {
            source = parts[1]
            parts.removeFirst(2)
        } else if parts.count == 4, parts[0] == "gcp" {
            parts.removeFirst()
        } else {
            return nil
        }
        guard GCPSecretRef.isValidProject(parts[0]), GCPSecretRef.isValidSecret(parts[1]),
              parts[2] == "latest" || GCPSecretRef.isValidVersion(parts[2]) else { return nil }
        self.init(source: source, project: parts[0], secret: parts[1], version: parts[2])
    }

    /// `projects/P/secrets/S@V`, after `<source>:` for a named source.
    public var description: String {
        (source.map { "\($0):" } ?? "") + "projects/\(project)/secrets/\(secret)@\(version)"
    }
}

public enum SecretTemplateError: Error, Equatable, CustomStringConvertible {
    case malformed(String)
    case missing(SecretRef)

    public var description: String {
        switch self {
        case .malformed(let text):
            "'\(text)' isn't a valid secret reference. Use ${secret:NAME}, ${secret:shared/NAME}, ${secret:gcp:NAME[@VERSION]}, ${secret:gcp:projects/P/secrets/S[@VERSION]}, or a named source in place of gcp, as in ${secret:billing:NAME}."
        case .missing(let ref) where ref.gcp != nil:
            "The secret \(ref) hasn't been fetched from GCP Secret Manager on this node. `tender secret list` says why."
        case .missing(let ref):
            "The secret \(ref) isn't set on this node."
        }
    }
}

/// Templates are stored as written; only `tenderd exec` ever sees resolved values.
/// `$${` stands for a literal `${`. Any other `${…}` is left alone.
public enum SecretTemplate {
    private static let opener = "${secret:"

    /// True if `text` needs `tenderd exec` to turn it into what the process sees.
    public static func needsProcessing(_ text: String) -> Bool {
        text.contains(opener) || text.contains("$${")
    }

    public static func references(in text: String) throws -> [SecretRef] {
        var refs: [SecretRef] = []
        _ = try render(text) { ref in
            refs.append(ref)
            return ""
        }
        return refs
    }

    /// Replaces each reference with `lookup`'s value. A nil value throws `missing`.
    public static func render(_ text: String, lookup: (SecretRef) throws -> String?) throws -> String {
        var output = ""
        var rest = Substring(text)
        while let dollar = rest.firstIndex(of: "$") {
            output += rest[..<dollar]
            rest = rest[dollar...]
            if rest.hasPrefix("$${") {
                output += "${"
                rest = rest.dropFirst(3)
            } else if rest.hasPrefix(opener) {
                guard let close = rest.firstIndex(of: "}") else { throw SecretTemplateError.malformed(String(rest)) }
                let body = String(rest[rest.index(rest.startIndex, offsetBy: opener.count)..<close])
                guard let ref = SecretRef(parsing: body) else { throw SecretTemplateError.malformed(String(rest[...close])) }
                guard let value = try lookup(ref) else { throw SecretTemplateError.missing(ref) }
                output += value
                rest = rest[rest.index(after: close)...]
            } else {
                output += "$"
                rest = rest.dropFirst()
            }
        }
        return output + rest
    }
}

extension ServiceSpec {
    /// True if the process must start through `tenderd exec`.
    public var usesSecretTemplates: Bool {
        !secretFiles.isEmpty
            || environment.values.contains(where: SecretTemplate.needsProcessing)
            || arguments.contains(where: SecretTemplate.needsProcessing)
    }

    /// Every distinct reference in the environment, arguments and secret files, sorted.
    public func secretRefs() throws -> [SecretRef] {
        var refs = Set<SecretRef>()
        for text in environment.values.sorted() + arguments {
            refs.formUnion(try SecretTemplate.references(in: text))
        }
        refs.formUnion(try parsedSecretFiles().map(\.ref))
        return refs.sorted { $0.description < $1.description }
    }

    /// `secretFiles` with each reference parsed, sorted by path.
    public func parsedSecretFiles() throws -> [(path: String, ref: SecretRef)] {
        try secretFiles.sorted { $0.key < $1.key }.map { path, text in
            guard let ref = SecretRef(parsing: text) else { throw SecretTemplateError.malformed(text) }
            return (path, ref)
        }
    }

    public static let maxSecretFiles = 32

    /// An absolute path with nothing to normalize away: no `.`, `..` or empty components,
    /// and no trailing `/`. Whether it's somewhere Tender may write is the node's call.
    public static func isValidSecretFilePath(_ path: String) -> Bool {
        guard path.hasPrefix("/"), path.count > 1, path.utf8.count <= 1024, !path.hasSuffix("/") else { return false }
        return path.dropFirst().split(separator: "/", omittingEmptySubsequences: false).allSatisfy {
            !$0.isEmpty && $0 != "." && $0 != ".." && !$0.unicodeScalars.contains { $0.value < 0x20 || $0.value == 0x7f }
        }
    }
}

/// What a node knows about one secret. Never carries the value.
public struct SecretInfo: Codable, Sendable, Equatable {
    /// `api/MONGO_PASSWORD` or `shared/JWT_KEY`.
    public var name: String
    public var scope: SecretScope
    public var node: NodeID
    public var updatedAt: Date
    /// Goes up every time the secret changes on this node.
    public var revision: Int
    /// Services on this node that reference it.
    public var usedBy: [String]

    public init(name: String, scope: SecretScope, node: NodeID, updatedAt: Date, revision: Int, usedBy: [String]) {
        self.name = name
        self.scope = scope
        self.node = node
        self.updatedAt = updatedAt
        self.revision = revision
        self.usedBy = usedBy
    }
}

/// A GCP Secret Manager reference as a node sees it. Never carries the value.
public struct GCPSecretInfo: Codable, Sendable, Equatable {
    /// `projects/P/secrets/S@latest` or `…@4`.
    public var name: String
    public var node: NodeID
    /// The version the cached value is, once this daemon has fetched it.
    public var version: String?
    /// Whether the node holds a value, which instances start from.
    public var cached: Bool
    /// When the cached value last changed.
    public var updatedAt: Date?
    /// The last successful fetch since the daemon started.
    public var checkedAt: Date?
    /// Goes up every time the cached value changes.
    public var revision: Int
    public var usedBy: [String]
    /// Why the last fetch failed. Never includes the value.
    public var fetchError: String?
    /// Cached, but the last attempt to refresh it failed: instances start from the cache.
    public var stale: Bool

    public init(name: String, node: NodeID, version: String? = nil, cached: Bool, updatedAt: Date? = nil,
                checkedAt: Date? = nil, revision: Int = 0, usedBy: [String] = [], fetchError: String? = nil) {
        self.name = name
        self.node = node
        self.version = version
        self.cached = cached
        self.updatedAt = updatedAt
        self.checkedAt = checkedAt
        self.revision = revision
        self.usedBy = usedBy
        self.fetchError = fetchError
        stale = cached && fetchError != nil
    }
}

public struct SecretList: Codable, Sendable, Equatable {
    public var secrets: [SecretInfo]
    /// References that no secret on the node satisfies, as `service: NAME`.
    public var missing: [String]
    public var unreachableNodes: [String]
    /// GCP Secret Manager references in use on the node.
    public var gcp: [GCPSecretInfo]

    public init(secrets: [SecretInfo], missing: [String] = [], unreachableNodes: [String] = [], gcp: [GCPSecretInfo] = []) {
        self.secrets = secrets
        self.missing = missing
        self.unreachableNodes = unreachableNodes
        self.gcp = gcp
    }

    /// Lists from before GCP references still decode.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            secrets: try container.decode([SecretInfo].self, forKey: .secrets),
            missing: try container.decode([String].self, forKey: .missing),
            unreachableNodes: try container.decode([String].self, forKey: .unreachableNodes),
            gcp: try container.decodeIfPresent([GCPSecretInfo].self, forKey: .gcp) ?? []
        )
    }
}

/// Body of `PUT /v1/secrets/{scope}/{name}`. `value` is base64 in JSON.
public struct SecretSetRequest: Codable, Sendable {
    public static let maxValueSize = 64 << 10
    public var value: Data

    public init(value: Data) { self.value = value }
}
