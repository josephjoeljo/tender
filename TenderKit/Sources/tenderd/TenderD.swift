import ArgumentParser
import Foundation
import TenderAgent
import TenderCore
import TenderHead
import TenderPKI

@main
struct TenderD: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "tenderd",
        abstract: "Tender daemon: runs as the head node or a worker.",
        subcommands: [Run.self, Exec.self, SecretsExport.self, SecretsImport.self, CAImport.self],
        defaultSubcommand: Run.self
    )
}

struct EnvironmentOptions: ParsableArguments {
    @Flag(help: "Use per-user paths and the gui/<uid> launchd domain (no root needed).")
    var dev = false

    @Option(help: .hidden)
    var root: String?

    @Option(help: .hidden)
    var labelPrefix: String?

    /// `--root` and `--label-prefix` let several dev daemons share one Mac, for tests.
    var environment: TenderEnvironment {
        guard dev else { return .production }
        guard let root else { return .development }
        let url = URL(filePath: root)
        return TenderEnvironment(
            mode: .development,
            root: url,
            logsDirectory: url.appending(path: "logs"),
            plistDirectory: url.appending(path: "agents"),
            serviceLabelPrefix: labelPrefix ?? "com.olympsis.tender.svc"
        )
    }
}

struct Run: AsyncParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Run the daemon.")

    enum Role: String, ExpressibleByArgument { case head, worker }

    @Option(help: "Which role this daemon plays. The head also runs a worker.")
    var role: Role = .worker

    @OptionGroup var environmentOptions: EnvironmentOptions

    @Option(help: "This node's ID. It must match its Tailscale machine name. Defaults to the hostname.")
    var nodeId: String?

    @Option(help: "Address to listen on. Defaults to the Tailscale IP.")
    var listen: String?

    @Option(help: "Address other nodes use to reach this one. Defaults to the listen address.")
    var advertise: String?

    @Option(help: "Port for node-to-node traffic.")
    var agentPort = 7070

    @Option(help: "Port for the head's public API.")
    var apiPort = 7071

    @Option(help: "Tailscale identity check: enforce, warn or off.")
    var identityMode: String = "enforce"

    @Option(help: "Seconds between heartbeats.")
    var heartbeatInterval = 5

    @Flag(help: "EXPERIMENTAL: report CPU, GPU, Neural Engine and DRAM power, read through a private macOS API.")
    var experimentalPower = false

    func run() async throws {
        let env = environmentOptions.environment
        guard let mode = IdentityMode(rawValue: identityMode) else {
            throw ValidationError("--identity-mode must be enforce, warn or off.")
        }
        print("tenderd starting: role=\(role.rawValue) mode=\(env.mode.rawValue) root=\(env.root.path())")

        var host = listen
        if host == nil { host = await TailscaleCLI.localIPv4() }
        let cluster = ClusterOptions(listenHost: host, advertiseHost: advertise, agentPort: agentPort,
                                     identityMode: mode, heartbeatInterval: .seconds(heartbeatInterval),
                                     experimentalPower: experimentalPower)
        let secrets = env.makeSecretStore()
        var hooks: ClusterHooks?
        if role == .head {
            let names = [advertise, host].compactMap { $0 }
            let options = HeadOptions(nodeID: NodeID(nodeId ?? defaultNodeID()), apiHost: host, apiPort: apiPort,
                                      agentPort: agentPort, advertisedNames: names)
            hooks = try HeadServices(environment: env, secrets: secrets, options: options).hooks()
        }
        try await AgentRuntime(environment: env, secrets: secrets, cluster: cluster, hooks: hooks).run()
    }
}

/// What a service that references secrets runs as: launchd starts this, and it becomes
/// the program. It runs as the service's user and reads the service's file, which any
/// service with the same user could read too: isolation is per user, not per service.
struct Exec: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Start a program with its secrets filled in. Written into plists by tenderd.",
        shouldDisplay: false
    )
    @Option(help: "Service name, for error messages.") var service: String
    @Option(help: "Instance number, for error messages.") var instance = 0
    @Option(help: "The service's secrets file.") var secrets: String
    @Option(name: .customLong("secret-file"), help: "A secret to write as a file, as <path>=<ref>. Repeatable.") var secretFiles: [String] = []
    @Argument(parsing: .postTerminator, help: "Program and arguments, after `--`.") var command: [String] = []

    func run() throws {
        SecretExec.run(service: "\(service).\(instance)", secretsFile: URL(filePath: secrets), files: secretFiles, command: command)
    }
}

/// Keychain items trust the binary that created them, so `tender daemon install
/// --system` has the old binary export them, and the new one import them.
struct SecretsExport: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "secrets-export", abstract: "Write secrets to a private file, for an upgrade.")
    @Option(help: "File to create.") var to: String
    @OptionGroup var environmentOptions: EnvironmentOptions

    func run() async throws {
        let environment = environmentOptions.environment
        let store = environment.makeSecretStore()
        var values: [String: Data] = [:]
        // Services' secrets and cached GCP values too: they live in the same Keychain,
        // under the same binary.
        let vault = SecretVault(secrets: store, store: try StateStore(environment: environment))
        for name in ClusterSecrets.all + (try vault.live()).map(\.name.itemName) + (try vault.cachedGCPItems()) {
            if let value = try store.read(name) { values[name] = value }
        }
        guard FileManager.default.createFile(atPath: to, contents: nil, attributes: [.posixPermissions: 0o600]) else {
            throw ValidationError("Can't create \(to).")
        }
        try JSONEncoder().encode(values).write(to: URL(filePath: to))
    }
}

struct SecretsImport: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "secrets-import", abstract: "Read secrets from `secrets-export` and delete the file.")
    @Option(help: "File to read.") var from: String
    @OptionGroup var environmentOptions: EnvironmentOptions

    func run() async throws {
        let store = environmentOptions.environment.makeSecretStore()
        let values = try JSONDecoder().decode([String: Data].self, from: Data(contentsOf: URL(filePath: from)))
        for (name, value) in values { try store.write(name, value) }
        try FileManager.default.removeItem(atPath: from)
    }
}

/// A subcommand of `tenderd`, not `tender`, so that the Keychain items belong to
/// `tenderd`, and so that it works on a head that refuses to start with half a CA.
struct CAImport: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "ca-import", abstract: "Restore the CA from a `tender ca export` backup.")
    @Option(help: "Backup file to read.") var from: String
    @Flag(help: "Overwrite a different CA. Nodes that joined it will have to join again.") var replace = false
    @OptionGroup var environmentOptions: EnvironmentOptions

    func run() async throws {
        let backup = try String(contentsOf: URL(filePath: from), encoding: .utf8)
        let store = environmentOptions.environment.makeSecretStore()
        let restored = try HeadServices.restoreAuthority(backupPEM: backup, secrets: store, replace: replace)
        print("Restored CA \(restored.fingerprint). Restart the daemon to use it.")
    }
}
