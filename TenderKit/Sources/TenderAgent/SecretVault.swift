import Foundation
import TenderCore

public enum SecretVaultError: Error, Equatable, CustomStringConvertible {
    case invalidValue(String)

    public var description: String {
        switch self {
        case .invalidValue(let reason): reason
        }
    }
}

/// Secrets for managed services, on the node that runs them. Values go to the node's
/// `SecretStore` (System Keychain in production); `state.db` holds only names and
/// revisions. Nothing here ever returns a value except to `SecretMaterializer`.
public struct SecretVault: Sendable {
    public static let maxValueSize = SecretSetRequest.maxValueSize

    let secrets: any SecretStore
    let store: StateStore
    /// The store and `state.db` change in two steps, so a concurrent set and delete could
    /// otherwise leave a record saying live with no value behind it. Copies share it.
    private let lock = NSLock()

    public init(secrets: any SecretStore, store: StateStore) {
        self.secrets = secrets
        self.store = store
    }

    public func set(_ name: SecretName, value: Data) throws {
        guard !value.isEmpty, value.count <= Self.maxValueSize else {
            throw SecretVaultError.invalidValue("A secret must be between 1 byte and \(Self.maxValueSize / 1024) KiB.")
        }
        // It ends up in an environment variable, which can hold neither.
        guard let text = String(data: value, encoding: .utf8), !text.contains("\0") else {
            throw SecretVaultError.invalidValue("A secret must be UTF-8 text without NUL bytes.")
        }
        try lock.withLock {
            try secrets.write(name.itemName, value)
            try store.recordSecretChange(item: name.itemName)
        }
    }

    /// Returns false if there was nothing to delete.
    @discardableResult
    public func delete(_ name: SecretName) throws -> Bool {
        try lock.withLock {
            guard try records()[name.itemName]?.deleted == false else { return false }
            try secrets.delete(name.itemName)
            try store.recordSecretChange(item: name.itemName, deleted: true)
            return true
        }
    }

    func value(_ name: SecretName) throws -> String? {
        guard try records()[name.itemName]?.deleted == false, let data = try secrets.read(name.itemName) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    /// Secrets that are set, by name.
    public func live() throws -> [(name: SecretName, record: SecretRecord)] {
        try store.secretRecords().compactMap { record in
            guard !record.deleted, let name = SecretName(itemName: record.item) else { return nil }
            return (name, record)
        }
    }

    private func records() throws -> [String: SecretRecord] {
        Dictionary(uniqueKeysWithValues: try store.secretRecords().map { ($0.item, $0) })
    }

    /// One revision per reference, missing ones as 0, so that setting or deleting any of
    /// them changes the tag. A counter, never derived from the values.
    public func revisionTag(for spec: ServiceSpec) throws -> String {
        let records = try records()
        let revisions = try spec.secretRefs().map { records[$0.secretName(service: spec.name).itemName]?.revision ?? 0 }
        return revisions.isEmpty ? "0" : revisions.map(String.init).joined(separator: ".")
    }

    /// References in `spec` that no secret satisfies.
    public func missing(for spec: ServiceSpec) throws -> [SecretRef] {
        let records = try records()
        return try spec.secretRefs().filter { records[$0.secretName(service: spec.name).itemName]?.deleted != false }
    }
}

/// Writes the resolved secrets a service's instances read at launch, as
/// `env/<service>/secrets.json`: 0400, owned by the service's user, in a 0711 directory
/// root owns, so the service can read its file but never swap in another. Missing secrets
/// are left out, and `tenderd exec` names them when it exits.
struct SecretMaterializer: Sendable {
    let environment: TenderEnvironment
    let vault: SecretVault

    func materialize(_ spec: ServiceSpec) throws {
        var values: [String: String] = [:]
        for ref in try spec.secretRefs() {
            if let value = try vault.value(ref.secretName(service: spec.name)) { values[ref.description] = value }
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        let content = try encoder.encode(values)

        let file = environment.serviceSecretsFile(service: spec.name)
        let directory = file.deletingLastPathComponent()
        let files = FileManager.default
        try files.createDirectory(at: directory, withIntermediateDirectories: true)
        let owner = try self.owner(spec)
        try own(directory, mode: 0o711, owner: owner.map { _ in (uid: 0, gid: 0) })
        if holds(file, content, owner: owner) { return }

        // Private before any secret bytes reach it, and swapped in whole, so that an
        // instance starting meanwhile reads either the old file or the new one.
        let temporary = directory.appending(path: ".secrets-\(UUID().uuidString)").path(percentEncoded: false)
        let descriptor = open(temporary, O_CREAT | O_EXCL | O_WRONLY | O_CLOEXEC, 0o400)
        guard descriptor >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        let written = content.withUnsafeBytes { write(descriptor, $0.baseAddress, $0.count) }
        let chowned = owner.map { fchown(descriptor, $0.uid, $0.gid) == 0 } ?? true
        close(descriptor)
        guard written == content.count, chowned,
              rename(temporary, file.path(percentEncoded: false)) == 0 else {
            let error = POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            unlink(temporary)
            throw error
        }
    }

    /// Whether `file` is already exactly `content`, owned as it should be. Opened without
    /// following a symlink or waiting on a FIFO, and read no further than `content` is long,
    /// so nothing put at that path can hang or exhaust the daemon: it counts as different
    /// and is replaced.
    private func holds(_ file: URL, _ content: Data, owner: (uid: uid_t, gid: gid_t)?) -> Bool {
        let descriptor = open(file.path(percentEncoded: false), O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard descriptor >= 0 else { return false }
        defer { close(descriptor) }
        var info = stat()
        guard fstat(descriptor, &info) == 0, info.st_mode & S_IFMT == S_IFREG, info.st_mode & 0o7777 == 0o400,
              info.st_size == content.count, owner.map({ info.st_uid == $0.uid }) ?? true else { return false }
        var existing = Data(count: content.count)
        let count = existing.withUnsafeMutableBytes { read(descriptor, $0.baseAddress, $0.count) }
        return count == content.count && existing == content
    }

    /// Removes the files of services that no longer use secrets.
    func removeStale(keeping services: Set<String>) {
        let root = environment.serviceSecretsRoot
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: root.path(percentEncoded: false)) else { return }
        for name in names where !services.contains(name) {
            try? FileManager.default.removeItem(at: root.appending(path: name))
        }
    }

    /// In dev mode services run as the daemon's own user, so nothing changes owner.
    private func owner(_ spec: ServiceSpec) throws -> (uid: uid_t, gid: gid_t)? {
        guard environment.mode == .production else { return nil }
        guard let account = getpwnam(spec.user) else { throw ReconcileApplyError.unknownUser(spec.user) }
        return (account.pointee.pw_uid, account.pointee.pw_gid)
    }

    private func own(_ url: URL, mode: mode_t, owner: (uid: uid_t, gid: gid_t)?) throws {
        let path = url.path(percentEncoded: false)
        guard chmod(path, mode) == 0, owner.map({ chown(path, $0.uid, $0.gid) == 0 }) ?? true else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
    }
}

/// `tenderd exec`: resolves `${secret:…}` in its environment and arguments from the
/// service's secrets file, then becomes the program with `execve`, so launchd, restart
/// counts and process metrics see one process. It never talks to `tenderd`, so a
/// service still starts while the daemon is down.
public enum SecretExec {
    /// `EX_CONFIG`. launchd throttles the restarts, and `tender list` shows the exit code.
    public static let configurationError: Int32 = 78

    public static func loadSecrets(file: URL) throws -> [String: String] {
        guard FileManager.default.fileExists(atPath: file.path(percentEncoded: false)) else { return [:] }
        return try JSONDecoder().decode([String: String].self, from: Data(contentsOf: file))
    }

    public static func resolve(arguments: [String], environment: [String: String],
                               secrets: [String: String]) throws -> (arguments: [String], environment: [String: String]) {
        let lookup: (SecretRef) -> String? = { secrets[$0.description] }
        var resolved = environment
        for (key, value) in environment where SecretTemplate.needsProcessing(value) {
            resolved[key] = try SecretTemplate.render(value, lookup: lookup)
        }
        let arguments = try arguments.map { try SecretTemplate.needsProcessing($0) ? SecretTemplate.render($0, lookup: lookup) : $0 }
        return (arguments, resolved)
    }

    public static func run(service: String, secretsFile: URL, command: [String]) -> Never {
        guard let program = command.first else { fail(service, "no command to run", code: configurationError) }
        let resolved: (arguments: [String], environment: [String: String])
        do {
            resolved = try resolve(arguments: command, environment: ProcessInfo.processInfo.environment,
                                   secrets: try loadSecrets(file: secretsFile))
        } catch {
            fail(service, "\(error)", code: configurationError)
        }
        let argv = resolved.arguments.map { strdup($0) } + [nil]
        let envp = resolved.environment.map { strdup("\($0.key)=\($0.value)") } + [nil]
        execve(program, argv, envp)
        let error = errno
        fail(service, "can't run \(program): \(String(cString: strerror(error)))", code: error == ENOENT ? 127 : 126)
    }

    private static func fail(_ service: String, _ message: String, code: Int32) -> Never {
        FileHandle.standardError.write(Data("tenderd exec: \(service): \(message)\n".utf8))
        exit(code)
    }
}
