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
