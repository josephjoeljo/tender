import Foundation
import TenderCore

/// An environment in a unique temp directory. Labels stay under the test prefix,
/// so tests can never touch a real managed job.
func makeTestEnvironment() throws -> TenderEnvironment {
    let root = URL(filePath: "/tmp/tender-test-\(UUID().uuidString.prefix(8))")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    return TenderEnvironment(
        mode: .development,
        root: root,
        logsDirectory: root.appending(path: "logs"),
        plistDirectory: root.appending(path: "agents"),
        serviceLabelPrefix: "com.olympsis.tender.test.svc.\(UUID().uuidString.prefix(8))"
    )
}
