import Foundation
import LaunchdKit
import Testing
import TenderCore
@testable import TenderAgent
@testable import TenderClient

private let fakeTenderd = "/opt/tender/libexec/tenderd"
private let password = "hunter2-correct-horse"

private func makeVault(_ env: TenderEnvironment) throws -> (SecretVault, StateStore) {
    let store = try StateStore(environment: env)
    return (SecretVault(secrets: env.makeSecretStore(), store: store), store)
}

private let api = ServiceSpec(
    name: "api", program: .executable("/bin/sleep"), arguments: ["1000", "${secret:shared/TOKEN}"],
    environment: ["MONGO_URL": "mongodb://app:${secret:MONGO_PASSWORD}@db", "PLAIN": "x"]
)

private func plist(_ data: Data) throws -> [String: Any] {
    try #require(try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any])
}

@Test func vaultRevisionsOnlyGoUp() throws {
    let env = try makeTestEnvironment()
    defer { try? FileManager.default.removeItem(at: env.root) }
    let (vault, _) = try makeVault(env)
    let name = SecretName(service: "api", name: "MONGO_PASSWORD")

    try vault.set(name, value: Data(password.utf8))
    #expect(try vault.value(name) == password)
    let first = try #require(try vault.live().first?.record.revision)
    try vault.set(name, value: Data("other".utf8))
    let second = try #require(try vault.live().first?.record.revision)
    #expect(second > first)

    #expect(try vault.delete(name))
    #expect(try vault.delete(name) == false)
    #expect(try vault.live().isEmpty)
    #expect(try vault.value(name) == nil)
    try vault.set(name, value: Data("again".utf8))
    #expect(try #require(try vault.live().first?.record.revision) > second + 1)
}

@Test func vaultRefusesValuesThatCantBeEnvironmentVariables() throws {
    let env = try makeTestEnvironment()
    defer { try? FileManager.default.removeItem(at: env.root) }
    let (vault, _) = try makeVault(env)
    let name = SecretName(shared: "X")
    for bad in [Data(), Data([0x61, 0x00]), Data([0xff, 0xfe]), Data(count: SecretVault.maxValueSize + 1)] {
        #expect(throws: SecretVaultError.self) { try vault.set(name, value: bad) }
    }
}

@Test func plistsHoldTemplatesAndARevisionNeverValues() async throws {
    let env = try makeTestEnvironment()
    defer { try? FileManager.default.removeItem(at: env.root) }
    let (vault, store) = try makeVault(env)
    let reconciler = Reconciler(environment: env, store: store, launchd: MemoryLaunchd(), vault: vault, execPath: fakeTenderd)
    try vault.set(SecretName(service: "api", name: "MONGO_PASSWORD"), value: Data(password.utf8))

    let before = try await reconciler.renderPlist(spec: api, instance: 1)
    #expect(!String(decoding: before, as: UTF8.self).contains(password))
    let parsed = try plist(before)
    let arguments = try #require(parsed["ProgramArguments"] as? [String])
    #expect(arguments == [fakeTenderd, "exec", "--service", "api", "--instance", "1",
                          "--secrets", env.serviceSecretsFile(service: "api").path(percentEncoded: false),
                          "--", "/bin/sleep", "1000", "${secret:shared/TOKEN}"])
    let variables = try #require(parsed["EnvironmentVariables"] as? [String: String])
    #expect(variables["MONGO_URL"] == "mongodb://app:${secret:MONGO_PASSWORD}@db")
    // MONGO_PASSWORD is set, shared/TOKEN isn't.
    #expect(variables["TENDER_SECRETS_REV"] == "1.0")

    try vault.set(SecretName(shared: "TOKEN"), value: Data("t".utf8))
    let after = try plist(try await reconciler.renderPlist(spec: api, instance: 1))
    #expect((after["EnvironmentVariables"] as? [String: String])?["TENDER_SECRETS_REV"] == "1.2")

    // Without references, nothing changes from before secrets existed.
    let plain = ServiceSpec(name: "web", program: .executable("/bin/sleep"), arguments: ["1"], environment: ["A": "$5"])
    let rendered = try plist(try await reconciler.renderPlist(spec: plain, instance: 0))
    #expect(rendered["ProgramArguments"] as? [String] == ["/bin/sleep", "1"])
    #expect(rendered["EnvironmentVariables"] as? [String: String] == ["A": "$5"])
}

@Test func changingASecretReplacesTheJobAndRewritesItsFile() async throws {
    let env = try makeTestEnvironment()
    defer { try? FileManager.default.removeItem(at: env.root) }
    let (vault, store) = try makeVault(env)
    let launchd = MemoryLaunchd()
    let reconciler = Reconciler(environment: env, store: store, launchd: launchd, vault: vault, execPath: fakeTenderd)
    try store.upsert(api)
    #expect(try await reconciler.reconcile().failures.isEmpty)
    #expect(try await reconciler.reconcile().applied.isEmpty)

    let file = env.serviceSecretsFile(service: "api")
    #expect(try SecretExec.loadSecrets(file: file).isEmpty)
    let mode = try FileManager.default.attributesOfItem(atPath: file.path(percentEncoded: false))[.posixPermissions] as? Int
    #expect(mode == 0o400)
    let directory = file.deletingLastPathComponent().path(percentEncoded: false)
    #expect(try FileManager.default.attributesOfItem(atPath: directory)[.posixPermissions] as? Int == 0o711)

    try vault.set(SecretName(service: "api", name: "MONGO_PASSWORD"), value: Data(password.utf8))
    let report = try await reconciler.reconcile()
    #expect(report.applied.contains { if case .replace = $0 { true } else { false } })
    #expect(try SecretExec.loadSecrets(file: file) == ["MONGO_PASSWORD": password])

    try store.deleteService("api")
    try await reconciler.reconcile()
    #expect(!FileManager.default.fileExists(atPath: directory))
}

@Test func aFIFOOrSymlinkInPlaceOfTheSecretsFileIsReplacedNotRead() async throws {
    let env = try makeTestEnvironment()
    defer { try? FileManager.default.removeItem(at: env.root) }
    let (vault, store) = try makeVault(env)
    let reconciler = Reconciler(environment: env, store: store, launchd: MemoryLaunchd(), vault: vault, execPath: fakeTenderd)
    try store.upsert(api)
    try vault.set(SecretName(service: "api", name: "MONGO_PASSWORD"), value: Data(password.utf8))
    #expect(try await reconciler.reconcile().failures.isEmpty)

    let file = env.serviceSecretsFile(service: "api")
    let path = file.path(percentEncoded: false)
    for plant in [{ mkfifo(path, 0o600) }, { symlink("/dev/zero", path) }] {
        try FileManager.default.removeItem(at: file)
        #expect(plant() == 0)
        #expect(try await reconciler.reconcile().failures.isEmpty)
        let type = try FileManager.default.attributesOfItem(atPath: path)[.type] as? FileAttributeType
        #expect(type == .typeRegular)
        #expect(try SecretExec.loadSecrets(file: file) == ["MONGO_PASSWORD": password])
    }
}

@Test func aServiceWhoseSecretsCantBeWrittenStillStops() async throws {
    let env = try makeTestEnvironment()
    defer { try? FileManager.default.removeItem(at: env.root) }
    let (vault, store) = try makeVault(env)
    let launchd = MemoryLaunchd()
    let reconciler = Reconciler(environment: env, store: store, launchd: launchd, vault: vault, execPath: fakeTenderd)
    try store.upsert(api)
    #expect(try await reconciler.reconcile().failures.isEmpty)
    let label = env.serviceLabel(service: "api", instance: 0)
    #expect(await launchd.loaded.contains(label))

    // A non-empty directory where the file goes, so the rename over it fails.
    let file = env.serviceSecretsFile(service: "api")
    try FileManager.default.removeItem(at: file)
    try FileManager.default.createDirectory(at: file.appending(path: "x"), withIntermediateDirectories: true)
    let running = try await reconciler.reconcile()
    #expect(running.failures.count == 1)
    #expect(running.applied.isEmpty)
    #expect(await launchd.loaded.contains(label))

    #expect(try store.setDesired(.stopped, service: "api"))
    let stopped = try await reconciler.reconcile()
    #expect(stopped.failures.count == 1)
    #expect(stopped.applied.contains(.bootout(label: label)))
    #expect(await !launchd.loaded.contains(label))
    #expect(!FileManager.default.fileExists(atPath: env.plistPath(label: label).path(percentEncoded: false)))
}

@Test func execResolvesTemplatesAndNamesMissingSecrets() throws {
    let secrets = ["MONGO_PASSWORD": password, "shared/TOKEN": "t"]
    let resolved = try SecretExec.resolve(
        arguments: ["/bin/sleep", "--token=${secret:shared/TOKEN}", "$${secret:literal}"],
        environment: ["MONGO_URL": "mongodb://app:${secret:MONGO_PASSWORD}@db", "PATH": "/bin", "TENDER_SECRETS_REV": "3"],
        secrets: secrets
    )
    #expect(resolved.arguments == ["/bin/sleep", "--token=t", "${secret:literal}"])
    #expect(resolved.environment == ["MONGO_URL": "mongodb://app:\(password)@db", "PATH": "/bin", "TENDER_SECRETS_REV": "3"])
    #expect(throws: SecretTemplateError.missing(SecretRef(name: "GONE"))) {
        try SecretExec.resolve(arguments: ["/bin/sleep"], environment: ["A": "${secret:GONE}"], secrets: secrets)
    }
}

/// Runs a daemon on a temp socket for the duration of `body`.
private func withSecretsDaemon(_ body: (TenderClient, TenderEnvironment) async throws -> Void) async throws {
    let env = try makeTestEnvironment()
    defer { try? FileManager.default.removeItem(at: env.root) }
    let runtime = AgentRuntime(environment: env, launchd: MemoryLaunchd(), execPath: fakeTenderd, shutdownSignals: [])
    let daemon = Task { try await runtime.run() }
    defer { daemon.cancel() }
    let socket = env.socketPath.path(percentEncoded: false)
    for _ in 0..<100 where !FileManager.default.fileExists(atPath: socket) {
        try await Task.sleep(for: .milliseconds(50))
    }
    try await Task.sleep(for: .milliseconds(100))
    try await body(TenderClient(socketPath: socket), env)
    daemon.cancel()
    _ = try? await daemon.value
}

@Test func secretsOverTheSocketNeverComeBack() async throws {
    try await withSecretsDaemon { client, env async throws in
        _ = try await client.start(api)
        let empty = try await client.secrets()
        #expect(empty.secrets.isEmpty)
        #expect(empty.missing == ["api: MONGO_PASSWORD", "api: shared/TOKEN"])

        let set = try await client.setSecret("api/MONGO_PASSWORD", value: Data(password.utf8))
        #expect(set.secrets.map(\.name) == ["api/MONGO_PASSWORD"])
        #expect(set.secrets.first?.usedBy == ["api"])
        #expect(set.missing == ["api: shared/TOKEN"])
        let raw = try await client.perform(.GET, "/v1/secrets")
        #expect(!String(decoding: raw.data, as: UTF8.self).contains(password))
        let processes = try await client.perform(.GET, "/v1/processes")
        #expect(!String(decoding: processes.data, as: UTF8.self).contains(password))
        let plistData = try Data(contentsOf: env.plistPath(label: env.serviceLabel(service: "api", instance: 0)))
        #expect(!String(decoding: plistData, as: UTF8.self).contains(password))

        #expect(try await client.deleteSecret("api/MONGO_PASSWORD").secrets.isEmpty)
        _ = try await client.deleteSecret("api/MONGO_PASSWORD")
        // The daemon checks names too, not only the client.
        let body = try JSONEncoder().encode(SecretSetRequest(value: Data("v".utf8)))
        #expect(try await client.perform(.PUT, "/v1/secrets/api/bad-name", body: body).status == 400)

        for bad in ["api", "api/bad-name", "x/../y"] {
            do {
                _ = try await client.setSecret(bad, value: Data("v".utf8))
                Issue.record("expected \(bad) to be refused")
            } catch let error as TenderClientError {
                #expect(error.code == "invalid_secret_name")
            }
        }
        do {
            _ = try await client.setSecret("shared/EMPTY", value: Data())
            Issue.record("expected an empty value to be refused")
        } catch let error as TenderClientError {
            #expect(error.code == "invalid_secret_value")
        }
        var reserved = api
        reserved.name = "shared"
        do {
            _ = try await client.start(reserved)
            Issue.record("expected the name shared to be refused")
        } catch let error as TenderClientError {
            #expect(error.code == "invalid_name")
        }
        var malformed = api
        malformed.name = "bad"
        malformed.environment = ["A": "${secret:no-dashes}"]
        do {
            _ = try await client.start(malformed)
            Issue.record("expected a malformed reference to be refused")
        } catch let error as TenderClientError {
            #expect(error.code == "invalid_secret_ref")
        }
    }
}

// MARK: Real launchd

/// The `tenderd` that `swift build` made, next to this package's tests.
private let builtTenderd: String? = {
    let package = URL(filePath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    let path = package.appending(path: ".build/debug/tenderd").path(percentEncoded: false)
    return FileManager.default.isExecutableFile(atPath: path) ? path : nil
}()

@Test(.enabled(if: builtTenderd != nil, "needs .build/debug/tenderd"))
func aRealJobSeesItsSecretThroughTenderdExec() async throws {
    let env = try makeTestEnvironment()
    let (vault, store) = try makeVault(env)
    let launchctl = Launchctl(domain: .currentUser)
    let reconciler = Reconciler(environment: env, store: store, launchd: launchctl, vault: vault,
                                execPath: builtTenderd, throttleInterval: 1)
    let label = env.serviceLabel(service: "echo", instance: 0)
    defer {
        let cleanup = Process()
        cleanup.executableURL = URL(filePath: "/bin/launchctl")
        cleanup.arguments = ["bootout", "\(launchctl.domain.target)/\(label)"]
        cleanup.standardError = FileHandle.nullDevice
        try? cleanup.run()
        cleanup.waitUntilExit()
        try? FileManager.default.removeItem(at: env.root)
    }
    let output = env.root.appending(path: "seen.txt")
    try store.upsert(ServiceSpec(
        name: "echo", program: .executable("/bin/sh"),
        arguments: ["-c", "printf %s \"$TOKEN\" > \(output.path(percentEncoded: false)); exec /bin/sleep 1000"],
        environment: ["TOKEN": "t=${secret:TOKEN}"]
    ))
    try vault.set(SecretName(service: "echo", name: "TOKEN"), value: Data("first".utf8))
    #expect(try await reconciler.reconcile().failures.isEmpty)

    func seen(_ expected: String) async throws -> Bool {
        for _ in 0..<100 {
            if (try? String(contentsOf: output, encoding: .utf8)) == expected { return true }
            try await Task.sleep(for: .milliseconds(100))
        }
        return false
    }
    #expect(try await seen("t=first"))
    let pid = try await launchctl.print(label: label)?.pid
    #expect(pid != nil)

    try vault.set(SecretName(service: "echo", name: "TOKEN"), value: Data("second".utf8))
    #expect(try await reconciler.reconcile().failures.isEmpty)
    #expect(try await seen("t=second"))
    let plistData = try Data(contentsOf: env.plistPath(label: label))
    #expect(!String(decoding: plistData, as: UTF8.self).contains("second"))

    try vault.delete(SecretName(service: "echo", name: "TOKEN"))
    #expect(try await reconciler.reconcile().failures.isEmpty)
    var exitCode: Int?
    for _ in 0..<100 {
        exitCode = try await launchctl.print(label: label)?.lastExitCode.map(Int.init)
        if exitCode == Int(SecretExec.configurationError) { break }
        try await Task.sleep(for: .milliseconds(100))
    }
    #expect(exitCode == Int(SecretExec.configurationError))

    try store.deleteService("echo")
    #expect(try await reconciler.reconcile().failures.isEmpty)
}
