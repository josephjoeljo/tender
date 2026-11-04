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

// MARK: Secret files

/// A directory outside the test environment's root, as secret files must be.
private func makeFilesDirectory() throws -> URL {
    let directory = URL(filePath: "/private/tmp/tender-test-files-\(UUID().uuidString.prefix(8))")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    return directory
}

@Test func secretFilesGoInThePlistAsPathsAndReferences() async throws {
    let env = try makeTestEnvironment()
    defer { try? FileManager.default.removeItem(at: env.root) }
    let (vault, store) = try makeVault(env)
    let reconciler = Reconciler(environment: env, store: store, launchd: MemoryLaunchd(), vault: vault, execPath: fakeTenderd)
    let spec = ServiceSpec(name: "web", program: .executable("/bin/sleep"), arguments: ["1"],
                           secretFiles: ["/opt/web/z.pem": "shared/TLS", "/opt/web/gcp.json": "GCP_KEY"])
    let first = try plist(try await reconciler.renderPlist(spec: spec, instance: 0))
    #expect(first["ProgramArguments"] as? [String] == [
        fakeTenderd, "exec", "--service", "web", "--instance", "0",
        "--secrets", env.serviceSecretsFile(service: "web").path(percentEncoded: false),
        "--secret-file", "/opt/web/gcp.json=GCP_KEY", "--secret-file", "/opt/web/z.pem=shared/TLS",
        "--", "/bin/sleep", "1",
    ])
    #expect((first["EnvironmentVariables"] as? [String: String])?["TENDER_SECRETS_REV"] == "0.0")

    // A file's secret is part of the revision, so rotating it restarts the service.
    try vault.set(SecretName(service: "web", name: "GCP_KEY"), value: Data(password.utf8))
    let rotated = try await reconciler.renderPlist(spec: spec, instance: 0)
    #expect((try plist(rotated)["EnvironmentVariables"] as? [String: String])?["TENDER_SECRETS_REV"] != "0.0")
    #expect(!String(decoding: rotated, as: UTF8.self).contains(password))
    try store.upsert(spec)
    #expect(try await reconciler.reconcile().failures.isEmpty)
    #expect(try SecretExec.loadSecrets(file: env.serviceSecretsFile(service: "web")) == ["GCP_KEY": password])
}

@Test func execWritesSecretFilesPrivatelyAndNeverThroughASymlink() throws {
    let directory = try makeFilesDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let victim = directory.appending(path: "victim")
    try Data("untouched".utf8).write(to: victim)
    let target = directory.appending(path: "key.json").path(percentEncoded: false)
    #expect(symlink(victim.path(percentEncoded: false), target) == 0)
    let nested = directory.appending(path: "new/dir/tls.pem").path(percentEncoded: false)

    let files = [(path: target, ref: SecretRef(name: "KEY")), (path: nested, ref: SecretRef(name: "TLS", shared: true))]
    try SecretExec.writeFiles(files, secrets: ["KEY": password, "shared/TLS": "pem"])
    #expect(try String(contentsOf: victim, encoding: .utf8) == "untouched")
    let attributes = try FileManager.default.attributesOfItem(atPath: target)
    #expect(attributes[.type] as? FileAttributeType == .typeRegular)
    #expect(attributes[.posixPermissions] as? Int == 0o400)
    #expect(try String(contentsOfFile: target, encoding: .utf8) == password)
    #expect(try String(contentsOfFile: nested, encoding: .utf8) == "pem")
    // Writing again replaces a 0400 file.
    try SecretExec.writeFiles(files, secrets: ["KEY": "rotated", "shared/TLS": "pem"])
    #expect(try String(contentsOfFile: target, encoding: .utf8) == "rotated")
    let leftovers = try FileManager.default.contentsOfDirectory(atPath: directory.path(percentEncoded: false)).filter { $0.hasPrefix(".") }
    #expect(leftovers.isEmpty)

    // A missing secret writes nothing, removes its stale file, and names it.
    #expect(throws: SecretTemplateError.missing(SecretRef(name: "TLS", shared: true))) {
        try SecretExec.writeFiles(files, secrets: ["KEY": "third"])
    }
    #expect(try String(contentsOfFile: target, encoding: .utf8) == "rotated")
    #expect(!FileManager.default.fileExists(atPath: nested))

    #expect(SecretExec.parseFile("/opt/a=b/key=shared/TLS")?.path == "/opt/a=b/key")
    #expect(SecretExec.parseFile("/opt/a=b/key=shared/TLS")?.ref == SecretRef(name: "TLS", shared: true))
    #expect(SecretExec.parseFile("relative=KEY") == nil)
    #expect(SecretExec.parseFile("/opt/key=bad-name") == nil)
}

@Test func theCleanerOnlyRemovesWhatExecWrote() throws {
    let directory = try makeFilesDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let path = { (name: String) in directory.appending(path: name).path(percentEncoded: false) }
    try SecretExec.writeFiles([(path("written"), SecretRef(name: "K"))], secrets: ["K": "v"])
    try Data("mine".utf8).write(to: URL(filePath: path("not-0400")))
    // Reached through /tmp, a symlink root owns in a directory only root can change.
    let throughTmp = "/tmp/" + directory.lastPathComponent + "/written"

    SecretFileCleaner.remove(path("not-0400"), owner: getuid())
    SecretFileCleaner.remove(path("written"), owner: getuid() + 1)
    #expect(FileManager.default.fileExists(atPath: path("not-0400")))
    #expect(FileManager.default.fileExists(atPath: path("written")))
    SecretFileCleaner.remove(throughTmp, owner: getuid())
    #expect(!FileManager.default.fileExists(atPath: path("written")))

    // A symlinked directory the user controls stops it.
    let elsewhere = directory.appending(path: "elsewhere")
    try FileManager.default.createDirectory(at: elsewhere, withIntermediateDirectories: true)
    try SecretExec.writeFiles([(elsewhere.appending(path: "key").path(percentEncoded: false), SecretRef(name: "K"))], secrets: ["K": "v"])
    #expect(symlink(elsewhere.path(percentEncoded: false), path("link")) == 0)
    SecretFileCleaner.remove(path("link") + "/key", owner: getuid())
    #expect(FileManager.default.fileExists(atPath: elsewhere.appending(path: "key").path(percentEncoded: false)))
}

@Test func secretFilePathsAreCheckedAndCleanedUpOverTheSocket() async throws {
    try await withSecretsDaemon { client, env async throws in
        let directory = try makeFilesDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let keep = directory.appending(path: "keep.json").path(percentEncoded: false)
        let drop = directory.appending(path: "drop.json").path(percentEncoded: false)
        var spec = ServiceSpec(name: "files", program: .executable("/bin/sleep"), arguments: ["1000"],
                               secretFiles: [keep: "KEY", drop: "shared/OTHER"])

        for bad in ["relative/key", "/opt/../etc/key", "/opt//key", env.root.appending(path: "bin/x").path(percentEncoded: false),
                    env.plistDirectory.appending(path: "x.plist").path(percentEncoded: false),
                    "/tmp/" + env.root.lastPathComponent + "/state.db"] {
            var invalid = spec
            invalid.secretFiles = [bad: "KEY"]
            do {
                _ = try await client.start(invalid)
                Issue.record("expected \(bad) to be refused")
            } catch let error as TenderClientError {
                #expect(error.code == "invalid_secret_file", "\(bad)")
            }
        }
        var malformed = spec
        malformed.secretFiles = [keep: "${secret:KEY}"]
        do {
            _ = try await client.start(malformed)
            Issue.record("expected a malformed file reference to be refused")
        } catch let error as TenderClientError {
            #expect(error.code == "invalid_secret_ref")
        }

        _ = try await client.start(spec)
        #expect(try await client.secrets().missing == ["files: KEY", "files: shared/OTHER"])
        // What `tenderd exec` would have written; MemoryLaunchd runs nothing.
        try SecretExec.writeFiles([(keep, SecretRef(name: "KEY")), (drop, SecretRef(name: "OTHER", shared: true))],
                                  secrets: ["KEY": "k", "shared/OTHER": "o"])
        spec.secretFiles = [keep: "KEY"]
        _ = try await client.start(spec)
        #expect(FileManager.default.fileExists(atPath: keep))
        #expect(!FileManager.default.fileExists(atPath: drop))
        _ = try await client.delete(service: "files")
        #expect(!FileManager.default.fileExists(atPath: keep))
    }
}

@Test func gcpReferencesNeedAProjectAndAFirstFetch() async throws {
    try await withSecretsDaemon { client, env async throws in
        var spec = ServiceSpec(name: "gcp", program: .executable("/bin/sleep"), arguments: ["1000"],
                               environment: ["P": "${secret:gcp:MONGO_PASSWORD}"])
        do {
            _ = try await client.start(spec)
            Issue.record("expected a reference without a project to be refused")
        } catch let error as TenderClientError {
            #expect(error.code == "invalid_secret_ref")
            #expect(error.description.contains("secrets.project"))
        }
        // No credentials on this node, so it can never be fetched: the spec isn't stored.
        spec.environment["P"] = "${secret:gcp:projects/olympsis-prod/secrets/MONGO_PASSWORD@2}"
        do {
            _ = try await client.start(spec)
            Issue.record("expected a secret never fetched to stop the start")
        } catch let error as TenderClientError {
            #expect(error.code == "secret_fetch_failed")
            #expect(error.description.contains("projects/olympsis-prod/secrets/MONGO_PASSWORD@2"))
            #expect(error.description.contains("roles/secretmanager.secretAccessor"))
            #expect(error.description.contains("tender credentials set"))
        }
        #expect(try await client.list().processes.isEmpty)

        try FileManager.default.createDirectory(at: env.configDirectory, withIntermediateDirectories: true)
        try Data(#"{"secrets":{"project":"olympsis-prod"}}"#.utf8).write(to: env.configDirectory.appending(path: "cloud.json"))
        spec.environment["P"] = "${secret:gcp:MONGO_PASSWORD}"
        do {
            _ = try await client.start(spec)
            Issue.record("expected a secret never fetched to stop the start")
        } catch let error as TenderClientError {
            #expect(error.code == "secret_fetch_failed")
            #expect(error.description.contains("projects/olympsis-prod/secrets/MONGO_PASSWORD@latest"))
        }
    }
}

// MARK: Real launchd

/// The `tenderd` that `swift build` made: beside the test bundle, which also finds it
/// under `--scratch-path`, or in this package's `.build`.
private let builtTenderd: String? = {
    let package = URL(filePath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    // The test bundle is a loaded image, whoever hosts it.
    let besideTests = (0..<_dyld_image_count()).compactMap { _dyld_get_image_name($0).map { String(cString: $0) } }
        .compactMap { image in image.range(of: ".xctest/").map { String(image[..<$0.lowerBound]) + ".xctest" } }
        .map { URL(filePath: $0).deletingLastPathComponent().appending(path: "tenderd").path(percentEncoded: false) }
    let candidates = besideTests + [package.appending(path: ".build/debug/tenderd").path(percentEncoded: false)]
    return candidates.first { FileManager.default.isExecutableFile(atPath: $0) }
}()

@Test(.enabled(if: builtTenderd != nil, "needs a built tenderd"))
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
    let files = try makeFilesDirectory()
    defer { try? FileManager.default.removeItem(at: files) }
    let keyFile = files.appending(path: "key.txt").path(percentEncoded: false)
    try store.upsert(ServiceSpec(
        name: "echo", program: .executable("/bin/sh"),
        arguments: ["-c", "printf '%s|%s' \"$TOKEN\" \"$(cat \(keyFile))\" > \(output.path(percentEncoded: false)); exec /bin/sleep 1000"],
        environment: ["TOKEN": "t=${secret:TOKEN}"],
        secretFiles: [keyFile: "KEY"]
    ))
    try vault.set(SecretName(service: "echo", name: "TOKEN"), value: Data("first".utf8))
    try vault.set(SecretName(service: "echo", name: "KEY"), value: Data("file-first".utf8))
    #expect(try await reconciler.reconcile().failures.isEmpty)

    func seen(_ expected: String) async throws -> Bool {
        for _ in 0..<100 {
            if (try? String(contentsOf: output, encoding: .utf8)) == expected { return true }
            try await Task.sleep(for: .milliseconds(100))
        }
        return false
    }
    #expect(try await seen("t=first|file-first"))
    #expect(try FileManager.default.attributesOfItem(atPath: keyFile)[.posixPermissions] as? Int == 0o400)
    let pid = try await launchctl.print(label: label)?.pid
    #expect(pid != nil)

    try vault.set(SecretName(service: "echo", name: "KEY"), value: Data("file-second".utf8))
    #expect(try await reconciler.reconcile().failures.isEmpty)
    #expect(try await seen("t=first|file-second"))
    try vault.set(SecretName(service: "echo", name: "TOKEN"), value: Data("second".utf8))
    #expect(try await reconciler.reconcile().failures.isEmpty)
    #expect(try await seen("t=second|file-second"))
    let plistData = try Data(contentsOf: env.plistPath(label: label))
    #expect(!String(decoding: plistData, as: UTF8.self).contains("second"))

    // A deleted file secret takes its file with it.
    try vault.delete(SecretName(service: "echo", name: "KEY"))
    #expect(try await reconciler.reconcile().failures.isEmpty)
    var exitCode: Int?
    for _ in 0..<100 {
        exitCode = try await launchctl.print(label: label)?.lastExitCode.map(Int.init)
        if exitCode == Int(SecretExec.configurationError) { break }
        try await Task.sleep(for: .milliseconds(100))
    }
    #expect(exitCode == Int(SecretExec.configurationError))
    #expect(!FileManager.default.fileExists(atPath: keyFile))

    try store.deleteService("echo")
    #expect(try await reconciler.reconcile().failures.isEmpty)
}
