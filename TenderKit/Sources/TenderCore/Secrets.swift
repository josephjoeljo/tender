import Foundation

/// A service's own secret, or one any service on the node can use.
public enum SecretScope: String, Codable, Sendable {
    case service, shared
}

/// A stored secret: `api/MONGO_PASSWORD` or `shared/JWT_KEY`. A service named
/// `shared` can't have service-scoped secrets, since its path would mean the shared scope.
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

/// `${secret:NAME}` or `${secret:shared/NAME}` inside an environment value or argument.
public struct SecretRef: Hashable, Codable, Sendable, CustomStringConvertible {
    public var shared: Bool
    public var name: String

    public init(name: String, shared: Bool = false) {
        self.name = name
        self.shared = shared
    }

    /// What goes between `${secret:` and `}`.
    public var description: String { shared ? "shared/\(name)" : name }

    public func secretName(service: String) -> SecretName {
        shared ? SecretName(shared: name) : SecretName(service: service, name: name)
    }
}

public enum SecretTemplateError: Error, Equatable, CustomStringConvertible {
    case malformed(String)
    case missing(SecretRef)

    public var description: String {
        switch self {
        case .malformed(let text): "'\(text)' isn't a valid secret reference. Use ${secret:NAME} or ${secret:shared/NAME}."
        case .missing(let ref): "The secret \(ref) isn't set on this node."
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
                let ref: SecretRef
                if body.hasPrefix("shared/") {
                    ref = SecretRef(name: String(body.dropFirst("shared/".count)), shared: true)
                } else {
                    ref = SecretRef(name: body)
                }
                guard SecretName.isValidName(ref.name) else {
                    throw SecretTemplateError.malformed(String(rest[...close]))
                }
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
        environment.values.contains(where: SecretTemplate.needsProcessing)
            || arguments.contains(where: SecretTemplate.needsProcessing)
    }

    /// Every distinct reference in the environment and arguments, sorted.
    public func secretRefs() throws -> [SecretRef] {
        var refs = Set<SecretRef>()
        for text in environment.values.sorted() + arguments {
            refs.formUnion(try SecretTemplate.references(in: text))
        }
        return refs.sorted { $0.description < $1.description }
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

public struct SecretList: Codable, Sendable, Equatable {
    public var secrets: [SecretInfo]
    /// References that no secret on the node satisfies, as `service: NAME`.
    public var missing: [String]
    public var unreachableNodes: [String]

    public init(secrets: [SecretInfo], missing: [String] = [], unreachableNodes: [String] = []) {
        self.secrets = secrets
        self.missing = missing
        self.unreachableNodes = unreachableNodes
    }
}

/// Body of `PUT /v1/secrets/{scope}/{name}`. `value` is base64 in JSON.
public struct SecretSetRequest: Codable, Sendable {
    public static let maxValueSize = 64 << 10
    public var value: Data

    public init(value: Data) { self.value = value }
}
