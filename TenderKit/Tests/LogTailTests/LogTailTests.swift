import Foundation
import LaunchdKit
import Testing
@testable import LogTail

private func tempFile() throws -> URL {
    let directory = URL(filePath: "/tmp/tender-test-\(UUID().uuidString.prefix(8))")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    return directory.appending(path: "x.log")
}

private func append(_ text: String, to url: URL) throws {
    if !FileManager.default.fileExists(atPath: url.path(percentEncoded: false)) {
        FileManager.default.createFile(atPath: url.path(percentEncoded: false), contents: nil)
    }
    let handle = try FileHandle(forWritingTo: url)
    defer { try? handle.close() }
    try handle.seekToEnd()
    try handle.write(contentsOf: Data(text.utf8))
}

@Test func lastLinesReturnsTheEnd() throws {
    let url = try tempFile()
    defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
    #expect(try LogReader.lastLines(of: url, count: 5).isEmpty)

    try append((1...1000).map { "line \($0)" }.joined(separator: "\n") + "\n", to: url)
    #expect(try LogReader.lastLines(of: url, count: 2) == ["line 999", "line 1000"])
    #expect(try LogReader.lastLines(of: url, count: 2000).count == 1000)
    #expect(try LogReader.lastLines(of: url, count: 0).isEmpty)
}

@Test func lastLinesSpansChunksAndStaysBounded() throws {
    let url = try tempFile()
    defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
    let long = String(repeating: "x", count: 100_000)
    try append("first\n\(long)\nlast\n", to: url)
    #expect(try LogReader.lastLines(of: url, count: 2) == [long, "last"])
    let bounded = try LogReader.lastLines(of: url, count: 3, maxBytes: 1000)
    #expect(bounded.allSatisfy { $0 != "first" })
}

@Test func followerSeesOnlyNewCompleteLines() throws {
    let url = try tempFile()
    defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
    try append("old\n", to: url)
    var follower = LogFollower(url: url)
    #expect(try follower.poll().isEmpty)

    try append("a\nb\npart", to: url)
    #expect(try follower.poll() == ["a", "b"])
    try append("ial\n", to: url)
    #expect(try follower.poll() == ["partial"])
    #expect(try follower.poll().isEmpty)
}

@Test func followerHandlesTruncationAndReplacement() throws {
    let url = try tempFile()
    defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
    try append("one\ntwo\n", to: url)
    var follower = LogFollower(url: url)

    #expect(truncate(url.path(percentEncoded: false), 0) == 0)
    try append("x\n", to: url)
    #expect(try follower.poll() == ["x"])

    try FileManager.default.removeItem(at: url)
    #expect(try follower.poll().isEmpty)
    try append("new file\n", to: url)
    #expect(try follower.poll() == ["new file"])
}

@Test func rotatorKeepsNCopies() throws {
    let url = try tempFile()
    defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
    let rotator = LogRotator(maxBytes: 5, keep: 2)
    let path = url.path(percentEncoded: false)

    try append("abc", to: url)
    #expect(try !rotator.rotateIfNeeded(url))

    for generation in ["first!", "second", "third!"] {
        try append(generation, to: url)
        #expect(try rotator.rotateIfNeeded(url))
        #expect(try FileManager.default.attributesOfItem(atPath: path)[.size] as? UInt64 == 0)
    }
    #expect(try String(contentsOfFile: "\(path).1", encoding: .utf8) == "third!")
    #expect(try String(contentsOfFile: "\(path).2", encoding: .utf8) == "second")
    #expect(!FileManager.default.fileExists(atPath: "\(path).3"))
}

/// The plan's named risk: launchd holds the descriptor open, so truncation only
/// works if its writes are O_APPEND. Otherwise the file would keep its old
/// offset and turn sparse (a run of NULs at the start).
@Test func copyTruncateWorksOnARealLaunchdJob() async throws {
    let url = try tempFile()
    let label = "com.olympsis.tender.test.\(UUID().uuidString.prefix(8))"
    let directory = url.deletingLastPathComponent()
    let plist = directory.appending(path: "\(label).plist")
    let launchctl = Launchctl(domain: .currentUser)
    try PlistRenderer().render(
        label: label,
        programArguments: ["/bin/sh", "-c", "i=0; while :; do echo line$i; i=$((i+1)); sleep 0.02; done"],
        stdoutPath: url.path(percentEncoded: false),
        stderrPath: directory.appending(path: "err.log").path(percentEncoded: false)
    ).write(to: plist)
    try await launchctl.bootstrap(plistURL: plist)
    defer {
        let cleanup = Process()
        cleanup.executableURL = URL(filePath: "/bin/launchctl")
        cleanup.arguments = ["bootout", "\(launchctl.domain.target)/\(label)"]
        try? cleanup.run()
        cleanup.waitUntilExit()
        try? FileManager.default.removeItem(at: directory)
    }

    func size() -> UInt64 {
        ((try? FileManager.default.attributesOfItem(atPath: url.path(percentEncoded: false)))?[.size] as? UInt64) ?? 0
    }
    var attempts = 0
    while size() < 200, attempts < 100 {
        try await Task.sleep(for: .milliseconds(100))
        attempts += 1
    }
    let before = size()
    #expect(before >= 200)
    #expect(try LogRotator(maxBytes: 100, keep: 1).rotateIfNeeded(url))
    try await Task.sleep(for: .milliseconds(300))

    let data = try Data(contentsOf: url)
    #expect(!data.contains(0), "file went sparse: launchd's descriptor isn't O_APPEND")
    #expect(!data.isEmpty, "job stopped writing after truncate")
    #expect(UInt64(data.count) < before)
    #expect(FileManager.default.fileExists(atPath: "\(url.path(percentEncoded: false)).1"))
}
