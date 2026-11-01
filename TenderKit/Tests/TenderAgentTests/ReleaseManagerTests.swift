import FileWatch
import Foundation
import LaunchdKit
import Testing
import TenderCore
@testable import TenderAgent

private struct Harness {
    let env: TenderEnvironment
    let store: StateStore
    let launchd = MemoryLaunchd()
    let reconciler: Reconciler
    let manager: ReleaseManager

    init(keep: Int = 5) throws {
        env = try makeTestEnvironment()
        store = try StateStore(environment: env)
        reconciler = Reconciler(environment: env, store: store, launchd: launchd)
        manager = ReleaseManager(environment: env, store: store, reconciler: reconciler,
                                 stabilityWindow: 0, keep: keep)
    }

    /// Drops a new binary as a fresh file with an unmistakable mtime.
    func drop(_ body: String, mtime: TimeInterval) throws {
        let directory = env.binDirectory.appending(path: "api")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let path = directory.appending(path: "api").path(percentEncoded: false)
        try? FileManager.default.removeItem(atPath: path)
        FileManager.default.createFile(atPath: path, contents: Data("#!/bin/sh\n# \(body)\n".utf8),
                                       attributes: [.posixPermissions: 0o755])
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: mtime)], ofItemAtPath: path)
    }

    /// With a zero window: the first scan sees the file, the second deploys it.
    func settle() async {
        while await manager.scan() {}
    }

    func program() throws -> ProgramSource? { try store.service("api")?.spec.program }
    func cleanup() { try? FileManager.default.removeItem(at: env.root) }
}

private let spec = ServiceSpec(name: "api", program: .executable("/bin/sleep"), arguments: ["1000"])

@Test func droppedBinaryBecomesAReleaseAndIsDeployed() async throws {
    let h = try Harness()
    defer { h.cleanup() }
    try h.store.upsert(spec)
    try h.drop("v1", mtime: 1000)
    await h.settle()

    let list = try await h.manager.list(service: "api")
    #expect(list.releases.count == 1)
    let release = try #require(list.releases.first)
    #expect(release.sha12.count == 12)
    #expect(list.current == release.sha12)
    #expect(try h.program() == .release(sha12: release.sha12))
    #expect(FileManager.default.isExecutableFile(atPath: release.path))

    // The plist now points at the copy, and the arguments survived.
    let label = h.env.serviceLabel(service: "api", instance: 0)
    let plist = try Data(contentsOf: h.env.plistPath(label: label))
    let parsed = try #require(try PropertyListSerialization.propertyList(from: plist, format: nil) as? [String: Any])
    #expect(parsed["ProgramArguments"] as? [String] == [release.path, "1000"])
}

@Test func releaseIsANewInodeAndSurvivesOverwritingBin() async throws {
    let h = try Harness()
    defer { h.cleanup() }
    try h.store.upsert(spec)
    try h.drop("v1", mtime: 1000)
    await h.settle()
    let first = try #require(try await h.manager.list(service: "api").releases.first)
    let binary = h.env.binDirectory.appending(path: "api/api").path(percentEncoded: false)
    let releaseInode = try FileManager.default.attributesOfItem(atPath: first.path)[.systemFileNumber] as? UInt64
    #expect(try FileManager.default.attributesOfItem(atPath: binary)[.systemFileNumber] as? UInt64 != releaseInode)

    try h.drop("v2", mtime: 2000)
    await h.settle()
    #expect(try String(contentsOfFile: first.path, encoding: .utf8).contains("v1"))
    #expect(try await h.manager.list(service: "api").releases.count == 2)
}

@Test func unchangedBinaryIsNotRedeployed() async throws {
    let h = try Harness()
    defer { h.cleanup() }
    try h.store.upsert(spec)
    try h.drop("v1", mtime: 1000)
    await h.settle()
    #expect(await h.manager.scan() == false)
    #expect(try await h.manager.list(service: "api").releases.count == 1)
}

@Test func fileIsNotDeployedUntilStable() async throws {
    let h = try Harness()
    defer { h.cleanup() }
    let manager = ReleaseManager(environment: h.env, store: h.store, reconciler: h.reconciler, stabilityWindow: 60)
    try h.drop("v1", mtime: 1000)
    #expect(await manager.scan() == true)
    #expect(await manager.scan() == true)
    #expect(try await manager.list(service: "api").releases.isEmpty)
}

@Test func rollbackGoesBackAndSticks() async throws {
    let h = try Harness()
    defer { h.cleanup() }
    try h.store.upsert(spec)
    await #expect(throws: ReleaseError.noPrevious(service: "api")) {
        try await h.manager.rollback(service: "api", to: nil)
    }
    try h.drop("v1", mtime: 1000)
    await h.settle()
    try h.drop("v2", mtime: 2000)
    await h.settle()
    let releases = try await h.manager.list(service: "api").releases
    let (v2, v1) = (releases[0].sha12, releases[1].sha12)

    let target = try await h.manager.rollback(service: "api", to: nil)
    #expect(target.sha12 == v1)
    #expect(try h.program() == .release(sha12: v1))

    // The newer binary still sitting in bin/ must not undo the rollback.
    await h.settle()
    #expect(try h.program() == .release(sha12: v1))

    _ = try await h.manager.rollback(service: "api", to: v2)
    #expect(try h.program() == .release(sha12: v2))

    await #expect(throws: ReleaseError.notFound(service: "api", sha12: "nope")) {
        try await h.manager.rollback(service: "api", to: "nope")
    }
    await #expect(throws: ReleaseError.unknownService("ghost")) {
        try await h.manager.rollback(service: "ghost", to: nil)
    }
}

@Test func redroppingAnOlderBinaryDeploysIt() async throws {
    let h = try Harness()
    defer { h.cleanup() }
    try h.store.upsert(spec)
    try h.drop("v1", mtime: 1000)
    await h.settle()
    let v1 = try await h.manager.list(service: "api").current
    try h.drop("v2", mtime: 2000)
    await h.settle()
    try h.drop("v1", mtime: 3000)
    await h.settle()
    let list = try await h.manager.list(service: "api")
    #expect(list.current == v1)
    #expect(list.releases.first?.sha12 == v1)
    #expect(list.releases.count == 2)
}

@Test func keepsLastNAndAlwaysTheCurrentOne() async throws {
    let h = try Harness(keep: 2)
    defer { h.cleanup() }
    try h.store.upsert(spec)
    for version in 1...3 {
        try h.drop("v\(version)", mtime: TimeInterval(version * 1000))
        await h.settle()
    }
    let list = try await h.manager.list(service: "api")
    #expect(list.releases.count == 2)
    let directories = try FileManager.default.contentsOfDirectory(
        atPath: h.env.releasesDirectory.appending(path: "api").path(percentEncoded: false))
    #expect(directories.filter { !$0.hasPrefix(".") }.count == 2)

    // Pinned to the oldest kept release, it survives the next prunes.
    let oldest = try #require(list.releases.last?.sha12)
    try h.store.setProgram(.release(sha12: oldest), service: "api")
    try h.store.setDesired(.stopped, service: "api")
    let path = h.env.releaseBinary(service: "api", sha12: oldest).path(percentEncoded: false)
    #expect(FileManager.default.fileExists(atPath: path))
}

@Test func newReleaseDoesNotStartAStoppedService() async throws {
    let h = try Harness()
    defer { h.cleanup() }
    try h.store.upsert(spec)
    try await h.reconciler.reconcile()
    _ = try h.store.setDesired(.stopped, service: "api")
    try await h.reconciler.reconcile()

    try h.drop("v1", mtime: 1000)
    await h.settle()
    #expect(try h.store.service("api")?.desired == .stopped)
    #expect(await h.launchd.loaded.isEmpty)
    #expect(try await h.manager.list(service: "api").current != nil)
}

@Test func releaseWithoutServiceIsRecordedOnly() async throws {
    let h = try Harness()
    defer { h.cleanup() }
    try h.drop("v1", mtime: 1000)
    await h.settle()
    #expect(try await h.manager.list(service: "api").releases.count == 1)
    #expect(try h.store.service("api") == nil)
}

@Test func fsEventsFireForADroppedFile() async throws {
    let env = try makeTestEnvironment()
    defer { try? FileManager.default.removeItem(at: env.root) }
    let directory = env.root.appending(path: "watched")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let (events, continuation) = AsyncStream.makeStream(of: Void.self)
    let watcher = DirectoryWatcher(path: directory.path(percentEncoded: false)) { continuation.yield() }
    watcher.start()
    defer { watcher.stop() }
    try await Task.sleep(for: .milliseconds(300))
    try Data("x".utf8).write(to: directory.appending(path: "new"))

    let fired = await withTaskGroup(of: Bool.self) { group in
        group.addTask {
            for await _ in events { return true }
            return false
        }
        group.addTask {
            try? await Task.sleep(for: .seconds(5))
            return false
        }
        let first = await group.next() ?? false
        group.cancelAll()
        continuation.finish()
        return first
    }
    #expect(fired)
}

@Test func stabilityTrackerWaitsForAQuietWindow() {
    var tracker = StabilityTracker(window: 2)
    let start = Date(timeIntervalSince1970: 0)
    let a = FileFingerprint(size: 1, modified: 1)
    let b = FileFingerprint(size: 2, modified: 2)
    var stable = tracker.isStable(key: "k", fingerprint: a, now: start)
    #expect(!stable)
    stable = tracker.isStable(key: "k", fingerprint: a, now: start.addingTimeInterval(1))
    #expect(!stable)
    stable = tracker.isStable(key: "k", fingerprint: b, now: start.addingTimeInterval(1.5))
    #expect(!stable)
    stable = tracker.isStable(key: "k", fingerprint: b, now: start.addingTimeInterval(3))
    #expect(!stable)
    stable = tracker.isStable(key: "k", fingerprint: b, now: start.addingTimeInterval(3.5))
    #expect(stable)
}
