import Foundation
import Security

/// Holds private keys and certificates. Production uses the System Keychain. Dev mode
/// and tests use 0600 files, because a non-root process can't write the System Keychain.
public protocol SecretStore: Sendable {
    func read(_ name: String) throws -> Data?
    func write(_ name: String, _ value: Data) throws
    func delete(_ name: String) throws
}

public enum SecretStoreError: Error, CustomStringConvertible {
    case keychain(operation: String, status: OSStatus)
    case unavailable(String)

    public var description: String {
        switch self {
        case .keychain(let operation, let status):
            let message = SecCopyErrorMessageString(status, nil).map { $0 as String } ?? "status \(status)"
            return "Keychain \(operation) failed: \(message)"
        case .unavailable(let path):
            return "Can't open the keychain at \(path)."
        }
    }
}

/// Files in a 0700 directory, each 0600.
public struct FileSecretStore: SecretStore {
    public let directory: URL

    public init(directory: URL) { self.directory = directory }

    private func url(_ name: String) -> URL { directory.appending(path: name) }

    public func read(_ name: String) throws -> Data? {
        let path = url(name).path(percentEncoded: false)
        guard FileManager.default.fileExists(atPath: path) else { return nil }
        return try Data(contentsOf: url(name))
    }

    public func write(_ name: String, _ value: Data) throws {
        let files = FileManager.default
        try files.createDirectory(at: directory, withIntermediateDirectories: true)
        try files.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path(percentEncoded: false))
        let path = url(name).path(percentEncoded: false)
        // Created private before any secret bytes reach it.
        guard files.createFile(atPath: path + ".tmp", contents: nil, attributes: [.posixPermissions: 0o600]) else {
            throw CocoaError(.fileWriteUnknown)
        }
        try value.write(to: URL(filePath: path + ".tmp"))
        guard rename(path + ".tmp", path) == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
    }

    public func delete(_ name: String) throws {
        try? FileManager.default.removeItem(at: url(name))
    }
}

/// Generic passwords in a file-based keychain.
///
/// An item's access list trusts the binary that created it, so a replaced `tenderd`
/// loses access. `tenderd secrets-export`/`secrets-import` move secrets across an upgrade.
/// User interaction is disabled: a daemon has nobody to answer a prompt, so a denied
/// read must fail rather than hang.
public struct KeychainSecretStore: SecretStore {
    public static let systemKeychainPath = "/Library/Keychains/System.keychain"
    public let keychainPath: String
    public let service: String

    public init(keychainPath: String = KeychainSecretStore.systemKeychainPath,
                service: String = "com.olympsis.tender") {
        self.keychainPath = keychainPath
        self.service = service
    }

    @available(macOS, deprecated: 10.10)
    private func keychain() throws -> SecKeychain {
        var keychain: SecKeychain?
        let status = SecKeychainOpen(keychainPath, &keychain)
        guard status == errSecSuccess, let keychain else { throw SecretStoreError.unavailable(keychainPath) }
        SecKeychainSetUserInteractionAllowed(false)
        return keychain
    }

    @available(macOS, deprecated: 10.10)
    private func baseQuery(_ name: String) throws -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: name,
            kSecMatchSearchList as String: [try keychain()],
        ]
    }

    @available(macOS, deprecated: 10.10)
    public func read(_ name: String) throws -> Data? {
        var query = try baseQuery(name)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else { throw SecretStoreError.keychain(operation: "read", status: status) }
        return result as? Data
    }

    @available(macOS, deprecated: 10.10)
    public func write(_ name: String, _ value: Data) throws {
        // In place, so that a failure leaves the old value rather than none.
        let updated = SecItemUpdate(try baseQuery(name) as CFDictionary, [kSecValueData as String: value] as CFDictionary)
        if updated == errSecSuccess { return }
        guard updated == errSecItemNotFound else { throw SecretStoreError.keychain(operation: "write", status: updated) }
        let attributes: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: name,
            kSecValueData as String: value,
            kSecUseKeychain as String: try keychain(),
        ]
        let status = SecItemAdd(attributes as CFDictionary, nil)
        guard status == errSecSuccess else { throw SecretStoreError.keychain(operation: "write", status: status) }
    }

    @available(macOS, deprecated: 10.10)
    public func delete(_ name: String) throws {
        let status = SecItemDelete(try baseQuery(name) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw SecretStoreError.keychain(operation: "delete", status: status)
        }
    }
}

extension TenderEnvironment {
    public var secretsDirectory: URL { configDirectory.appending(path: "secrets") }

    public func makeSecretStore() -> any SecretStore {
        mode == .production ? KeychainSecretStore() : FileSecretStore(directory: secretsDirectory)
    }
}
