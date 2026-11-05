import CryptoKit
import Foundation
import TenderCore
import Yams

/// A service file (`services.yaml`): YAML documents of `kind: Service` or `kind: Adopted`.
/// Parsed here, on the CLI side, so that the daemons never parse YAML and the node only
/// ever sees final specs with `env_file` already merged in.
public enum ServiceFile {
    static let serviceKeys: Set<String> = ["kind", "name", "binary", "exec", "args", "cwd", "instances", "node",
                                           "env_file", "env", "secret_files", "user"]
    static let adoptedKeys: Set<String> = ["kind", "label", "node", "log_path"]
    /// Milestone 5c's keys. Rejected rather than ignored, so that a file written for a
    /// later Tender doesn't silently run without its health checks.
    static let laterKeys: Set<String> = ["health", "rollout", "replicas", "placement"]

    public struct Loaded: Sendable {
        public var manifest: Manifest
        /// Of the file's bytes, for the audit log.
        public var sha256: String
    }

    public static func load(_ url: URL) throws -> Loaded {
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            throw ManifestError("Can't read \(url.path(percentEncoded: false)): \(error.localizedDescription)")
        }
        let manifest = try parse(String(decoding: data, as: UTF8.self), file: url.lastPathComponent,
                                 directory: url.deletingLastPathComponent())
        let sha256 = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        return Loaded(manifest: manifest, sha256: sha256)
    }

    /// `env_file` paths are relative to `directory`, the file's own.
    public static func parse(_ yaml: String, file: String = "services.yaml", directory: URL? = nil) throws -> Manifest {
        var documents = try Yams.compose_all(yaml: yaml)
        var items: [ManifestItem] = []
        var index = 0
        while let node = documents.next() {
            index += 1
            var document = Document(file: file, index: index, directory: directory)
            if case .scalar(let scalar) = node, isNull(scalar) { continue }
            items.append(try document.item(node))
        }
        if let error = documents.error { throw ManifestError("\(file): \(error)") }
        let manifest = Manifest(items: items)
        try manifest.validate()
        return manifest
    }

    static func isNull(_ scalar: Node.Scalar) -> Bool {
        scalar.style == .plain && ["", "~", "null", "Null", "NULL"].contains(scalar.string)
    }

    /// One document, for error messages that say where.
    struct Document {
        var file: String
        var index: Int
        var directory: URL?
        var name: String?

        func fail(_ message: String, at node: Node? = nil) -> ManifestError {
            var place = "\(file), document \(index)"
            if let name { place += " (\(name))" }
            if let line = node?.mark?.line { place += ", line \(line)" }
            return ManifestError("\(place): \(message)")
        }

        mutating func item(_ node: Node) throws -> ManifestItem {
            guard let mapping = node.mapping else { throw fail("expected a mapping of keys to values.", at: node) }
            var values: [String: Node] = [:]
            var keys: [String: Node] = [:]
            for (keyNode, value) in mapping {
                guard let key = keyNode.scalar?.string else { throw fail("keys must be plain strings.", at: keyNode) }
                guard values.updateValue(value, forKey: key) == nil else { throw fail("'\(key)' appears twice.", at: keyNode) }
                keys[key] = keyNode
            }
            name = values["name"]?.scalar?.string ?? values["label"]?.scalar?.string
            guard let kind = values["kind"] else { throw fail("missing 'kind' (Service or Adopted).", at: node) }
            switch try string(kind, "kind") {
            case "Service":
                try checkKeys(keys, allowed: serviceKeys)
                return .service(try service(values, at: node))
            case "Adopted":
                try checkKeys(keys, allowed: adoptedKeys)
                return .adopted(try adopted(values, at: node))
            case let other:
                throw fail("unknown kind '\(other)'. Use Service or Adopted.", at: kind)
            }
        }

        func checkKeys(_ keys: [String: Node], allowed: Set<String>) throws {
            for (key, node) in keys.sorted(by: { $0.key < $1.key }) where !allowed.contains(key) {
                if laterKeys.contains(key) { throw fail("'\(key)' is not supported yet.", at: node) }
                throw fail("unknown key '\(key)'. Valid keys: \(allowed.sorted().joined(separator: ", ")).", at: node)
            }
        }

        func service(_ values: [String: Node], at node: Node) throws -> ServiceSpec {
            guard let nameNode = values["name"] else { throw fail("missing 'name'.", at: node) }
            let name = try string(nameNode, "name")
            let program: ProgramSource
            switch (values["binary"], values["exec"]) {
            case (let binary?, nil):
                // Releases are per service: `releases/<name>/` from `bin/<name>/`.
                guard try string(binary, "binary") == name else {
                    throw fail("binary must be the service's own name ('\(name)'): releases come from bin/\(name)/.", at: binary)
                }
                program = .nodeRelease
            case (nil, let exec?):
                program = .executable(try string(exec, "exec"))
            case (nil, nil):
                throw fail("needs 'binary' (a release from bin/\(name)/) or 'exec' (an absolute path).", at: node)
            case (_?, _?):
                throw fail("has both 'binary' and 'exec'; pick one.", at: node)
            }
            var environment: [String: String] = [:]
            if let envFile = values["env_file"] {
                environment = try readEnvFile(try string(envFile, "env_file"), at: envFile)
            }
            // Inline values win over the env_file's.
            if let env = values["env"] {
                environment.merge(try stringMap(env, "env"), uniquingKeysWith: { _, inline in inline })
            }
            var spec = ServiceSpec(
                name: name,
                program: program,
                arguments: try values["args"].map { try stringList($0, "args") } ?? [],
                environment: environment,
                workingDirectory: try values["cwd"].map { try string($0, "cwd") },
                instances: try values["instances"].map { try int($0, "instances") } ?? 1,
                node: try values["node"].map { NodeID(try string($0, "node")) },
                secretFiles: try values["secret_files"].map { try stringMap($0, "secret_files") } ?? [:]
            )
            if let user = values["user"] { spec.user = try string(user, "user") }
            return spec
        }

        func adopted(_ values: [String: Node], at node: Node) throws -> AdoptedItem {
            guard let label = values["label"] else { throw fail("missing 'label'.", at: node) }
            return AdoptedItem(label: try string(label, "label"),
                               node: try values["node"].map { NodeID(try string($0, "node")) },
                               logPath: try values["log_path"].map { try string($0, "log_path") })
        }

        func readEnvFile(_ path: String, at node: Node) throws -> [String: String] {
            let url = URL(filePath: path, relativeTo: directory ?? URL(filePath: FileManager.default.currentDirectoryPath))
            let text: String
            do {
                text = try String(contentsOf: url, encoding: .utf8)
            } catch {
                throw fail("can't read env_file '\(path)': \(error.localizedDescription)", at: node)
            }
            do {
                return try DotEnv.parse(text)
            } catch let error as ManifestError {
                throw fail("env_file '\(path)', \(error.message)", at: node)
            }
        }

        func string(_ node: Node, _ key: String) throws -> String {
            guard let scalar = node.scalar, !isNull(scalar) else { throw fail("'\(key)' must be a string.", at: node) }
            return scalar.string
        }

        func int(_ node: Node, _ key: String) throws -> Int {
            guard let value = Int(try string(node, key)) else { throw fail("'\(key)' must be a whole number.", at: node) }
            return value
        }

        /// Scalars as written, so `8080` and `"8080"` are the same argument.
        func stringList(_ node: Node, _ key: String) throws -> [String] {
            guard let sequence = node.sequence else { throw fail("'\(key)' must be a list.", at: node) }
            return try sequence.map { try string($0, key) }
        }

        func stringMap(_ node: Node, _ key: String) throws -> [String: String] {
            guard let mapping = node.mapping else { throw fail("'\(key)' must be a mapping.", at: node) }
            var result: [String: String] = [:]
            for (name, value) in mapping {
                let name = try string(name, key)
                guard result.updateValue(try string(value, "\(key).\(name)"), forKey: name) == nil else {
                    throw fail("'\(key).\(name)' appears twice.", at: value)
                }
            }
            return result
        }
    }

    // MARK: Export

    /// YAML that applies as a no-op: every item names its node, secrets stay as the
    /// `${secret:…}` templates the spec stores, and `binary:` keeps the node's release.
    public static func render(_ items: [ManifestItem]) throws -> String {
        let documents = items.map { item -> Node in
            var pairs: [(Node, Node)] = []
            func add(_ key: String, _ value: Node) { pairs.append((Node(key), value)) }
            // Values a YAML reader would otherwise take for numbers or booleans stay strings.
            func quoted(_ text: String) -> Node { Node(text, .implicit, .doubleQuoted) }
            switch item {
            case .service(let spec):
                add("kind", "Service")
                add("name", Node(spec.name))
                switch spec.program {
                case .executable(let path): add("exec", Node(path))
                case .release: add("binary", Node(spec.name))
                }
                if !spec.arguments.isEmpty { add("args", Node(spec.arguments.map(quoted), .implicit, .flow)) }
                if let cwd = spec.workingDirectory { add("cwd", Node(cwd)) }
                if spec.instances != 1 { add("instances", Node(String(spec.instances))) }
                if let node = spec.node { add("node", Node(node.rawValue)) }
                if !spec.environment.isEmpty {
                    add("env", Node(spec.environment.sorted { $0.key < $1.key }.map { (Node($0.key), quoted($0.value)) }))
                }
                if !spec.secretFiles.isEmpty {
                    add("secret_files", Node(spec.secretFiles.sorted { $0.key < $1.key }.map { (Node($0.key), Node($0.value)) }))
                }
                if spec.user != ServiceSpec.defaultUser { add("user", Node(spec.user)) }
            case .adopted(let job):
                add("kind", "Adopted")
                add("label", Node(job.label))
                if let node = job.node { add("node", Node(node.rawValue)) }
                if let path = job.logPath { add("log_path", Node(path)) }
            }
            return Node(pairs)
        }
        guard !documents.isEmpty else { return "" }
        return try Yams.serialize(nodes: documents, width: -1, allowUnicode: true, explicitStart: true)
    }
}

/// `.env` syntax: `KEY=value`, blank lines and `#` comments, an optional `export `,
/// and single quotes (literal) or double quotes (with `\n`, `\t`, `\"` and `\\`).
/// Unquoted values end at ` #`, and are trimmed.
public enum DotEnv {
    public static func parse(_ text: String) throws -> [String: String] {
        var result: [String: String] = [:]
        for (number, raw) in text.split(separator: "\n", omittingEmptySubsequences: false).enumerated() {
            var line = raw.hasSuffix("\r") ? raw.dropLast() : raw
            line = line.drop { $0 == " " || $0 == "\t" }
            if line.isEmpty || line.hasPrefix("#") { continue }
            if line.hasPrefix("export ") { line = line.dropFirst("export ".count).drop { $0 == " " } }
            guard let equals = line.firstIndex(of: "=") else {
                throw ManifestError("line \(number + 1): expected KEY=value.")
            }
            let key = String(line[..<equals]).trimmingCharacters(in: .whitespaces)
            guard SecretName.isValidName(key) else {
                throw ManifestError("line \(number + 1): '\(key)' isn't a valid variable name.")
            }
            result[key] = try value(line[line.index(after: equals)...].drop { $0 == " " || $0 == "\t" }, line: number + 1)
        }
        return result
    }

    private static func value(_ text: Substring, line: Int) throws -> String {
        guard let quote = text.first, quote == "\"" || quote == "'" else {
            var value = text
            if let comment = value.range(of: " #") ?? value.range(of: "\t#") { value = value[..<comment.lowerBound] }
            return value.trimmingCharacters(in: .whitespaces)
        }
        var output = ""
        var rest = text.dropFirst()
        while let character = rest.first {
            rest = rest.dropFirst()
            if character == quote {
                let after = rest.trimmingCharacters(in: .whitespaces)
                guard after.isEmpty || after.hasPrefix("#") else {
                    throw ManifestError("line \(line): unexpected text after the closing quote.")
                }
                return output
            }
            if quote == "\"", character == "\\", let next = rest.first {
                rest = rest.dropFirst()
                switch next {
                case "n": output.append("\n")
                case "t": output.append("\t")
                case "r": output.append("\r")
                default: output.append(next)
                }
            } else {
                output.append(character)
            }
        }
        throw ManifestError("line \(line): unterminated \(quote) quote.")
    }
}

/// The text form of a diff, for `tender apply`.
public enum ManifestDiffRenderer {
    public static func render(_ diff: ManifestDiff) -> String {
        var lines: [String] = []
        if !diff.prunedNodes.isEmpty {
            lines.append("Pruning on \(diff.prunedNodes.map(\.rawValue).joined(separator: ", ")): what the file doesn't list there goes.")
        }
        for change in diff.changes where change.action != .unchanged {
            let symbol = switch change.action {
            case .create: "+"
            case .update: "~"
            case .prune: "-"
            case .unchanged: "="
            }
            lines.append("\(symbol) \(change.action.rawValue) \(change.kind.rawValue) \(terminalSafe(change.name)) on \(change.node)")
            for field in change.fields {
                // Environment changes carry no values, only added, removed or changed.
                if field.field.hasPrefix("env.") {
                    lines.append("    \(terminalSafe(field.field)): \(field.to ?? field.from ?? "changed")")
                } else {
                    lines.append("    \(terminalSafe(field.field)): \(terminalSafe(field.from ?? "(none)")) -> \(terminalSafe(field.to ?? "(none)"))")
                }
            }
        }
        lines.append(diff.hasChanges ? "\(diff.summary)." : "Nothing to change (\(diff.count(.unchanged)) unchanged).")
        return lines.joined(separator: "\n")
    }

    public static func render(_ response: ApplyResponse) -> String {
        var lines: [String] = []
        for result in response.results {
            let what = "\(result.action.rawValue) \(result.kind.rawValue) \(terminalSafe(result.name)) on \(result.node)"
            lines.append(result.error.map { "failed: \(what): \(terminalSafe($0))" } ?? "done: \(what)")
        }
        for failure in response.failedNodes {
            lines.append("failed: node \(failure.node): \(terminalSafe(failure.error))")
        }
        if lines.isEmpty { lines.append("Nothing to change.") }
        return lines.joined(separator: "\n")
    }
}
