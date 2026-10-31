import Foundation
import Security
import TenderCore
import TenderPKI

public enum JoinError: Error, Equatable, CustomStringConvertible {
    case invalidToken
    case fingerprintMismatch(expected: String, found: String)
    case refused(String)
    case alreadyJoined(String)

    public var description: String {
        switch self {
        case .invalidToken: "That join token isn't valid. Create one with `tender token create` on the head."
        case .fingerprintMismatch(let expected, let found):
            "The head's CA fingerprint is \(found), but the token expects \(expected). This may not be your head."
        case .refused(let message): "The head refused to let this node join: \(message)"
        case .alreadyJoined(let head): "This node has already joined \(head)."
        }
    }
}

/// A node's first contact with its head. The first request is unauthenticated on
/// purpose: it fetches the CA, which is only trusted if it matches the fingerprint
/// in the token. From then on the connection is pinned to that CA.
public struct JoinClient: Sendable {
    public init() {}

    private final class PinningDelegate: NSObject, URLSessionDelegate {
        let anchor: SecCertificate?
        init(anchor: SecCertificate?) { self.anchor = anchor }

        func urlSession(_ session: URLSession, didReceive challenge: URLAuthenticationChallenge,
                        completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
            guard challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
                  let trust = challenge.protectionSpace.serverTrust else {
                return completionHandler(.performDefaultHandling, nil)
            }
            guard let anchor else {
                // Fetching the CA: nothing is trusted until its fingerprint has been checked.
                return completionHandler(.useCredential, URLCredential(trust: trust))
            }
            SecTrustSetPolicies(trust, SecPolicyCreateBasicX509())
            SecTrustSetAnchorCertificates(trust, [anchor] as CFArray)
            SecTrustSetAnchorCertificatesOnly(trust, true)
            guard SecTrustEvaluateWithError(trust, nil) else {
                return completionHandler(.cancelAuthenticationChallenge, nil)
            }
            completionHandler(.useCredential, URLCredential(trust: trust))
        }
    }

    private static func certificate(fromPEM pem: String) -> SecCertificate? {
        let base64 = pem.split(whereSeparator: \.isNewline).filter { !$0.hasPrefix("-----") }.joined()
        return Data(base64Encoded: base64).flatMap { SecCertificateCreateWithData(nil, $0 as CFData) }
    }

    public func join(head: String, token: String, nodeID: NodeID, defaultAPIPort: Int = 7071,
                     key: NodeKey) async throws -> JoinResponse {
        guard let parsed = JoinToken(parsing: token) else { throw JoinError.invalidToken }
        let (host, port) = splitHostPort(head, defaultPort: defaultAPIPort)
        guard let base = URL(string: "https://\(host):\(port)") else { throw JoinError.refused("bad address \(head)") }

        let probe = URLSession(configuration: .ephemeral, delegate: PinningDelegate(anchor: nil), delegateQueue: nil)
        defer { probe.finishTasksAndInvalidate() }
        let (caData, _) = try await probe.data(from: base.appending(path: "v1/ca"))
        let caPEM = String(decoding: caData, as: UTF8.self)
        let found = CertificateAuthority.fingerprint(ofPEM: caPEM) ?? "unreadable"
        guard found == parsed.caFingerprint else {
            throw JoinError.fingerprintMismatch(expected: parsed.caFingerprint, found: found)
        }
        guard let anchor = Self.certificate(fromPEM: caPEM) else { throw JoinError.refused("unreadable CA") }

        let session = URLSession(configuration: .ephemeral, delegate: PinningDelegate(anchor: anchor), delegateQueue: nil)
        defer { session.finishTasksAndInvalidate() }
        var request = URLRequest(url: base.appending(path: "v1/join"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(JoinRequest(token: token, nodeID: nodeID, csrPEM: try key.makeCSR(nodeID: nodeID)))
        let (data, response) = try await session.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else {
            let message = (try? JSONDecoder().decode(APIErrorBody.self, from: data))?.message ?? "HTTP error"
            throw JoinError.refused(message)
        }
        return try JSONDecoder().decode(JoinResponse.self, from: data)
    }
}

public func defaultNodeID() -> String {
    let host = ProcessInfo.processInfo.hostName.split(separator: ".").first.map(String.init) ?? "node"
    return host.lowercased()
}
