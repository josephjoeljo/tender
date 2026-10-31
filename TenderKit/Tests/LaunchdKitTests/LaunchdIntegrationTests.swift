import Foundation
import Testing
@testable import LaunchdKit

/// Talks to real launchd in the current user's domain, using only test labels.
@Suite(.serialized) struct LaunchdIntegrationTests {
    let launchctl = Launchctl(domain: .currentUser)

    private func poll<T>(timeout: Duration = .seconds(15), _ check: () async throws -> T?) async throws -> T? {
        let deadline = ContinuousClock.now + timeout
        while ContinuousClock.now < deadline {
            if let value = try await check() { return value }
            try await Task.sleep(for: .milliseconds(100))
        }
        return nil
    }

    @Test func bootstrapKillRestartBootout() async throws {
        let label = "com.olympsis.tender.test.\(UUID().uuidString.prefix(8))"
        let directory = FileManager.default.temporaryDirectory.appending(path: label)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let plist = directory.appending(path: "\(label).plist")
        try PlistRenderer().render(
            label: label,
            programArguments: ["/bin/sleep", "1000"],
            stdoutPath: directory.appending(path: "out.log").path(),
            stderrPath: directory.appending(path: "err.log").path(),
            throttleInterval: 1
        ).write(to: plist)
        defer {
            let cleanup = Process()
            cleanup.executableURL = URL(filePath: "/bin/launchctl")
            cleanup.arguments = ["bootout", "\(launchctl.domain.target)/\(label)"]
            cleanup.standardError = FileHandle.nullDevice
            try? cleanup.run()
            cleanup.waitUntilExit()
            try? FileManager.default.removeItem(at: directory)
        }

        #expect(try await launchctl.print(label: label) == nil)
        try await launchctl.bootstrap(plistURL: plist)

        await #expect(throws: LaunchctlError.alreadyLoaded(label)) {
            try await launchctl.bootstrap(plistURL: plist)
        }
        #expect(try await launchctl.listLabels(prefix: "com.olympsis.tender.test.").contains(label))

        let first = try #require(try await poll {
            let info = try await launchctl.print(label: label)
            return info?.state == .running ? info : nil
        })
        let firstPid = try #require(first.pid)
        #expect(first.restarts == 0)

        kill(firstPid, SIGKILL)
        let second = try #require(try await poll {
            let info = try await launchctl.print(label: label)
            return info?.state == .running && info?.pid != firstPid ? info : nil
        })
        #expect(second.restarts == 1)
        #expect(second.lastTerminatingSignal != nil)

        try await launchctl.kickstart(label: label, kill: true)
        let third = try #require(try await poll {
            let info = try await launchctl.print(label: label)
            return info?.state == .running && info?.pid != second.pid ? info : nil
        })
        #expect(third.restarts == 2)

        try await launchctl.bootout(label: label)
        #expect(try await poll { try await launchctl.print(label: label) == nil ? true : nil } == true)
        await #expect(throws: LaunchctlError.self) { try await launchctl.bootout(label: label) }
    }

    @Test func disableAndEnableSucceed() async throws {
        // A fixed label: launchd keeps enable/disable overrides forever, so a
        // unique one would add a new entry on every run.
        let label = "com.olympsis.tender.test.overrides"
        try await launchctl.disable(label: label)
        try await launchctl.enable(label: label)
    }
}
