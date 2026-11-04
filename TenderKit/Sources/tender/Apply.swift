import ArgumentParser
import Foundation
import TenderClient
import TenderCore

extension Tender {
    struct Apply: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Create or update the services a YAML file describes.",
            discussion: """
                Prints what would change first, then asks, unless --yes is given or stdin isn't a terminal. \
                Applying the same file again changes nothing and restarts nothing. Services the file doesn't \
                list are left alone unless --prune, which prunes only the nodes the file names (an item's \
                node:, or the head for items without one); --prune-all prunes every node. See \
                docs/examples/services.yaml.
                """
        )
        @Option(name: .shortAndLong, help: "The service file.") var file: String
        @Flag(help: "Only print what would change.") var dryRun = false
        @Flag(help: "Also delete services, and abandon adopted jobs, that the file doesn't list, on the nodes it names.") var prune = false
        @Flag(help: "Like --prune, on every node, including ones the file doesn't name.") var pruneAll = false
        @Flag(name: .shortAndLong, help: "Don't ask before applying.") var yes = false
        @OptionGroup var options: CommonOptions

        func run() async throws {
            let loaded: ServiceFile.Loaded
            do {
                loaded = try ServiceFile.load(URL(filePath: file))
            } catch let error as ManifestError {
                try options.fail(.api(status: 400, code: "invalid_manifest", message: error.message))
            }
            do {
                let client = try options.makeClient()
                var request = ApplyRequest(items: loaded.manifest.items, prune: prune || pruneAll, pruneAll: pruneAll,
                                           dryRun: true, sha256: loaded.sha256)
                let preview = try await client.apply(request)
                if dryRun || !preview.diff.hasChanges {
                    try report(preview, diff: true)
                    return
                }
                if !options.json {
                    print(ManifestDiffRenderer.render(preview.diff))
                    for failure in preview.failedNodes { print("failed: node \(failure.node): \(terminalSafe(failure.error))") }
                }
                if !yes, isatty(STDIN_FILENO) == 1 {
                    FileHandle.standardError.write(Data("Apply these changes? [y/N] ".utf8))
                    guard let answer = readLine(), ["y", "yes"].contains(answer.lowercased()) else {
                        throw ExitCode.failure
                    }
                }
                request.dryRun = false
                try report(try await client.apply(request), diff: false)
            } catch let error as TenderClientError {
                try options.fail(error)
            }
        }

        private func report(_ response: ApplyResponse, diff: Bool) throws {
            if options.json {
                print(try options.encode(response))
            } else {
                print(diff ? ManifestDiffRenderer.render(response.diff) : ManifestDiffRenderer.render(response))
                for failure in diff ? response.failedNodes : [] {
                    print("failed: node \(failure.node): \(terminalSafe(failure.error))")
                }
            }
            if !response.succeeded { throw ExitCode.failure }
        }
    }

    struct Export: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Print the services as a YAML service file.",
            discussion: "Applying the output changes nothing. Secrets stay ${secret:…} references, but literal environment values, including ones that came from an env_file, are printed as they are."
        )
        @Option(help: "Only this service or adopted label.") var service: String?
        @Option(help: "Only this node.") var node: String?
        @OptionGroup var options: CommonOptions

        func run() async throws {
            do {
                let list = try await options.makeClient().specs(node: node)
                if options.json {
                    print(try options.encode(list))
                    return
                }
                for unreachable in list.unreachableNodes {
                    FileHandle.standardError.write(Data("warning: \(unreachable) is unreachable and left out.\n".utf8))
                }
                print(try ServiceFile.render(list.items(service: service, node: node)), terminator: "")
            } catch let error as TenderClientError {
                try options.fail(error)
            }
        }
    }
}
