import Foundation

/// One change made through the head: who, what, when, and how it went. Written by the
/// head's audit log for every call that isn't a read. Never holds a body, a token or a
/// secret's value.
public struct AuditRecord: Codable, Sendable, Equatable {
    public var time: Date
    /// The API token's name, `local-socket`, or `unauthenticated`.
    public var who: String
    public var method: String
    /// The path without its query string.
    public var path: String
    public var status: Int
    /// A handler's own summary, such as an apply's file hash and counts. Never values.
    public var detail: String?
    /// The `?node=` the call named, if any. Nil in records from before it was kept.
    public var node: String?

    public init(time: Date, who: String, method: String, path: String, status: Int, detail: String? = nil, node: String? = nil) {
        self.time = time
        self.who = who
        self.method = method
        self.path = path
        self.status = status
        self.detail = detail
        self.node = node
    }

    public var succeeded: Bool { (200..<300).contains(status) }

    /// What it did in a word or two, like `restart` or `set secret`, from its method and path.
    public var action: String { Self.describe(method: method, path: path).action }

    /// What it acted on, like `api` or `api/MONGO_PASSWORD`. Nil when nothing names it. A
    /// start or deploy names its service only in `detail`, as `service <name> …`.
    public var target: String? {
        if let target = Self.describe(method: method, path: path).target { return target }
        guard let detail, detail.hasPrefix("service ") else { return nil }
        return detail.dropFirst("service ".count).split(separator: " ").first.map(String.init)
    }

    static func describe(method: String, path: String) -> (action: String, target: String?) {
        let parts = path.split(separator: "/").map { String($0).removingPercentEncoding ?? String($0) }
        guard parts.first == "v1", parts.count >= 2 else { return ("\(method) \(path)", nil) }
        let rest = Array(parts.dropFirst())
        switch (method, rest.first!, rest.count) {
        case ("POST", "processes", 1): return ("start", nil)
        case ("POST", "processes", 3): return (rest[2], rest[1])
        case ("DELETE", "processes", 2): return ("delete", rest[1])
        case ("POST", "deploy", 1): return ("deploy", nil)
        case ("POST", "releases", 3) where rest[2] == "rollback": return ("rollback", rest[1])
        case ("PUT", "secrets", 3): return ("set secret", "\(rest[1])/\(rest[2])")
        case ("DELETE", "secrets", 3): return ("delete secret", "\(rest[1])/\(rest[2])")
        case ("POST", "apply", 1): return ("apply", nil)
        case ("POST", "adopt", 1): return ("adopt", nil)
        case ("DELETE", "adopt", 2): return ("abandon", rest[1])
        case ("POST", "gc", 1): return ("gc", nil)
        case ("POST", "tokens", 1): return ("create join token", nil)
        case ("POST", "nodes", 3) where rest[2] == "revoke": return ("revoke node", rest[1])
        case ("DELETE", "nodes", 2): return ("remove node", rest[1])
        case ("PUT", "nodes", 3) where rest[2] == "labels": return ("label node", rest[1])
        case ("POST", "api-tokens", 1): return ("create api token", nil)
        case ("DELETE", "api-tokens", 2): return ("revoke api token", rest[1])
        case ("PUT", "settings", 2): return ("set \(rest[1]) retention", nil)
        case ("POST", "credentials", 1): return ("set credentials", nil)
        case ("DELETE", "credentials", 1): return ("delete credentials", nil)
        default: return ("\(method) \(path)", nil)
        }
    }
}

/// `GET /v1/audit`: newest first.
public struct AuditList: Codable, Sendable, Equatable {
    public var records: [AuditRecord]
    /// More records matched than `limit` allowed.
    public var truncated: Bool
    /// Of the records returned, how many failed, so a caller sees trouble before reading them.
    public var failures: Int

    public init(records: [AuditRecord], truncated: Bool = false) {
        self.records = records
        self.truncated = truncated
        failures = records.filter { !$0.succeeded }.count
    }
}

/// Which audit records to return. Every filter is optional.
public struct AuditQuery: Sendable, Equatable {
    public static let defaultLimit = 100
    public static let maxLimit = 1000

    public var since: Date?
    public var until: Date?
    public var limit: Int
    /// A token name, exactly.
    public var who: String?
    /// Matches the target, the node or the detail, case-insensitively: a service, a secret, a node.
    public var about: String?
    public var failedOnly: Bool

    public init(since: Date? = nil, until: Date? = nil, limit: Int = AuditQuery.defaultLimit, who: String? = nil,
                about: String? = nil, failedOnly: Bool = false) {
        self.since = since
        self.until = until
        self.limit = min(max(limit, 1), Self.maxLimit)
        self.who = who
        self.about = about
        self.failedOnly = failedOnly
    }

    public func matches(_ record: AuditRecord) -> Bool {
        if let since, record.time < since { return false }
        if let until, record.time > until { return false }
        if let who, record.who != who { return false }
        if failedOnly, record.succeeded { return false }
        if let about {
            let needle = about.lowercased()
            let haystacks = [record.target, record.node, record.detail].compactMap { $0?.lowercased() }
            if !haystacks.contains(where: { $0.contains(needle) }) { return false }
        }
        return true
    }
}
