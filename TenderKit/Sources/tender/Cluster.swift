import ArgumentParser
import Foundation
import TenderClient
import TenderCore

extension Tender {
    struct Deploy: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Fetch a release from the configured source and restart on it.",
            discussion: "Each node downloads the release itself, and verifies its sha256 before installing it."
        )
        @Argument(help: "Service name.") var name: String
        @Option(help: "Release version, as CI published it.") var release: String
        @Option(help: "Only this node. Defaults to every node running the service.") var node: String?
        @OptionGroup var options: CommonOptions

        func run() async throws {
            let response: DeployResponse
            do {
                response = try await options.makeClient().deploy(service: name, version: release, node: node)
            } catch let error as TenderClientError {
                try options.fail(error)
            }
            print(options.json ? try options.encode(response) : response.outcomes.map { outcome in
                "\(outcome.node): " + (outcome.sha12 ?? "failed: \(outcome.error ?? "unknown error")")
            }.joined(separator: "\n"))
            if response.outcomes.contains(where: { $0.error != nil }) { throw ExitCode.failure }
        }
    }

    struct Credentials: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Manage this node's cloud credentials and secrets sources.",
            discussion: """
                The default credentials serve ${secret:gcp:…}, release fetching and log offload. A named \
                source, defined under secrets.sources in the node's cloud.json with its own project and \
                allowed services, has its own key and serves ${secret:<source>:…}.
                """,
            subcommands: [Set.self, Show.self, Delete.self])

        struct Set: AsyncParsableCommand {
            static let configuration = CommandConfiguration(
                abstract: "Save a GCP service account key on this node.",
                discussion: "The key goes to the local daemon's secret store. You can delete the file afterwards."
            )
            @Option(help: "Path to the key's JSON file.") var file: String
            @Option(help: "A named secrets source from cloud.json. Defaults to the node's default credentials.") var source: String?
            @OptionGroup var options: CommonOptions

            func run() async throws {
                let json = try String(contentsOf: URL(filePath: file), encoding: .utf8)
                try await options.run({ try await $0.setCredentials(serviceAccountJSON: json, source: source) }) {
                    "Saved credentials for \($0.clientEmail)" + ($0.source.map { " (source \($0))" } ?? "")
                }
            }
        }

        struct Show: AsyncParsableCommand {
            static let configuration = CommandConfiguration(
                abstract: "Show a node's secrets sources: account, project, allowed services and failures.",
                discussion: "Without --node, asks this machine's daemon. With it, asks the head, which has each node's latest report. Never shows a key."
            )
            @Option(help: "A node, by name or ID, as the head last heard from it.") var node: String?
            @OptionGroup var options: CommonOptions

            func run() async throws {
                guard let node else {
                    try await options.run({ try await $0.credentials() }) { ProcessTable.render($0) }
                    return
                }
                try await options.run({ client -> NodeSecretsStatus in
                    let nodes = try await client.nodes().nodes
                    guard let match = nodes.first(where: { $0.info.id.rawValue == node || $0.info.hostname == node }) else {
                        throw TenderClientError.api(status: 404, code: "unknown_node", message: "No node named \(node).")
                    }
                    guard let secrets = match.secrets else {
                        throw TenderClientError.api(status: 409, code: "not_reported",
                                                    message: "\(node) hasn't reported its secrets sources. It may run an older tenderd.")
                    }
                    return secrets
                }) { ProcessTable.render($0, node: node) }
            }
        }

        struct Delete: AsyncParsableCommand {
            static let configuration = CommandConfiguration(
                abstract: "Forget a source's key on this node.",
                discussion: "Cached values stay, so running services keep starting until a value changes. Deleting the default credentials also stops release fetching and log offload."
            )
            @Option(help: "A named secrets source. Defaults to the node's default credentials.") var source: String?
            @OptionGroup var options: CommonOptions

            func run() async throws {
                try await options.run({ try await $0.deleteCredentials(source: source) }) { ProcessTable.render($0) }
            }
        }
    }

    struct Token: AsyncParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Manage join tokens.", subcommands: [Create.self])

        struct Create: AsyncParsableCommand {
            static let configuration = CommandConfiguration(abstract: "Create a single-use join token. Run this on the head.")
            @Option(help: "Seconds until it expires.") var ttl = 900
            @OptionGroup var options: CommonOptions

            func run() async throws {
                try await options.run({ try await $0.createJoinToken(ttlSeconds: ttl) }) { response in
                    "\(response.token)\n\nOn the new node, within \(ttl / 60) minutes:\n  tender join <this-head> --token \(response.token)"
                }
            }
        }
    }

    struct Join: AsyncParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Join this node to a cluster. Its daemon must be running.")
        @Argument(help: "The head's address: host or host:port.") var head: String
        @Option(help: "From `tender token create`.") var token: String
        @Option(help: "This node's ID. Defaults to the UUID this machine made on first run; use this only to override it.") var nodeId: String?
        @OptionGroup var options: CommonOptions

        func run() async throws {
            try await options.run({ try await $0.join(head: head, token: token, nodeID: nodeId) }) { status in
                "Joined: \(status.nodeID) -> head \(status.headNode)"
            }
        }
    }

    struct Leave: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Make this worker forget its cluster, so that it can join again.",
            discussion: "Services keep running. The daemon restarts, under launchd. Revoke the node on the head as well."
        )
        @OptionGroup var options: CommonOptions

        func run() async throws {
            try await options.run({ try await $0.leave() }) { _ in "Left the cluster." }
        }
    }

    struct Nodes: AsyncParsableCommand {
        static let configuration = CommandConfiguration(abstract: "List the cluster's nodes.")
        @OptionGroup var options: CommonOptions

        func run() async throws {
            try await options.run({ try await $0.nodes() }) { ProcessTable.render($0) }
        }
    }

    struct Status: AsyncParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Show whether this machine's daemon is listening for other nodes.")
        @OptionGroup var options: CommonOptions

        func run() async throws {
            try await options.run({ try await $0.network() }) { "tenderd is \($0.summary)" }
        }
    }

    struct Node: AsyncParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Manage a node.",
                                                        subcommands: [Label.self, Rename.self, Revoke.self, Remove.self])

        struct Label: AsyncParsableCommand {
            static let configuration = CommandConfiguration(
                abstract: "Show, set or remove a node's labels.",
                discussion: """
                    Labels are key=value pairs the node keeps in its own config and reports to the head, \
                    for grouping now and placement later. Keys use lowercase letters, digits, '.', '_', '-' \
                    and '/'. `role` is Tender's own; `name` is the display name (see `tender node rename`). \
                    With no pairs and no --remove, prints the node's labels.
                    """
            )
            @Argument(help: "Node ID, name or hostname.") var node: String
            @Argument(help: "Labels to set, as key=value.") var pairs: [String] = []
            @Option(name: .customLong("remove"), help: "A label key to remove. Repeatable.") var remove: [String] = []
            @OptionGroup var options: CommonOptions

            func run() async throws {
                var set: [String: String] = [:]
                for pair in pairs {
                    guard let equals = pair.firstIndex(of: "="), equals != pair.startIndex else {
                        throw ValidationError("'\(pair)' isn't key=value.")
                    }
                    set[String(pair[..<equals])] = String(pair[pair.index(after: equals)...])
                }
                let update = NodeLabelsUpdate(set: set, remove: remove)
                try await options.run({ client -> NodeSummary in
                    let list = update == NodeLabelsUpdate() ? try await client.nodes() : try await client.updateLabels(node: node, update)
                    guard let match = list.nodes.first(where: { Self.matches($0, node) }) else {
                        throw TenderClientError.api(status: 404, code: "node_not_found", message: "No node named \(node).")
                    }
                    return match
                }) { summary in
                    let labels = summary.info.labels.sorted { $0.key < $1.key }
                    return labels.isEmpty ? "\(summary.info.displayName) has no labels." : labels.map { "\($0.key)=\($0.value)" }.joined(separator: "\n")
                }
            }

            static func matches(_ summary: NodeSummary, _ reference: String) -> Bool {
                let wanted = reference.lowercased()
                return summary.info.id.rawValue == reference || summary.info.labels[NodeLabels.nameKey]?.lowercased() == wanted
                    || summary.info.hostname?.lowercased() == wanted
            }
        }

        struct Rename: AsyncParsableCommand {
            static let configuration = CommandConfiguration(
                abstract: "Give a node a display name, used everywhere in place of its hostname.",
                discussion: "Sets the node's `name` label. The ID doesn't change, so nothing else does. --reset goes back to the hostname."
            )
            @Argument(help: "Node ID, name or hostname.") var node: String
            @Argument(help: "The new display name.") var name: String?
            @Flag(help: "Remove the display name.") var reset = false
            @OptionGroup var options: CommonOptions

            func validate() throws {
                guard (name == nil) == reset else { throw ValidationError("Give a new name, or --reset, not both.") }
            }

            func run() async throws {
                let update = name.map { NodeLabelsUpdate(set: [NodeLabels.nameKey: $0]) } ?? NodeLabelsUpdate(remove: [NodeLabels.nameKey])
                try await options.run({ try await $0.updateLabels(node: node, update) }) { _ in
                    name.map { "\(node) is now shown as \($0)" } ?? "\(node) is shown by its hostname again"
                }
            }
        }

        struct Revoke: AsyncParsableCommand {
            static let configuration = CommandConfiguration(abstract: "Refuse a node's certificate from now on.")
            @Argument(help: "Node ID.") var id: String
            @OptionGroup var options: CommonOptions

            func run() async throws {
                try await options.run({ try await $0.revokeNode(id) }) { _ in "Revoked \(id)" }
            }
        }

        struct Remove: AsyncParsableCommand {
            static let configuration = CommandConfiguration(
                abstract: "Delete a node's records on the head, such as a stale one, and revoke its certificate.")
            @Argument(help: "Node ID (a UUID), or its hostname if only one node has it. See `tender nodes`.") var id: String
            @Flag(help: "Remove the node even though it is up.") var force = false
            @Flag(help: "Also delete its stored log lines. They are kept by default.") var purgeLogs = false
            @OptionGroup var options: CommonOptions

            func run() async throws {
                try await options.run({ try await $0.removeNode(id, force: force, purgeLogs: purgeLogs) }) { _ in "Removed \(id)" }
            }
        }
    }

    struct CA: AsyncParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Manage the internal CA.", subcommands: [Export.self])

        struct Export: AsyncParsableCommand {
            static let configuration = CommandConfiguration(
                abstract: "Print the CA certificate and private key, for an offline backup.",
                discussion: "Anyone with this output can issue certificates for your cluster. Store it offline."
            )
            @OptionGroup var options: CommonOptions

            func run() async throws {
                try await options.run({ try await $0.exportCA() }) { $0.certificatePEM + "\n" + $0.privateKeyPEM }
            }
        }
    }

    struct ApiToken: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "api-token", abstract: "Manage API tokens for the CLI and app.",
            subcommands: [Create.self, List.self, Revoke.self])

        struct Create: AsyncParsableCommand {
            static let configuration = CommandConfiguration(abstract: "Create a token. It's shown once.")
            @Argument(help: "A name for the token.") var name: String
            @Option(help: "read or write.") var scope = "read"
            @OptionGroup var options: CommonOptions

            func run() async throws {
                guard let parsed = APIScope(rawValue: scope) else { throw ValidationError("--scope must be read or write.") }
                try await options.run({ try await $0.createAPIToken(name: name, scope: parsed) }) { $0.token }
            }
        }

        struct List: AsyncParsableCommand {
            static let configuration = CommandConfiguration(abstract: "List API tokens.")
            @OptionGroup var options: CommonOptions

            func run() async throws {
                try await options.run({ try await $0.apiTokens() }) { list in
                    list.tokens.isEmpty ? "No API tokens." : list.tokens.map { "\($0.name)  \($0.scope.rawValue)" }.joined(separator: "\n")
                }
            }
        }

        struct Revoke: AsyncParsableCommand {
            static let configuration = CommandConfiguration(abstract: "Revoke an API token.")
            @Argument(help: "The token's name.") var name: String
            @OptionGroup var options: CommonOptions

            func run() async throws {
                try await options.run({ try await $0.revokeAPIToken(name: name) }) { _ in "Revoked \(name)" }
            }
        }
    }

    struct Context: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Choose which head this machine's CLI talks to.", subcommands: [Set.self, Show.self, Clear.self])

        struct Set: AsyncParsableCommand {
            static let configuration = CommandConfiguration(abstract: "Save a head's address and API token.")
            @Option(help: "host or host:port.") var head: String
            @Option(help: "From `tender api-token create`. Prefer $TENDER_TOKEN: arguments are visible to other users in `ps`.")
            var token: String?

            func run() async throws {
                guard let token = token ?? ProcessInfo.processInfo.environment["TENDER_TOKEN"] else {
                    throw ValidationError("Pass --token or set TENDER_TOKEN.")
                }
                let caPEM: String
                do {
                    caPEM = try await ClientPinning.fetchCA(head: head, credential: token)
                } catch let error as ClientPinningError {
                    throw ValidationError(error.description)
                }
                try ClientContextStore.standard().save(ClientContext(head: head, caPEM: caPEM), token: token)
                print("Saved. Commands now reach \(head) when no local daemon is running, or with --remote.")
            }
        }

        struct Show: AsyncParsableCommand {
            static let configuration = CommandConfiguration(abstract: "Show the saved head.")
            func run() async throws {
                print((try ClientContextStore.standard().load())?.context.head ?? "No head configured.")
            }
        }

        struct Clear: AsyncParsableCommand {
            static let configuration = CommandConfiguration(abstract: "Forget the saved head and its token.")
            func run() async throws {
                try ClientContextStore.standard().clear()
                print("Cleared.")
            }
        }
    }
}
