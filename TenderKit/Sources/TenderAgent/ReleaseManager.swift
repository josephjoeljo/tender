import CryptoKit
import FileWatch
import Foundation
import Logging
import ServiceLifecycle
import TenderCore

public enum ReleaseError: Error, Equatable, CustomStringConvertible {
    case notFound(service: String, sha12: String)
    case noPrevious(service: String)
    case binaryMissing(String)
    case unknownService(String)

    public var description: String {
        switch self {
        case .notFound(let service, let sha12): "No release \(sha12) of '\(service)'."
        case .noPrevious(let service): "'\(service)' has no earlier release to roll back to."
        case .binaryMissing(let path): "The release binary \(path) is missing."
        case .unknownService(let service): "No service named '\(service)'."
        }
    }
}

/// Turns binaries dropped into `bin/<service>/` into immutable releases and points
/// services at them. A release is always a new file: a running binary is never
/// overwritten, because the kernel caches code signatures per vnode and overwriting
/// one can SIGKILL the next process started from it.
public actor ReleaseManager {
    private let environment: TenderEnvironment
    private let store: StateStore
    private let reconciler: Reconciler
    private let keep: Int
    private let logger: Logger
    private var tracker: StabilityTracker

    public init(
        environment: TenderEnvironment,
        store: StateStore,
        reconciler: Reconciler,
        stabilityWindow: TimeInterval = 2,
        keep: Int = 5,
        logger: Logger = Logger(label: "tender.releases")
    ) {
        self.environment = environment
        self.store = store
        self.reconciler = reconciler
        self.tracker = StabilityTracker(window: stabilityWindow)
        self.keep = keep
        self.logger = logger
    }

    /// Checks `bin/` once. Returns true if a file is still settling, in which case
    /// the caller should scan again soon.
    @discardableResult
    public func scan() async -> Bool {
        var pending = false
        let files = FileManager.default
        let directories = (try? files.contentsOfDirectory(at: environment.binDirectory, includingPropertiesForKeys: nil)) ?? []
        for directory in directories where ServiceSpec.isValidName(directory.lastPathComponent) {
            let service = directory.lastPathComponent
            do {
                guard let binary = Self.candidate(in: directory, service: service),
                      let fingerprint = FileFingerprint(url: binary),
                      try store.lastSeenBinary(service: service) != fingerprint
                else { continue }
                guard tracker.isStable(key: service, fingerprint: fingerprint) else {
                    pending = true
                    continue
                }
                pending = try await deploy(binary: binary, fingerprint: fingerprint, service: service) || pending
            } catch {
                logger.error("release failed", metadata: ["service": "\(service)", "error": "\(error)"])
            }
        }
        return pending
    }

    /// `bin/<service>/<service>` if present, else the newest regular file.
    private static func candidate(in directory: URL, service: String) -> URL? {
        let named = directory.appending(path: service)
        var isDirectory: ObjCBool = false
        if FileManager.default.fileExists(atPath: named.path(percentEncoded: false), isDirectory: &isDirectory),
           !isDirectory.boolValue {
            return named
        }
        let keys: [URLResourceKey] = [.isRegularFileKey, .contentModificationDateKey]
        let entries = (try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: keys, options: .skipsHiddenFiles)) ?? []
        return entries
            .compactMap { url -> (URL, Date)? in
                guard let values = try? url.resourceValues(forKeys: Set(keys)), values.isRegularFile == true else { return nil }
                return (url, values.contentModificationDate ?? .distantPast)
            }
            .max { $0.1 < $1.1 }?.0
    }

    /// Returns true if the file changed during the copy and must be looked at again.
    private func deploy(binary: URL, fingerprint: FileFingerprint, service: String) async throws -> Bool {
        let files = FileManager.default
        let serviceDirectory = environment.releasesDirectory.appending(path: service)
        let temporary = serviceDirectory.appending(path: ".tmp-\(UUID().uuidString)")
        try files.createDirectory(at: temporary, withIntermediateDirectories: true)
        defer { try? files.removeItem(at: temporary) }

        let copy = temporary.appending(path: service)
        try files.copyItem(at: binary, to: copy)
        guard FileFingerprint(url: binary) == fingerprint else {
            tracker.forget(key: service)
            return true
        }
        try files.setAttributes([.posixPermissions: 0o755], ofItemAtPath: copy.path(percentEncoded: false))

        let sha12 = try Self.sha12(of: copy)
        let destination = serviceDirectory.appending(path: sha12)
        if !files.fileExists(atPath: destination.path(percentEncoded: false)) {
            try files.moveItem(at: temporary, to: destination)
        }
        let path = environment.releaseBinary(service: service, sha12: sha12).path(percentEncoded: false)
        try store.recordRelease(Release(service: service, sha12: sha12, path: path, createdAt: Date()))
        try store.setLastSeenBinary(service: service, fingerprint: fingerprint)
        tracker.forget(key: service)
        logger.info("new release", metadata: ["service": "\(service)", "sha12": "\(sha12)"])

        if try store.setProgram(.release(sha12: sha12), service: service) {
            try await reconciler.reconcile()
        }
        try prune(service: service)
        return false
    }

    /// Installs a binary fetched from a release source: verifies it, strips quarantine,
    /// and points the service at it. A file that fails verification goes no further.
    public func installFetched(file: URL, service: String, expectedSHA256: String) async throws -> String {
        let found = try Self.sha256(of: file)
        guard found == expectedSHA256.lowercased() else {
            throw CloudError.checksumMismatch(expected: expectedSHA256, found: found)
        }
        let sha12 = String(found.prefix(12))
        let files = FileManager.default
        let destination = environment.releasesDirectory.appending(path: "\(service)/\(sha12)")
        if !files.fileExists(atPath: destination.path(percentEncoded: false)) {
            let temporary = environment.releasesDirectory.appending(path: "\(service)/.tmp-\(UUID().uuidString)")
            try files.createDirectory(at: temporary, withIntermediateDirectories: true)
            defer { try? files.removeItem(at: temporary) }
            let copy = temporary.appending(path: service)
            try files.moveItem(at: file, to: copy)
            removexattr(copy.path(percentEncoded: false), "com.apple.quarantine", 0)
            try files.setAttributes([.posixPermissions: 0o755], ofItemAtPath: copy.path(percentEncoded: false))
            try files.moveItem(at: temporary, to: destination)
        }
        let path = environment.releaseBinary(service: service, sha12: sha12).path(percentEncoded: false)
        try store.recordRelease(Release(service: service, sha12: sha12, path: path, createdAt: Date()))
        if try store.setProgram(.release(sha12: sha12), service: service) {
            try await reconciler.reconcile()
        }
        try prune(service: service)
        return sha12
    }

    private static func sha12(of url: URL) throws -> String {
        String(try sha256(of: url).prefix(12))
    }

    private static func sha256(of url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        while let chunk = try handle.read(upToCount: 1 << 20), !chunk.isEmpty {
            hasher.update(data: chunk)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    /// Keeps the newest `keep` releases, and always the one in use.
    private func prune(service: String) throws {
        let current = try currentRelease(service: service)
        for release in try store.releases(service: service).dropFirst(keep) where release.sha12 != current {
            try? FileManager.default.removeItem(at: URL(filePath: release.path).deletingLastPathComponent())
            try store.removeRelease(service: service, sha12: release.sha12)
        }
    }

    public func currentRelease(service: String) throws -> String? {
        if case .release(let sha12) = try store.service(service)?.spec.program { return sha12 }
        return nil
    }

    public func list(service: String) throws -> ReleaseList {
        ReleaseList(releases: try store.releases(service: service), current: try currentRelease(service: service))
    }

    /// Points the service at `sha12`, or by default at the release before the
    /// current one. The binary still in `bin/` doesn't undo this: only a change to
    /// that file creates a new deployment.
    public func rollback(service: String, to sha12: String?) async throws -> Release {
        guard try store.service(service) != nil else { throw ReleaseError.unknownService(service) }
        let releases = try store.releases(service: service)
        let target: Release
        if let sha12 {
            guard let match = releases.first(where: { $0.sha12 == sha12 }) else {
                throw ReleaseError.notFound(service: service, sha12: sha12)
            }
            target = match
        } else {
            let current = try currentRelease(service: service)
            guard let index = releases.firstIndex(where: { $0.sha12 == current }),
                  releases.indices.contains(index + 1) else {
                throw ReleaseError.noPrevious(service: service)
            }
            target = releases[index + 1]
        }
        guard FileManager.default.isExecutableFile(atPath: target.path) else {
            throw ReleaseError.binaryMissing(target.path)
        }
        try store.setProgram(.release(sha12: target.sha12), service: service)
        try await reconciler.reconcile()
        return target
    }
}

/// Wakes the release manager on FSEvents, with a periodic rescan as a backstop for
/// coalesced or missed events.
public struct ReleaseWatcher: Service {
    private let environment: TenderEnvironment
    private let manager: ReleaseManager
    private let backstop: Duration

    public init(environment: TenderEnvironment, manager: ReleaseManager, backstop: Duration = .seconds(10)) {
        self.environment = environment
        self.manager = manager
        self.backstop = backstop
    }

    public func run() async throws {
        let directory = environment.binDirectory
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let (wakeups, continuation) = AsyncStream.makeStream(of: Void.self, bufferingPolicy: .bufferingNewest(1))
        let watcher = DirectoryWatcher(path: directory.path(percentEncoded: false)) { continuation.yield() }
        watcher.start()
        defer { watcher.stop() }

        let backstop = self.backstop
        await cancelWhenGracefulShutdown {
            await withTaskGroup(of: Void.self) { group in
                group.addTask {
                    while !Task.isCancelled {
                        continuation.yield()
                        try? await Task.sleep(for: backstop)
                    }
                }
                group.addTask {
                    for await _ in wakeups {
                        if Task.isCancelled { break }
                        if await manager.scan() {
                            try? await Task.sleep(for: .milliseconds(500))
                            continuation.yield()
                        }
                    }
                }
                await withTaskCancellationHandler {
                    await group.next()
                } onCancel: {
                    continuation.finish()
                }
                group.cancelAll()
            }
        }
    }
}
