import Crypto
import _CryptoExtras
import Foundation
import TenderCore

/// HTTP, as a protocol so that tests never touch the network.
public protocol HTTPFetching: Sendable {
    func data(for request: URLRequest) async throws -> (Data, Int)
    /// Streams the body to a file, because release binaries can be large.
    func download(_ request: URLRequest, to destination: URL) async throws -> Int
    func upload(_ request: URLRequest, fromFile file: URL) async throws -> (Data, Int)
}

public struct URLSessionFetcher: HTTPFetching {
    public init() {}

    public func data(for request: URLRequest) async throws -> (Data, Int) {
        let (data, response) = try await URLSession.shared.data(for: request)
        return (data, (response as? HTTPURLResponse)?.statusCode ?? 0)
    }

    public func download(_ request: URLRequest, to destination: URL) async throws -> Int {
        let (temporary, response) = try await URLSession.shared.download(for: request)
        try? FileManager.default.removeItem(at: destination)
        try FileManager.default.moveItem(at: temporary, to: destination)
        return (response as? HTTPURLResponse)?.statusCode ?? 0
    }

    public func upload(_ request: URLRequest, fromFile file: URL) async throws -> (Data, Int) {
        let (data, response) = try await URLSession.shared.upload(for: request, fromFile: file)
        return (data, (response as? HTTPURLResponse)?.statusCode ?? 0)
    }
}

public enum CloudError: Error, Equatable, CustomStringConvertible {
    case noCredentials
    case invalidCredentials(String)
    case notConfigured(String)
    case http(status: Int, detail: String)
    case invalidVersion(String)
    case invalidManifest(String)
    case checksumMismatch(expected: String, found: String)

    public var description: String {
        switch self {
        case .noCredentials: "No GCP credentials on this node. Run `tender credentials set --file <key.json>`."
        case .invalidCredentials(let detail): "Those GCP credentials aren't usable: \(detail)"
        case .notConfigured(let what): "\(what) isn't configured in cloud.json on this node."
        case .http(let status, let detail): "Google Cloud returned HTTP \(status): \(detail)"
        case .invalidVersion(let version): "'\(version)' isn't a valid release version."
        case .invalidManifest(let detail): "Invalid release manifest: \(detail)"
        case .checksumMismatch(let expected, let found): "Checksum mismatch: expected \(expected), got \(found). Nothing was installed."
        }
    }
}

/// A GCP service account key. `token_uri` in the file is ignored: tokens only ever
/// go to Google's endpoint, whatever a tampered key file says.
public struct GoogleCredentials: Sendable {
    public static let secretName = "gcp.json"
    public static let tokenURL = URL(string: "https://oauth2.googleapis.com/token")!
    public let clientEmail: String
    private let key: _RSA.Signing.PrivateKey

    public init(json: Data) throws {
        guard let object = try? JSONSerialization.jsonObject(with: json) as? [String: Any] else {
            throw CloudError.invalidCredentials("not JSON")
        }
        guard object["type"] as? String == "service_account" else {
            throw CloudError.invalidCredentials("not a service account key")
        }
        guard let email = object["client_email"] as? String, let pem = object["private_key"] as? String else {
            throw CloudError.invalidCredentials("client_email or private_key is missing")
        }
        do {
            key = try _RSA.Signing.PrivateKey(pemRepresentation: pem)
        } catch {
            throw CloudError.invalidCredentials("private_key can't be read")
        }
        clientEmail = email
    }

    private static func base64URL(_ data: Data) -> String {
        data.base64EncodedString().replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
    }

    /// The signed assertion exchanged for an access token (RFC 7523).
    public func assertion(scope: String, now: Date = Date()) throws -> String {
        let issued = Int(now.timeIntervalSince1970)
        let header = try JSONSerialization.data(withJSONObject: ["alg": "RS256", "typ": "JWT"], options: .sortedKeys)
        let claims = try JSONSerialization.data(withJSONObject: [
            "iss": clientEmail, "scope": scope, "aud": Self.tokenURL.absoluteString,
            "iat": issued, "exp": issued + 3600,
        ] as [String: Any], options: .sortedKeys)
        let body = Self.base64URL(header) + "." + Self.base64URL(claims)
        let signature = try key.signature(for: Data(body.utf8), padding: .insecurePKCS1v1_5)
        return body + "." + Self.base64URL(signature.rawRepresentation)
    }
}

/// Exchanges a key for access tokens and caches them until shortly before they expire.
public actor GoogleTokenProvider {
    private let credentials: GoogleCredentials
    private let fetcher: any HTTPFetching
    private var cached: [String: (token: String, expires: Date)] = [:]

    public init(credentials: GoogleCredentials, fetcher: any HTTPFetching) {
        self.credentials = credentials
        self.fetcher = fetcher
    }

    public func token(scope: String, now: Date = Date()) async throws -> String {
        if let entry = cached[scope], entry.expires > now.addingTimeInterval(60) { return entry.token }
        var request = URLRequest(url: GoogleCredentials.tokenURL)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        let assertion = try credentials.assertion(scope: scope, now: now)
        request.httpBody = Data("grant_type=urn%3Aietf%3Aparams%3Aoauth%3Agrant-type%3Ajwt-bearer&assertion=\(assertion)".utf8)
        let (data, status) = try await fetcher.data(for: request)
        guard status == 200, let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let token = object["access_token"] as? String else {
            throw CloudError.http(status: status, detail: "couldn't get an access token")
        }
        let lifetime = object["expires_in"] as? TimeInterval ?? 3600
        cached[scope] = (token, now.addingTimeInterval(lifetime))
        return token
    }
}

/// What's in `<configDirectory>/cloud.json`. Credentials are separate, in the secret store.
public struct CloudConfig: Codable, Sendable, Equatable {
    public struct Offload: Codable, Sendable, Equatable {
        public var bucket: String
        public var prefix: String?
        public init(bucket: String, prefix: String? = nil) {
            self.bucket = bucket
            self.prefix = prefix
        }
    }

    public struct Releases: Codable, Sendable, Equatable {
        public enum Kind: String, Codable, Sendable { case gcs, artifactRegistry }
        public var kind: Kind
        public var bucket: String?
        public var prefix: String?
        public var project: String?
        public var location: String?
        public var repository: String?

        public init(kind: Kind, bucket: String? = nil, prefix: String? = nil, project: String? = nil,
                    location: String? = nil, repository: String? = nil) {
            self.kind = kind
            self.bucket = bucket
            self.prefix = prefix
            self.project = project
            self.location = location
            self.repository = repository
        }
    }

    public var offload: Offload?
    public var releases: Releases?

    public init(offload: Offload? = nil, releases: Releases? = nil) {
        self.offload = offload
        self.releases = releases
    }

    public static func load(environment: TenderEnvironment) -> CloudConfig {
        let url = environment.configDirectory.appending(path: "cloud.json")
        guard let data = try? Data(contentsOf: url) else { return CloudConfig() }
        return (try? JSONDecoder().decode(CloudConfig.self, from: data)) ?? CloudConfig()
    }
}

/// `{sha256, artifact}` beside each release in the bucket, written by CI.
public struct ReleaseManifest: Codable, Sendable, Equatable {
    public var sha256: String
    public var artifact: String?

    public init(sha256: String, artifact: String? = nil) {
        self.sha256 = sha256
        self.artifact = artifact
    }
}

/// Where binaries come from. An implementation only downloads. The caller verifies.
public protocol ReleaseSource: Sendable {
    /// Downloads to `destination` and returns the sha256 it must have, in lowercase hex.
    func fetch(service: String, version: String, to destination: URL) async throws -> String
}

func validateVersion(_ version: String) throws {
    let allowed = !version.isEmpty && version.count <= 128 && version.first != "." && !version.contains("..")
        && version.unicodeScalars.allSatisfy {
            switch $0 {
            case "a"..."z", "A"..."Z", "0"..."9", ".", "_", "-", "+": true
            default: false
            }
        }
    guard allowed else { throw CloudError.invalidVersion(version) }
}

private let unreserved = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-._~"))

private func escapedComponent(_ text: String) -> String {
    text.addingPercentEncoding(withAllowedCharacters: unreserved) ?? ""
}

private func isHexSHA256(_ text: String) -> Bool {
    text.count == 64 && text.allSatisfy { $0.isHexDigit }
}

/// `gs://<bucket>/<prefix>/<service>/<version>/manifest.json` beside the artifact.
public struct GCSReleaseSource: ReleaseSource {
    static let readScope = "https://www.googleapis.com/auth/devstorage.read_only"
    let bucket: String
    let prefix: String?
    let tokens: GoogleTokenProvider
    let fetcher: any HTTPFetching

    public init(bucket: String, prefix: String?, tokens: GoogleTokenProvider, fetcher: any HTTPFetching) {
        self.bucket = bucket
        self.prefix = prefix
        self.tokens = tokens
        self.fetcher = fetcher
    }

    private func objectRequest(_ name: String) async throws -> URLRequest {
        let url = URL(string: "https://storage.googleapis.com/storage/v1/b/\(escapedComponent(bucket))/o/\(escapedComponent(name))?alt=media")!
        var request = URLRequest(url: url)
        request.setValue("Bearer \(try await tokens.token(scope: Self.readScope))", forHTTPHeaderField: "Authorization")
        return request
    }

    public func fetch(service: String, version: String, to destination: URL) async throws -> String {
        try validateVersion(version)
        let base = ([prefix, service, version].compactMap { $0 }).joined(separator: "/")
        let (data, status) = try await fetcher.data(for: try await objectRequest("\(base)/manifest.json"))
        guard status == 200 else { throw CloudError.http(status: status, detail: "\(base)/manifest.json") }
        guard let manifest = try? JSONDecoder().decode(ReleaseManifest.self, from: data) else {
            throw CloudError.invalidManifest("not JSON")
        }
        guard isHexSHA256(manifest.sha256) else { throw CloudError.invalidManifest("sha256 isn't 64 hex digits") }
        let artifact = manifest.artifact ?? service
        guard !artifact.isEmpty, !artifact.contains("/"), !artifact.contains("..") else {
            throw CloudError.invalidManifest("artifact must be a file name beside the manifest")
        }
        let download = try await fetcher.download(try await objectRequest("\(base)/\(artifact)"), to: destination)
        guard download == 200 else { throw CloudError.http(status: download, detail: "\(base)/\(artifact)") }
        return manifest.sha256.lowercased()
    }
}

/// A generic Artifact Registry repository: package = service, file = service.
public struct ArtifactRegistryReleaseSource: ReleaseSource {
    static let readScope = "https://www.googleapis.com/auth/cloud-platform.read-only"
    let project: String
    let location: String
    let repository: String
    let tokens: GoogleTokenProvider
    let fetcher: any HTTPFetching

    public init(project: String, location: String, repository: String, tokens: GoogleTokenProvider, fetcher: any HTTPFetching) {
        self.project = project
        self.location = location
        self.repository = repository
        self.tokens = tokens
        self.fetcher = fetcher
    }

    public func fetch(service: String, version: String, to destination: URL) async throws -> String {
        try validateVersion(version)
        let file = escapedComponent("\(service):\(version):\(service)")
        let parent = "projects/\(escapedComponent(project))/locations/\(escapedComponent(location))/repositories/\(escapedComponent(repository))/files/\(file)"
        let token = try await tokens.token(scope: Self.readScope)

        var metadata = URLRequest(url: URL(string: "https://artifactregistry.googleapis.com/v1/\(parent)")!)
        metadata.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        let (data, status) = try await fetcher.data(for: metadata)
        guard status == 200 else { throw CloudError.http(status: status, detail: "\(service):\(version)") }
        guard let sha = Self.sha256(fromFileMetadata: data) else {
            throw CloudError.invalidManifest("the registry reports no SHA256 for \(service):\(version)")
        }

        var request = URLRequest(url: URL(string: "https://artifactregistry.googleapis.com/download/v1/\(parent):download?alt=media")!)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        let download = try await fetcher.download(request, to: destination)
        guard download == 200 else { throw CloudError.http(status: download, detail: "\(service):\(version)") }
        return sha
    }

    /// `hashes: [{type: "SHA256", value: <base64>}]`. Hex is accepted too.
    static func sha256(fromFileMetadata data: Data) -> String? {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let hashes = object["hashes"] as? [[String: Any]],
              let value = hashes.first(where: { $0["type"] as? String == "SHA256" })?["value"] as? String
        else { return nil }
        if isHexSHA256(value) { return value.lowercased() }
        guard let raw = Data(base64Encoded: value), raw.count == 32 else { return nil }
        return raw.map { String(format: "%02x", $0) }.joined()
    }
}

/// Uploads closed log files and audit logs. Implemented by GCS, and by a fake in tests.
public protocol BlobUploader: Sendable {
    func upload(file: URL, as name: String) async throws
}

public struct GCSUploader: BlobUploader {
    static let writeScope = "https://www.googleapis.com/auth/devstorage.read_write"
    let bucket: String
    let prefix: String?
    let tokens: GoogleTokenProvider
    let fetcher: any HTTPFetching

    public init(bucket: String, prefix: String?, tokens: GoogleTokenProvider, fetcher: any HTTPFetching) {
        self.bucket = bucket
        self.prefix = prefix
        self.tokens = tokens
        self.fetcher = fetcher
    }

    public func upload(file: URL, as name: String) async throws {
        let object = ([prefix, name].compactMap { $0 }).joined(separator: "/")
        let url = URL(string: "https://storage.googleapis.com/upload/storage/v1/b/\(escapedComponent(bucket))/o?uploadType=media&name=\(escapedComponent(object))")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(try await tokens.token(scope: Self.writeScope))", forHTTPHeaderField: "Authorization")
        let (_, status) = try await fetcher.upload(request, fromFile: file)
        guard (200..<300).contains(status) else { throw CloudError.http(status: status, detail: object) }
    }
}

/// Builds cloud clients from a node's config and credentials, on demand, so that adding
/// either one doesn't need a daemon restart.
public struct CloudServices: Sendable {
    public let environment: TenderEnvironment
    public let secrets: any SecretStore
    public let fetcher: any HTTPFetching

    public init(environment: TenderEnvironment, secrets: any SecretStore, fetcher: any HTTPFetching = URLSessionFetcher()) {
        self.environment = environment
        self.secrets = secrets
        self.fetcher = fetcher
    }

    private func tokens() throws -> GoogleTokenProvider {
        guard let json = try secrets.read(GoogleCredentials.secretName) else { throw CloudError.noCredentials }
        return GoogleTokenProvider(credentials: try GoogleCredentials(json: json), fetcher: fetcher)
    }

    public func releaseSource() throws -> any ReleaseSource {
        guard let config = CloudConfig.load(environment: environment).releases else {
            throw CloudError.notConfigured("A release source")
        }
        switch config.kind {
        case .gcs:
            guard let bucket = config.bucket else { throw CloudError.notConfigured("releases.bucket") }
            return GCSReleaseSource(bucket: bucket, prefix: config.prefix, tokens: try tokens(), fetcher: fetcher)
        case .artifactRegistry:
            guard let project = config.project, let location = config.location, let repository = config.repository else {
                throw CloudError.notConfigured("releases.project, location or repository")
            }
            return ArtifactRegistryReleaseSource(project: project, location: location, repository: repository,
                                                 tokens: try tokens(), fetcher: fetcher)
        }
    }

    /// Nil when offload isn't configured, which is a normal way to run.
    public func uploader() throws -> (any BlobUploader)? {
        guard let config = CloudConfig.load(environment: environment).offload else { return nil }
        return GCSUploader(bucket: config.bucket, prefix: config.prefix, tokens: try tokens(), fetcher: fetcher)
    }
}
