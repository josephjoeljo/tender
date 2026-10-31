import ArgumentParser
import Foundation
import TenderClient
import TenderCore

extension Tender {
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
        @Option(help: "This node's ID. It must match its Tailscale machine name. Defaults to the hostname.") var nodeId: String?
        @OptionGroup var options: CommonOptions

        func run() async throws {
            try await options.run({ try await $0.join(head: head, token: token, nodeID: nodeId) }) { status in
                "Joined: \(status.nodeID) -> head \(status.headNode)"
            }
        }
    }

    struct Nodes: AsyncParsableCommand {
        static let configuration = CommandConfiguration(abstract: "List the cluster's nodes.")
        @OptionGroup var options: CommonOptions

        func run() async throws {
            try await options.run({ try await $0.nodes() }) { ProcessTable.render($0) }
        }
    }

    struct Node: AsyncParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Manage a node.", subcommands: [Revoke.self])

        struct Revoke: AsyncParsableCommand {
            static let configuration = CommandConfiguration(abstract: "Refuse a node's certificate from now on.")
            @Argument(help: "Node ID.") var id: String
            @OptionGroup var options: CommonOptions

            func run() async throws {
                try await options.run({ try await $0.revokeNode(id) }) { _ in "Revoked \(id)" }
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
                try await options.run({ try await $0.exportCA() }) { $0.certificatePEM + $0.privateKeyPEM }
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
            @Option(help: "From `tender api-token create`.") var token: String

            func run() async throws {
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
