import Foundation

/// Labels people put on a node: free-form `key=value` pairs for grouping and, later,
/// placement. `name` is the node's display name. The node keeps them, in its own config,
/// and reports them when it registers, so they survive losing the head.
public enum NodeLabels {
    /// The display name, shown in place of the hostname.
    public static let nameKey = "name"
    /// Keys Tender sets itself, which nobody can change.
    public static let reservedKeys: Set<String> = [NodeInfo.roleLabel]
    public static let maxCount = 32

    /// Lowercase letters, digits, `.`, `_`, `-` and `/`, starting with a letter or digit, up
    /// to 63 characters.
    public static func isValidKey(_ key: String) -> Bool {
        guard (1...63).contains(key.count), let first = key.unicodeScalars.first,
              ("a"..."z").contains(first) || ("0"..."9").contains(first) else { return false }
        return key.unicodeScalars.allSatisfy {
            switch $0 {
            case "a"..."z", "0"..."9", ".", "_", "-", "/": true
            default: false
            }
        }
    }

    /// Printable text without line breaks, 1 to 128 characters.
    public static func isValidValue(_ value: String) -> Bool {
        (1...128).contains(value.count) && !value.unicodeScalars.contains { $0.value < 0x20 || $0.value == 0x7f }
            && value.trimmingCharacters(in: .whitespaces) == value
    }

    /// Why `update` can't apply to `current`, or nil.
    public static func problem(with update: NodeLabelsUpdate, current: [String: String]) -> String? {
        for key in Set(update.set.keys).union(update.remove) {
            if reservedKeys.contains(key) { return "'\(key)' is set by Tender and can't be changed." }
            if !isValidKey(key) {
                return "'\(key)' isn't a label key: lowercase letters, digits, '.', '_', '-' and '/', starting with a letter or digit, up to 63."
            }
        }
        for (key, value) in update.set where !isValidValue(value) {
            return "The value of '\(key)' must be 1 to 128 printable characters on one line, without leading or trailing spaces."
        }
        if let both = update.remove.first(where: { update.set[$0] != nil }) { return "'\(both)' is both set and removed." }
        if update.applied(to: current).count > maxCount { return "A node can have at most \(maxCount) labels." }
        return nil
    }
}

/// `PUT /v1/nodes/{id}/labels`: labels to set or replace, and keys to remove.
public struct NodeLabelsUpdate: Codable, Sendable, Equatable {
    public var set: [String: String]
    public var remove: [String]

    public init(set: [String: String] = [:], remove: [String] = []) {
        self.set = set
        self.remove = remove
    }

    public func applied(to labels: [String: String]) -> [String: String] {
        var result = labels
        for key in remove { result[key] = nil }
        result.merge(set) { _, new in new }
        return result
    }
}
