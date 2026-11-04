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
    /// The project of `gcp:` references that name none, read when it's needed so that a
    /// change to `cloud.json` needs no restart.
    let gcpProject: @Sendable () -> String?
    /// The store and `state.db` change in two steps, so a concurrent set and delete could
    /// otherwise leave a record saying live with no value behind it. Copies share it.
    private let lock = NSLock()

    public init(secrets: any SecretStore, store: StateStore, gcpProject: @escaping @Sendable () -> String? = { nil }) {
        self.secrets = secrets
        self.store = store
        self.gcpProject = gcpProject
    }

    static func validate(_ value: Data) throws {
        guard !value.isEmpty, value.count <= Self.maxValueSize else {
            throw SecretVaultError.invalidValue("A secret must be between 1 byte and \(Self.maxValueSize / 1024) KiB.")
        }
        // It ends up in an environment variable, which can hold neither.
        guard let text = String(data: value, encoding: .utf8), !text.contains("\0") else {
            throw SecretVaultError.invalidValue("A secret must be UTF-8 text without NUL bytes.")
        }
    }

    public func set(_ name: SecretName, value: Data) throws {
        try Self.validate(value)
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
        try value(item: name.itemName)
    }

    func value(item: String) throws -> String? {
        guard try records()[item]?.deleted == false, let data = try secrets.read(item) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    func itemName(_ ref: SecretRef, service: String) -> String? {
        ref.itemName(service: service, defaultProject: gcpProject())
    }

    // MARK: GCP cache

    /// Stores a value fetched from GCP Secret Manager. Returns true if it changed, which
    /// bumps its revision and so restarts the services that use it.
    @discardableResult
    func cache(_ version: GCPSecretVersion, value: Data) throws -> Bool {
        try Self.validate(value)
        let item = version.itemName
        return try lock.withLock {
            if try records()[item]?.deleted == false, try secrets.read(item) == value { return false }
            try secrets.write(item, value)
            try store.recordSecretChange(item: item)
            return true
        }
    }

    /// The record of a cached GCP value. Nil if there is none.
    func cached(_ version: GCPSecretVersion) throws -> SecretRecord? {
        guard let record = try records()[version.itemName], !record.deleted else { return nil }
        return record
    }

    /// Cached GCP values, by item.
    public func cachedGCPItems() throws -> [String] {
        try store.secretRecords().filter { !$0.deleted && GCPSecretVersion(itemName: $0.item) != nil }.map(\.item)
    }

    func forgetCached(item: String) throws {
        try lock.withLock {
            try secrets.delete(item)
            try store.recordSecretChange(item: item, deleted: true)
        }
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
        let revisions = try spec.secretRefs().map { ref in itemName(ref, service: spec.name).flatMap { records[$0]?.revision } ?? 0 }
        return revisions.isEmpty ? "0" : revisions.map(String.init).joined(separator: ".")
    }

    /// References in `spec` that no secret satisfies.
    public func missing(for spec: ServiceSpec) throws -> [SecretRef] {
        let records = try records()
        return try spec.secretRefs().filter { ref in itemName(ref, service: spec.name).flatMap { records[$0]?.deleted } != false }
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
            if let item = vault.itemName(ref, service: spec.name), let value = try vault.value(item: item) {
                values[ref.description] = value
            }
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

/// A secret file `tenderd exec` couldn't write. Names the path, never the value.
public struct SecretFileError: Error, Equatable, CustomStringConvertible {
    public var path: String
    public var code: Int32

    public var description: String { "can't write the secret file \(path): \(String(cString: strerror(code)))" }
}

/// `tenderd exec`: resolves `${secret:…}` in its environment and arguments from the
/// service's secrets file, writes the service's secret files, then becomes the program
/// with `execve`, so launchd, restart counts and process metrics see one process. It
/// never talks to `tenderd`, so a service still starts while the daemon is down.
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

    /// `--secret-file <path>=<ref>`, as the plist carries it. References have no `=`.
    public static func parseFile(_ text: String) -> (path: String, ref: SecretRef)? {
        guard let separator = text.lastIndex(of: "="), let ref = SecretRef(parsing: String(text[text.index(after: separator)...])) else {
            return nil
        }
        let path = String(text[..<separator])
        return ServiceSpec.isValidSecretFilePath(path) ? (path, ref) : nil
    }

    /// Runs as the service's own user, after launchd dropped privileges, so a path that
    /// user controls (a symlink, a swapped directory) can only lead it to write where it
    /// could anyway: root never writes these files. Each one is created under a fresh name
    /// that `O_CREAT | O_EXCL | O_NOFOLLOW` guarantees is new, made 0400, then renamed over
    /// the target, which replaces a symlink there rather than following it, and which an
    /// instance starting meanwhile never sees half-written.
    ///
    /// Every value is looked up before anything is written. A missing one removes that
    /// file, so a deleted secret's old value isn't left behind, and throws `missing`.
    public static func writeFiles(_ files: [(path: String, ref: SecretRef)], secrets: [String: String]) throws {
        var contents: [(path: String, value: String)] = []
        for file in files {
            guard let value = secrets[file.ref.description] else {
                removeRegularFile(file.path)
                throw SecretTemplateError.missing(file.ref)
            }
            contents.append((file.path, value))
        }
        for file in contents { try writeFile(Data(file.value.utf8), to: file.path) }
    }

    private static func writeFile(_ data: Data, to path: String) throws {
        let target = URL(filePath: path)
        let directory = target.deletingLastPathComponent()
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                    attributes: [.posixPermissions: 0o700])
        } catch {
            let underlying = (error as NSError).userInfo[NSUnderlyingErrorKey] as? NSError
            throw SecretFileError(path: path, code: Int32(underlying?.code ?? Int(EACCES)))
        }
        let temporary = directory.appending(path: ".\(target.lastPathComponent).tender-\(UUID().uuidString)").path(percentEncoded: false)
        let descriptor = open(temporary, O_CREAT | O_EXCL | O_NOFOLLOW | O_WRONLY | O_CLOEXEC, 0o400)
        guard descriptor >= 0 else { throw SecretFileError(path: path, code: errno) }
        let written = data.withUnsafeBytes { write(descriptor, $0.baseAddress, $0.count) }
        // The mode in `open` is narrowed by the umask; this is exact.
        let complete = written == data.count && fchmod(descriptor, 0o400) == 0
        let code = errno
        close(descriptor)
        guard complete, rename(temporary, path) == 0 else {
            let error = SecretFileError(path: path, code: complete ? errno : code)
            unlink(temporary)
            throw error
        }
    }

    private static func removeRegularFile(_ path: String) {
        var info = stat()
        if lstat(path, &info) == 0, info.st_mode & S_IFMT == S_IFREG { unlink(path) }
    }

    public static func run(service: String, secretsFile: URL, files: [String] = [], command: [String]) -> Never {
        guard let program = command.first else { fail(service, "no command to run", code: configurationError) }
        let resolved: (arguments: [String], environment: [String: String])
        do {
            let secrets = try loadSecrets(file: secretsFile)
            resolved = try resolve(arguments: command, environment: ProcessInfo.processInfo.environment, secrets: secrets)
            let parsed = try files.map { text in
                guard let file = parseFile(text) else { throw SecretTemplateError.malformed(text) }
                return file
            }
            try writeFiles(parsed, secrets: secrets)
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

/// Removes secret files a service no longer has. `tenderd` runs as root and these paths
/// can be in directories the service's user controls, so it walks them one component at
/// a time with `openat` and `O_NOFOLLOW`, and gives up at a symlink unless root owns it
/// in a directory only root can change, as the system's `/tmp`, `/var` and `/etc` are.
/// Only a regular 0400 file owned by the service's user goes, which is what `tenderd
/// exec` writes; a swap after the check can at most unlink a name in a directory that
/// user can already change.
enum SecretFileCleaner {
    static func remove(_ path: String, owner: uid_t) {
        guard ServiceSpec.isValidSecretFilePath(path) else { return }
        let components = path.split(separator: "/").map(String.init)
        var directory = open("/", O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        guard directory >= 0 else { return }
        defer { close(directory) }
        for component in components.dropLast() {
            var next = openat(directory, component, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            if next < 0, errno == ELOOP || errno == ENOTDIR, isTrustedSymlink(component, in: directory) {
                next = openat(directory, component, O_RDONLY | O_DIRECTORY | O_CLOEXEC)
            }
            guard next >= 0 else { return }
            close(directory)
            directory = next
        }
        var info = stat()
        guard let name = components.last, fstatat(directory, name, &info, AT_SYMLINK_NOFOLLOW) == 0,
              info.st_mode & S_IFMT == S_IFREG, info.st_uid == owner, info.st_mode & 0o7777 == 0o400 else { return }
        unlinkat(directory, name, 0)
    }

    private static func isTrustedSymlink(_ name: String, in directory: Int32) -> Bool {
        var parent = stat()
        var link = stat()
        return fstat(directory, &parent) == 0 && parent.st_uid == 0 && parent.st_mode & 0o022 == 0
            && fstatat(directory, name, &link, AT_SYMLINK_NOFOLLOW) == 0 && link.st_mode & S_IFMT == S_IFLNK && link.st_uid == 0
    }

    /// The account whose files they are: the service's user, or in dev mode this one.
    static func owner(of spec: ServiceSpec, environment: TenderEnvironment) -> uid_t? {
        guard environment.mode == .production else { return getuid() }
        return getpwnam(spec.user).map { $0.pointee.pw_uid }
    }
}
