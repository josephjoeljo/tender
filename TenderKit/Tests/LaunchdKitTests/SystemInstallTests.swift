import Foundation
import Testing
import TenderCore
@testable import LaunchdKit

private let plan = SystemInstallPlan()

@Test func parsesDsclListings() {
    let ids = SystemInstallPlan.parseIDs("_www   70\nroot 0\n\ngarbage\nmy user 501\n")
    #expect(ids["_www"] == 70)
    #expect(ids["root"] == 0)
    #expect(ids["garbage"] == nil)
    #expect(ids["my"] == 501)
}

@Test func freeIDSkipsBothUsersAndGroups() {
    #expect(SystemInstallPlan.freeID(users: ["a": 400], groups: ["b": 401]) == 402)
    let full = Dictionary(uniqueKeysWithValues: SystemInstallPlan.idRange.map { ("u\($0)", $0) })
    #expect(SystemInstallPlan.freeID(users: full, groups: [:]) == nil)
}

@Test func createsAccountOnAFreshMac() throws {
    let commands = try plan.commands(users: ["root": 0], groups: ["wheel": 0], tenderdSource: "/b/tenderd")
    let text = commands.map(\.description)
    #expect(text.contains("/usr/bin/dscl . -create /Users/_tender UniqueID 400"))
    #expect(text.contains("/usr/bin/dscl . -create /Groups/_tender PrimaryGroupID 400"))
    #expect(text.contains("/usr/bin/dscl . -create /Users/_tender UserShell /usr/bin/false"))
    #expect(text.contains("/usr/bin/dscl . -create /Users/_tender IsHidden 1"))
}

@Test func rerunDoesNotRecreateTheAccount() throws {
    let commands = try plan.commands(users: ["_tender": 400], groups: ["_tender": 400], tenderdSource: "/b/tenderd")
    #expect(!commands.contains { $0.executable == "/usr/bin/dscl" })
}

@Test func missingUserReusesExistingGroup() throws {
    let text = try plan.commands(users: [:], groups: ["_tender": 410], tenderdSource: "/b/tenderd").map(\.description)
    #expect(text.contains("/usr/bin/dscl . -create /Users/_tender UniqueID 410"))
    #expect(text.contains("/usr/bin/dscl . -create /Users/_tender PrimaryGroupID 410"))
    #expect(!text.contains { $0.contains("/Groups/") })
}

@Test func uidAvoidsAnIDTakenByAnotherUser() throws {
    let text = try plan.commands(users: ["other": 410], groups: ["_tender": 410], tenderdSource: "/b/tenderd").map(\.description)
    #expect(text.contains("/usr/bin/dscl . -create /Users/_tender UniqueID 400"))
    #expect(text.contains("/usr/bin/dscl . -create /Users/_tender PrimaryGroupID 410"))
}

@Test func directoriesAreRootOwnedAndTheSocketDirectoryIsPrivate() throws {
    let text = try plan.commands(users: [:], groups: [:], tenderdSource: "/b/tenderd").map(\.description)
    for path in ["/opt/tender/", "/opt/tender/bin/", "/opt/tender/releases/", "/var/log/tender/", "/etc/tender/"] {
        let cleaned = path.hasSuffix("/") ? String(path.dropLast()) : path
        #expect(text.contains { $0.hasPrefix("/usr/bin/install -d -o root -g wheel -m 755 \(cleaned)") })
    }
    #expect(text.contains { $0.hasPrefix("/usr/bin/install -d -o root -g wheel -m 700 /opt/tender/run") })
}

@Test func daemonIsInstalledAtomicallyFromARootOwnedPath() throws {
    let text = try plan.commands(users: [:], groups: [:], tenderdSource: "/b/tenderd").map(\.description)
    #expect(text.contains("/usr/bin/install -S -o root -g wheel -m 755 /b/tenderd /opt/tender/libexec/tenderd"))

    let plist = try #require(
        try PropertyListSerialization.propertyList(from: try plan.renderDaemonPlist(), format: nil) as? [String: Any])
    #expect(plist["Label"] as? String == "com.olympsis.tender.agent")
    #expect(plist["ProgramArguments"] as? [String] == ["/opt/tender/libexec/tenderd", "--role", "worker"])
    #expect(plist["UserName"] == nil, "tenderd itself runs as root; only managed processes are _tender")
}

@Test func toolRunnerCapturesOutput() async throws {
    let result = try await ProcessLaunchctlRunner.runTool(executable: "/bin/sh", arguments: ["-c", "echo out; echo err >&2; exit 3"])
    #expect(result.exitCode == 3)
    #expect(result.stdout == "out\n")
    #expect(result.stderr == "err\n")
}
