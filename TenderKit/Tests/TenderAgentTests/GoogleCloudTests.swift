import Crypto
import _CryptoExtras
import Foundation
import Testing
import TenderCore
@testable import TenderAgent

/// Records requests and answers from a table of URL substrings.
final class FakeFetcher: HTTPFetching, @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [URLRequest] = []
    var responses: [(match: String, data: Data, status: Int)] = []
    var uploads: [(url: URL, bytes: Data)] = []

    var requests: [URLRequest] { lock.withLock { recorded } }

    private func answer(_ request: URLRequest) -> (Data, Int) {
        lock.withLock {
            recorded.append(request)
            let url = request.url?.absoluteString ?? ""
            return responses.first { url.contains($0.match) }.map { ($0.data, $0.status) } ?? (Data("no route".utf8), 404)
        }
    }

    func data(for request: URLRequest) async throws -> (Data, Int) { answer(request) }

    func download(_ request: URLRequest, to destination: URL) async throws -> Int {
        let (data, status) = answer(request)
        try data.write(to: destination)
        return status
    }

    func upload(_ request: URLRequest, fromFile file: URL) async throws -> (Data, Int) {
        let (data, status) = answer(request)
        let bytes = try Data(contentsOf: file)
        lock.withLock { uploads.append((request.url!, bytes)) }
        return (data, status)
    }
}

private func keyJSON(_ key: _RSA.Signing.PrivateKey, tokenURI: String = "https://evil.example/token") -> Data {
    try! JSONSerialization.data(withJSONObject: [
        "type": "service_account", "client_email": "ci@p.iam.gserviceaccount.com",
        "private_key": key.pemRepresentation, "token_uri": tokenURI,
    ])
}

private let tokenResponse = (match: "oauth2.googleapis.com", data: Data(#"{"access_token":"T0K","expires_in":3600}"#.utf8), status: 200)

private func provider(_ fetcher: FakeFetcher) throws -> GoogleTokenProvider {
    GoogleTokenProvider(credentials: try GoogleCredentials(json: keyJSON(try _RSA.Signing.PrivateKey(keySize: .bits2048))), fetcher: fetcher)
}

private func sha256Hex(_ data: Data) -> String {
    SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
}

private func tempFile() -> URL { URL(filePath: "/tmp/tender-test-\(UUID().uuidString.prefix(8))") }

@Test func assertionIsAVerifiableRS256JWT() throws {
    let key = try _RSA.Signing.PrivateKey(keySize: .bits2048)
    let credentials = try GoogleCredentials(json: keyJSON(key))
    let token = try credentials.assertion(scope: "s", now: Date(timeIntervalSince1970: 1000))
    let parts = token.split(separator: ".").map(String.init)
    #expect(parts.count == 3)
    func decode(_ text: String) -> Data {
        var base = text.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        while base.count % 4 != 0 { base += "=" }
        return Data(base64Encoded: base)!
    }
    let claims = try #require(try JSONSerialization.jsonObject(with: decode(parts[1])) as? [String: Any])
    #expect(claims["iss"] as? String == "ci@p.iam.gserviceaccount.com")
    #expect(claims["aud"] as? String == "https://oauth2.googleapis.com/token")
    #expect(claims["exp"] as? Int == 4600)
    let signature = _RSA.Signing.RSASignature(rawRepresentation: decode(parts[2]))
    #expect(key.publicKey.isValidSignature(signature, for: Data("\(parts[0]).\(parts[1])".utf8), padding: .insecurePKCS1v1_5))
}

@Test func tokensGoOnlyToGoogleAndAreCached() async throws {
    let fetcher = FakeFetcher()
    fetcher.responses = [tokenResponse]
    let tokens = try provider(fetcher)
    let now = Date()
    #expect(try await tokens.token(scope: "s", now: now) == "T0K")
    #expect(try await tokens.token(scope: "s", now: now.addingTimeInterval(100)) == "T0K")
    #expect(fetcher.requests.count == 1)
    #expect(fetcher.requests.first?.url?.host == "oauth2.googleapis.com", "a token_uri in the key file must be ignored")
    _ = try await tokens.token(scope: "s", now: now.addingTimeInterval(3590))
    #expect(fetcher.requests.count == 2, "refreshes before expiry")
}

@Test(arguments: [#"{}"#, "nope", #"{"type":"service_account"}"#, #"{"type":"user","client_email":"a","private_key":"b"}"#,
                  #"{"type":"service_account","client_email":"a","private_key":"not a key"}"#])
func badCredentialsAreRefused(json: String) {
    #expect(throws: CloudError.self) { try GoogleCredentials(json: Data(json.utf8)) }
}

@Test func gcsSourceReadsManifestThenArtifact() async throws {
    let fetcher = FakeFetcher()
    let binary = Data("binary".utf8)
    fetcher.responses = [tokenResponse,
                         ("manifest.json", try JSONEncoder().encode(ReleaseManifest(sha256: sha256Hex(binary), artifact: "api-bin")), 200),
                         ("api-bin", binary, 200)]
    let source = GCSReleaseSource(bucket: "b", prefix: "rel", tokens: try provider(fetcher), fetcher: fetcher)
    let file = tempFile()
    defer { try? FileManager.default.removeItem(at: file) }
    #expect(try await source.fetch(service: "api", version: "1.2.3", to: file) == sha256Hex(binary))
    #expect(try Data(contentsOf: file) == binary)
    let urls = fetcher.requests.compactMap { $0.url?.absoluteString }
    #expect(urls.contains { $0.contains("/b/b/o/rel%2Fapi%2F1.2.3%2Fmanifest.json?alt=media") })
    #expect(fetcher.requests.last?.value(forHTTPHeaderField: "Authorization") == "Bearer T0K")
}

@Test(arguments: ["../../etc/passwd", "..", "a/b", "", ".hidden", "a b", "a?x=1", "a%2fb", String(repeating: "x", count: 129)])
func unsafeVersionsAreRefusedBeforeAnyRequest(version: String) async throws {
    let fetcher = FakeFetcher()
    let source = GCSReleaseSource(bucket: "b", prefix: nil, tokens: try provider(fetcher), fetcher: fetcher)
    await #expect(throws: CloudError.invalidVersion(version)) {
        _ = try await source.fetch(service: "api", version: version, to: tempFile())
    }
    #expect(fetcher.requests.isEmpty)
}

@Test(arguments: [#"{"sha256":"short"}"#, #"{}"#, "garbage",
                  "{\"sha256\":\"\(String(repeating: "a", count: 64))\",\"artifact\":\"../../other\"}",
                  "{\"sha256\":\"\(String(repeating: "a", count: 64))\",\"artifact\":\"a/b\"}"])
func badManifestsAreRefused(manifest: String) async throws {
    let fetcher = FakeFetcher()
    fetcher.responses = [tokenResponse, ("manifest.json", Data(manifest.utf8), 200)]
    let source = GCSReleaseSource(bucket: "b", prefix: nil, tokens: try provider(fetcher), fetcher: fetcher)
    await #expect(throws: CloudError.self) { _ = try await source.fetch(service: "api", version: "1", to: tempFile()) }
    #expect(fetcher.requests.count == 2, "must stop before downloading anything")
}

@Test func artifactRegistrySourceUsesTheHashFromMetadata() async throws {
    let fetcher = FakeFetcher()
    let binary = Data("binary".utf8)
    let base64 = Data(SHA256.hash(data: binary)).base64EncodedString()
    fetcher.responses = [tokenResponse,
                         (":download", binary, 200),
                         ("/files/api%3A1.0%3Aapi", Data(#"{"hashes":[{"type":"MD5","value":"x"},{"type":"SHA256","value":"\#(base64)"}]}"#.utf8), 200)]
    let source = ArtifactRegistryReleaseSource(project: "p", location: "us", repository: "r", tokens: try provider(fetcher), fetcher: fetcher)
    let file = tempFile()
    defer { try? FileManager.default.removeItem(at: file) }
    #expect(try await source.fetch(service: "api", version: "1.0", to: file) == sha256Hex(binary))

    #expect(ArtifactRegistryReleaseSource.sha256(fromFileMetadata: Data(#"{"hashes":[{"type":"MD5","value":"x"}]}"#.utf8)) == nil)
    let hex = String(repeating: "A", count: 64)
    #expect(ArtifactRegistryReleaseSource.sha256(fromFileMetadata: Data(#"{"hashes":[{"type":"SHA256","value":"\#(hex)"}]}"#.utf8)) == hex.lowercased())
}

@Test func uploaderSendsTheFileWithAPrefixedName() async throws {
    let fetcher = FakeFetcher()
    fetcher.responses = [tokenResponse, ("upload/storage", Data("{}".utf8), 200)]
    let file = tempFile()
    try Data("logs".utf8).write(to: file)
    defer { try? FileManager.default.removeItem(at: file) }
    try await GCSUploader(bucket: "b", prefix: "cluster", tokens: try provider(fetcher), fetcher: fetcher)
        .upload(file: file, as: "logs/logs-2026-01-01.db")
    let upload = try #require(fetcher.uploads.first)
    #expect(upload.url.absoluteString.contains("name=cluster%2Flogs%2Flogs-2026-01-01.db"))
    #expect(upload.bytes == Data("logs".utf8))
}

@Test func uploadFailureIsReported() async throws {
    let fetcher = FakeFetcher()
    fetcher.responses = [tokenResponse, ("upload/storage", Data(), 403)]
    let file = tempFile()
    try Data("x".utf8).write(to: file)
    defer { try? FileManager.default.removeItem(at: file) }
    await #expect(throws: CloudError.http(status: 403, detail: "n")) {
        try await GCSUploader(bucket: "b", prefix: nil, tokens: try provider(fetcher), fetcher: fetcher).upload(file: file, as: "n")
    }
}

// MARK: Installing

private struct Harness {
    let env: TenderEnvironment
    let store: StateStore
    let launchd = MemoryLaunchd()
    let manager: ReleaseManager

    init() throws {
        env = try makeTestEnvironment()
        store = try StateStore(environment: env)
        manager = ReleaseManager(environment: env, store: store,
                                 reconciler: Reconciler(environment: env, store: store, launchd: launchd))
    }

    func download(_ contents: Data) throws -> URL {
        let directory = env.releasesDirectory.appending(path: "api")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let file = directory.appending(path: ".download-x")
        try contents.write(to: file)
        return file
    }
}

@Test func installVerifiesStripsQuarantineAndDeploys() async throws {
    let h = try Harness()
    defer { try? FileManager.default.removeItem(at: h.env.root) }
    try h.store.upsert(ServiceSpec(name: "api", program: .executable("/bin/sleep")))
    let binary = Data("#!/bin/sh\n".utf8)
    let file = try h.download(binary)
    let value = "0081;00000000;Safari;"
    #expect(setxattr(file.path(percentEncoded: false), "com.apple.quarantine", value, value.utf8.count, 0, 0) == 0)

    let sha12 = try await h.manager.installFetched(file: file, service: "api", expectedSHA256: sha256Hex(binary))
    let installed = h.env.releaseBinary(service: "api", sha12: sha12).path(percentEncoded: false)
    #expect(FileManager.default.isExecutableFile(atPath: installed))
    #expect(getxattr(installed, "com.apple.quarantine", nil, 0, 0, 0) == -1, "quarantine must be gone")
    #expect(try h.store.service("api")?.spec.program == .release(sha12: sha12))
    #expect(try await h.manager.list(service: "api").current == sha12)
}

@Test func checksumMismatchInstallsNothing() async throws {
    let h = try Harness()
    defer { try? FileManager.default.removeItem(at: h.env.root) }
    try h.store.upsert(ServiceSpec(name: "api", program: .executable("/bin/sleep")))
    let file = try h.download(Data("tampered".utf8))
    await #expect(throws: CloudError.self) {
        _ = try await h.manager.installFetched(file: file, service: "api", expectedSHA256: String(repeating: "0", count: 64))
    }
    #expect(try await h.manager.list(service: "api").releases.isEmpty)
    #expect(try h.store.service("api")?.spec.program == .executable("/bin/sleep"))
}

// MARK: GCP Secret Manager

private let secretVersion = GCPSecretVersion(project: "olympsis-prod", secret: "MONGO_PASSWORD", version: "latest")

private func accessResponse(_ value: String, version: Int, crc: UInt32? = nil, project: String = "123456") -> Data {
    let data = Data(value.utf8)
    return try! JSONSerialization.data(withJSONObject: [
        "name": "projects/\(project)/secrets/MONGO_PASSWORD/versions/\(version)",
        "payload": ["data": data.base64EncodedString(), "dataCrc32c": String(crc ?? CRC32C.checksum(data))],
    ])
}

private func secretRoute(_ value: String, version: Int, path: String = "secrets/MONGO_PASSWORD/versions/latest:access",
                         status: Int = 200, crc: UInt32? = nil) -> (match: String, data: Data, status: Int) {
    (path, accessResponse(value, version: version, crc: crc), status)
}

@Test func crc32cIsCastagnoli() {
    #expect(CRC32C.checksum(Data("123456789".utf8)) == 0xE306_9283)
    #expect(CRC32C.checksum(Data()) == 0)
    #expect(CRC32C.checksum(Data(repeating: 0, count: 32)) == 0x8A91_36AA)
}

@Test func secretSourceReadsAVersionAndVerifiesItsChecksum() async throws {
    let fetcher = FakeFetcher()
    fetcher.responses = [tokenResponse, secretRoute("hunter2", version: 7)]
    let source = GCPSecretSource(tokens: try provider(fetcher), fetcher: fetcher)
    let fetched = try await source.access(secretVersion)
    #expect(fetched.value == Data("hunter2".utf8))
    #expect(fetched.version == "7")
    let request = try #require(fetcher.requests.last)
    #expect(request.url?.absoluteString
        == "https://secretmanager.googleapis.com/v1/projects/olympsis-prod/secrets/MONGO_PASSWORD/versions/latest:access")
    #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer T0K")
    #expect(request.timeoutInterval <= 10)
    let scope = String(decoding: try #require(fetcher.requests.first?.httpBody), as: UTF8.self)
    #expect(scope.contains("assertion="))
}

@Test func secretSourceRefusesACorruptedPayload() async throws {
    let fetcher = FakeFetcher()
    fetcher.responses = [tokenResponse, secretRoute("hunter2", version: 7, crc: 12345)]
    let source = GCPSecretSource(tokens: try provider(fetcher), fetcher: fetcher)
    await #expect(throws: SecretFetchError.checksumMismatch(secretVersion)) { try await source.access(secretVersion) }

    let noChecksum = try JSONSerialization.data(withJSONObject: ["name": "projects/1/secrets/MONGO_PASSWORD/versions/1",
                                                                 "payload": ["data": Data("x".utf8).base64EncodedString()]])
    fetcher.responses = [tokenResponse, ("secretmanager", noChecksum, 200)]
    await #expect(throws: SecretFetchError.invalidResponse(secretVersion, "no dataCrc32c")) { try await source.access(secretVersion) }
}

@Test func deniedAndMissingSecretsNameTheSecretAndTheRole() async throws {
    let fetcher = FakeFetcher()
    let source = GCPSecretSource(tokens: try provider(fetcher), fetcher: fetcher)
    // The body of an error is never repeated: for an access call, a body can be the value.
    fetcher.responses = [tokenResponse, ("secretmanager", Data(#"{"error":{"message":"hunter2"}}"#.utf8), 403)]
    do {
        _ = try await source.access(secretVersion)
        Issue.record("expected a 403 to throw")
    } catch let error as SecretFetchError {
        #expect(error == .denied(secretVersion, account: "ci@p.iam.gserviceaccount.com"))
        #expect(error.description.contains("roles/secretmanager.secretAccessor"))
        #expect(error.description.contains("projects/olympsis-prod/secrets/MONGO_PASSWORD@latest"))
        #expect(error.description.contains("ci@p.iam.gserviceaccount.com"))
        #expect(!error.description.contains("hunter2"))
    }
    fetcher.responses = [tokenResponse, ("secretmanager", Data(), 404)]
    do {
        _ = try await source.access(secretVersion)
        Issue.record("expected a 404 to throw")
    } catch let error as SecretFetchError {
        #expect(error == .notFound(secretVersion))
        #expect(error.description.contains("roles/secretmanager.secretAccessor"))
    }
    fetcher.responses = [tokenResponse, ("secretmanager", Data(), 503)]
    await #expect(throws: SecretFetchError.http(secretVersion, status: 503)) { try await source.access(secretVersion) }
}

private struct GCPFixture {
    let env: TenderEnvironment
    let store: StateStore
    let vault: SecretVault
    let sync: GCPSecretSync
    let fetcher: FakeFetcher

    init(project: String? = "olympsis-prod") throws {
        env = try makeTestEnvironment()
        store = try StateStore(environment: env)
        vault = SecretVault(secrets: env.makeSecretStore(), store: store, gcpProject: { project })
        let fetcher = FakeFetcher()
        let tokens = try provider(fetcher)
        sync = GCPSecretSync(vault: vault, source: { GCPSecretSource(tokens: tokens, fetcher: fetcher) })
        self.fetcher = fetcher
    }

    func accesses() -> Int { fetcher.requests.filter { $0.url?.host == "secretmanager.googleapis.com" }.count }
}

private let gcpSpec = ServiceSpec(
    name: "api", program: .executable("/bin/sleep"), arguments: ["--pin=${secret:gcp:projects/other/secrets/PIN@3}"],
    environment: ["MONGO_URL": "mongodb://app:${secret:gcp:MONGO_PASSWORD}@db"]
)

@Test func latestIsRecheckedAndANewValueBumpsTheRevision() async throws {
    let fixture = try GCPFixture()
    defer { try? FileManager.default.removeItem(at: fixture.env.root) }
    fixture.fetcher.responses = [tokenResponse, secretRoute("first", version: 1),
                                 secretRoute("pin", version: 3, path: "projects/other/secrets/PIN/versions/3:access")]
    let start = Date()
    #expect(await fixture.sync.refresh([gcpSpec], now: start).isEmpty)
    #expect(fixture.accesses() == 2)
    let first = try fixture.vault.revisionTag(for: gcpSpec)
    #expect(try fixture.vault.missing(for: gcpSpec).isEmpty)

    // Within five minutes nothing is fetched again, and a pinned version never is.
    await fixture.sync.refresh([gcpSpec], now: start.addingTimeInterval(60))
    #expect(fixture.accesses() == 2)
    await fixture.sync.refresh([gcpSpec], force: true, now: start.addingTimeInterval(61))
    #expect(fixture.accesses() == 3, "a start re-checks latest, not the pinned version")

    // The same value under a new version changes nothing.
    fixture.fetcher.responses[1] = secretRoute("first", version: 2)
    await fixture.sync.refresh([gcpSpec], now: start.addingTimeInterval(400))
    #expect(try fixture.vault.revisionTag(for: gcpSpec) == first)

    fixture.fetcher.responses[1] = secretRoute("second", version: 3)
    await fixture.sync.refresh([gcpSpec], now: start.addingTimeInterval(800))
    #expect(fixture.accesses() == 5)
    let second = try fixture.vault.revisionTag(for: gcpSpec)
    #expect(second != first)
    #expect(try fixture.vault.value(item: secretVersion.itemName) == "second")

    let infos = await fixture.sync.infos(for: [gcpSpec], node: NodeID("mac-1"))
    #expect(infos.map(\.name) == ["projects/olympsis-prod/secrets/MONGO_PASSWORD@latest", "projects/other/secrets/PIN@3"])
    #expect(infos.first?.version == "3")
    #expect(infos.allSatisfy { $0.cached && !$0.stale && $0.usedBy == ["api"] })
}

@Test func anOutageServesTheCacheAndReportsItStale() async throws {
    let fixture = try GCPFixture()
    defer { try? FileManager.default.removeItem(at: fixture.env.root) }
    let spec = ServiceSpec(name: "api", program: .executable("/bin/sleep"), environment: ["P": "${secret:gcp:MONGO_PASSWORD}"])
    fixture.fetcher.responses = [tokenResponse, secretRoute("s3cr3t-value", version: 1)]
    let start = Date()
    #expect(await fixture.sync.refresh([spec], now: start).isEmpty)
    let revision = try fixture.vault.revisionTag(for: spec)

    fixture.fetcher.responses = [tokenResponse, ("secretmanager", Data(), 503)]
    let failures = await fixture.sync.refresh([spec], force: true, now: start.addingTimeInterval(10))
    #expect(failures[secretVersion] == .http(secretVersion, status: 503))
    #expect(await fixture.sync.fetchErrors == 1)
    #expect(try fixture.vault.revisionTag(for: spec) == revision, "an outage doesn't restart anything")

    // Instances still start from the cache.
    try SecretMaterializer(environment: fixture.env, vault: fixture.vault).materialize(spec)
    #expect(try SecretExec.loadSecrets(file: fixture.env.serviceSecretsFile(service: "api")) == ["gcp:MONGO_PASSWORD": "s3cr3t-value"])
    let info = try #require(await fixture.sync.infos(for: [spec], node: NodeID("n")).first)
    #expect(info.stale && info.cached)
    #expect(info.fetchError == "Google Cloud returned HTTP 503 for projects/olympsis-prod/secrets/MONGO_PASSWORD@latest.")
    #expect(!String(decoding: try JSONEncoder().encode(info), as: UTF8.self).contains("s3cr3t-value"), "no value in the list")

    // Failures back off instead of hitting Google on every sweep.
    await fixture.sync.refresh([spec], now: start.addingTimeInterval(400))
    await fixture.sync.refresh([spec], now: start.addingTimeInterval(405))
    #expect(await fixture.sync.fetchErrors == 2)

    fixture.fetcher.responses = [tokenResponse, secretRoute("s3cr3t-value", version: 1)]
    await fixture.sync.refresh([spec], now: start.addingTimeInterval(800))
    #expect(await fixture.sync.infos(for: [spec], node: NodeID("n")).first?.stale == false)
}

@Test func aSecretNeverFetchedIsMissingAndPrunedWhenUnused() async throws {
    let fixture = try GCPFixture()
    defer { try? FileManager.default.removeItem(at: fixture.env.root) }
    let spec = ServiceSpec(name: "api", program: .executable("/bin/sleep"), environment: ["P": "${secret:gcp:MONGO_PASSWORD}"])
    fixture.fetcher.responses = [tokenResponse]
    let start = Date()
    #expect(await fixture.sync.refresh([spec], now: start)[secretVersion] == .notFound(secretVersion))
    #expect(try fixture.vault.missing(for: spec).map(\.description) == ["gcp:MONGO_PASSWORD"])
    try SecretMaterializer(environment: fixture.env, vault: fixture.vault).materialize(spec)
    #expect(try SecretExec.loadSecrets(file: fixture.env.serviceSecretsFile(service: "api")).isEmpty)
    let info = try #require(await fixture.sync.infos(for: [spec], node: NodeID("n")).first)
    #expect(!info.cached && !info.stale && info.fetchError?.contains("roles/secretmanager.secretAccessor") == true)

    fixture.fetcher.responses = [tokenResponse, secretRoute("v", version: 1)]
    await fixture.sync.refresh([spec], now: start.addingTimeInterval(5))
    #expect(fixture.accesses() == 1, "a sweep inside the retry interval leaves it")
    #expect(await fixture.sync.refresh([spec], force: true, now: start.addingTimeInterval(6)).isEmpty)
    #expect(try fixture.vault.cachedGCPItems() == [secretVersion.itemName])

    // Recently fetched values survive a prune, for a start that hasn't stored its spec yet.
    await fixture.sync.prune(keeping: [], now: start.addingTimeInterval(60))
    #expect(try fixture.vault.cachedGCPItems() == [secretVersion.itemName])
    await fixture.sync.prune(keeping: [spec], now: start.addingTimeInterval(3600))
    #expect(try fixture.vault.cachedGCPItems() == [secretVersion.itemName])
    await fixture.sync.prune(keeping: [], now: start.addingTimeInterval(3600))
    #expect(try fixture.vault.cachedGCPItems().isEmpty)
}

@Test func withoutCredentialsEveryReferenceFailsWithTheSetupStep() async throws {
    let env = try makeTestEnvironment()
    defer { try? FileManager.default.removeItem(at: env.root) }
    let store = try StateStore(environment: env)
    let vault = SecretVault(secrets: env.makeSecretStore(), store: store, gcpProject: { "p" })
    let cloud = CloudServices(environment: env, secrets: env.makeSecretStore(), fetcher: FakeFetcher())
    let sync = GCPSecretSync(vault: vault, source: { try cloud.secretSource() })
    let failures = await sync.refresh([gcpSpec])
    #expect(failures.count == 2)
    #expect(failures.values.allSatisfy { $0.description.contains("tender credentials set") })
}

@Test func cloudConfigReadsTheDefaultSecretsProject() throws {
    let env = try makeTestEnvironment()
    defer { try? FileManager.default.removeItem(at: env.root) }
    try FileManager.default.createDirectory(at: env.configDirectory, withIntermediateDirectories: true)
    try Data(#"{"secrets":{"project":"olympsis-prod"}}"#.utf8).write(to: env.configDirectory.appending(path: "cloud.json"))
    let cloud = CloudServices(environment: env, secrets: env.makeSecretStore())
    #expect(cloud.defaultSecretsProject() == "olympsis-prod")
    #expect(CloudConfig.load(environment: env).releases == nil)
}
