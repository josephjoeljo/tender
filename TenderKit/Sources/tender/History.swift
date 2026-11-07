import ArgumentParser
import Foundation
import TenderClient
import TenderCore

extension Tender {
    struct History: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Show who changed what in the cluster, newest first.",
            discussion: """
                Every call that changes something, through the head's API or its socket, is in the head's \\
                audit log with the token's name (or local-socket), the action, what it acted on and whether \\
                it worked. Reads aren't recorded, and neither are request bodies, so no value ever is. \\
                Failures are counted first; --failed shows only those.
                """
        )
        @Option(help: "Only changes newer than this, like 1h, 30m or 7d.") var since: String = "24h"
        @Option(help: "Only changes older than this, like 1h.") var until: String?
        @Option(name: [.customShort("n"), .long], help: "At most this many, up to \(AuditQuery.maxLimit).") var limit = 50
        @Option(help: "Only this token's changes, or local-socket.") var who: String?
        @Option(help: "Only changes about this service, secret or node.") var about: String?
        @Flag(help: "Only failed changes.") var failed = false
        @OptionGroup var options: CommonOptions

        func run() async throws {
            let query = AuditQuery(since: try Logs.parseSince(since), until: try until.map { try Logs.parseSince($0) },
                                   limit: limit, who: who, about: about, failedOnly: failed)
            var names: [NodeID: String] = [:]
            try await options.run({ client in
                if !options.json { names = ProcessTable.names(try? await client.nodes()) }
                return try await client.history(query)
            }) { ProcessTable.render($0, names: names) }
        }
    }
}
