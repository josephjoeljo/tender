import ArgumentParser
import Foundation
import TenderClient
import TenderCore

extension Tender {
    struct Secret: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Manage services' secrets.",
            discussion: """
                Reference a secret from a service's environment or arguments with ${secret:NAME} \
                (that service's own) or ${secret:shared/NAME}, for example \
                tender start api --env 'MONGO_URL=mongodb://app:${secret:MONGO_PASSWORD}@db/olympsis' -- ./api. \
                ${secret:gcp:NAME}, ${secret:gcp:NAME@4} and ${secret:gcp:projects/P/secrets/S[@4]} come from \
                GCP Secret Manager, fetched and cached by the node. \
                Values stay on the node that runs the service and no command ever prints one.
                """,
            subcommands: [Set.self, List.self, Delete.self]
        )

        struct Set: AsyncParsableCommand {
            static let configuration = CommandConfiguration(
                abstract: "Store a secret and restart the services that use it.",
                discussion: "Reads the value from a hidden prompt, or from stdin when it isn't a terminal. A value never goes on the command line, where shell history and `ps` would show it."
            )
            @Argument(help: "<service>/<NAME> or shared/<NAME>.") var name: String
            @Option(help: "Only on this node. Defaults to every node running the service.") var node: String?
            @Flag(help: "On every node, for a shared secret.") var allNodes = false
            @Option(help: "Read the value from this file, byte for byte.") var fromFile: String?
            @OptionGroup var options: CommonOptions

            func run() async throws {
                let value = try readValue()
                try await options.run({ try await $0.setSecret(name, value: value, node: node, allNodes: allNodes) },
                                      text: { list in "Set \(name) on \(Self.nodes(list))." })
            }

            private func readValue() throws -> Data {
                if let fromFile { return try Data(contentsOf: URL(filePath: fromFile)) }
                if isatty(STDIN_FILENO) == 1 {
                    var buffer = [CChar](repeating: 0, count: SecretSetRequest.maxValueSize + 1)
                    guard let entered = readpassphrase("Value for \(name): ", &buffer, buffer.count, RPP_REQUIRE_TTY) else {
                        throw ValidationError("Can't read from the terminal.")
                    }
                    defer { buffer.withUnsafeMutableBytes { _ = memset_s($0.baseAddress, $0.count, 0, $0.count) } }
                    return Data(String(cString: entered).utf8)
                }
                // `echo value | tender secret set` adds a newline that isn't part of the secret.
                var data = FileHandle.standardInput.readDataToEndOfFile()
                if data.last == 10 { data.removeLast() }
                if data.last == 13 { data.removeLast() }
                return data
            }

            static func nodes(_ list: SecretList) -> String {
                let names = Swift.Set(list.secrets.map(\.node.rawValue)).sorted()
                return names.isEmpty ? "no node" : names.joined(separator: ", ")
            }
        }

        struct List: AsyncParsableCommand {
            static let configuration = CommandConfiguration(abstract: "List secrets by name. Values are never shown.")
            @Option(help: "Only this node. Defaults to every node.") var node: String?
            @OptionGroup var options: CommonOptions

            func run() async throws {
                try await options.run({ try await $0.secrets(node: node) }, text: Self.render)
            }

            static func render(_ list: SecretList) -> String {
                let formatter = ISO8601DateFormatter()
                var rows = [["NAME", "NODE", "REV", "UPDATED", "USED BY"]]
                for secret in list.secrets {
                    rows.append([secret.name, secret.node.rawValue, String(secret.revision),
                                 formatter.string(from: secret.updatedAt),
                                 secret.usedBy.isEmpty ? "-" : secret.usedBy.joined(separator: ",")])
                }
                var lines = list.secrets.isEmpty && !list.gcp.isEmpty ? [] : table(rows)
                if !list.gcp.isEmpty {
                    var gcp = [["GCP SECRET", "NODE", "VERSION", "REV", "CHECKED", "USED BY", "STATUS"]]
                    for secret in list.gcp {
                        let status = secret.stale ? "stale: \(secret.fetchError ?? "")"
                            : secret.cached ? "ok" : "not fetched: \(secret.fetchError ?? "pending")"
                        gcp.append([secret.name, secret.node.rawValue, secret.version ?? "-", String(secret.revision),
                                    secret.checkedAt.map(formatter.string(from:)) ?? "-",
                                    secret.usedBy.isEmpty ? "-" : secret.usedBy.joined(separator: ","), status])
                    }
                    lines += [""] + table(gcp)
                }
                for missing in list.missing { lines.append("missing: \(missing)") }
                for node in list.unreachableNodes { lines.append("unreachable: \(node)") }
                return lines.joined(separator: "\n")
            }

            private static func table(_ rows: [[String]]) -> [String] {
                let widths = rows[0].indices.map { column in rows.map { $0[column].count }.max() ?? 0 }
                return rows.map { row in
                    row.enumerated().map { index, cell in
                        index == row.count - 1 ? cell : cell.padding(toLength: widths[index] + 2, withPad: " ", startingAt: 0)
                    }.joined()
                }
            }
        }

        struct Delete: AsyncParsableCommand {
            static let configuration = CommandConfiguration(
                abstract: "Delete a secret.",
                discussion: "Services that still reference it restart and exit with code 78 until it's set again."
            )
            @Argument(help: "<service>/<NAME> or shared/<NAME>.") var name: String
            @Option(help: "Only on this node. Defaults to every node running the service.") var node: String?
            @Flag(help: "On every node, for a shared secret.") var allNodes = false
            @OptionGroup var options: CommonOptions

            func run() async throws {
                try await options.run({ try await $0.deleteSecret(name, node: node, allNodes: allNodes) },
                                      text: { _ in "Deleted \(name)." })
            }
        }
    }
}
