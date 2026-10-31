import Foundation
import Testing
@testable import LaunchdKit

@Test func rendersKeepAlivePlist() throws {
    let data = try PlistRenderer().render(
        label: "com.olympsis.tender.test.echo",
        programArguments: ["/bin/echo", "hi"],
        stdoutPath: "/tmp/echo.out",
        stderrPath: "/tmp/echo.err"
    )
    let plist = try #require(
        try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
    )
    #expect(plist["Label"] as? String == "com.olympsis.tender.test.echo")
    #expect(plist["KeepAlive"] as? Bool == true)
}
