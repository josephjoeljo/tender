import Darwin
import Foundation
import Testing
import TenderCore
@testable import ProcessMetrics

/// Binds a TCP socket to 127.0.0.1 on a free port and listens. Returns the fd and port.
private func listen() throws -> (fd: Int32, port: Int) {
    let fd = socket(AF_INET, SOCK_STREAM, 0)
    try #require(fd >= 0)
    var address = sockaddr_in()
    address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
    address.sin_family = sa_family_t(AF_INET)
    address.sin_addr.s_addr = inet_addr("127.0.0.1")
    address.sin_port = 0
    let bound = withUnsafePointer(to: &address) {
        $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
    }
    try #require(bound == 0)
    try #require(Darwin.listen(fd, 1) == 0)
    var length = socklen_t(MemoryLayout<sockaddr_in>.size)
    _ = withUnsafeMutablePointer(to: &address) {
        $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &length) }
    }
    return (fd, Int(UInt16(bigEndian: address.sin_port)))
}

@Test func findsAListeningPortAndAnOpenFile() throws {
    let (socketFD, port) = try listen()
    defer { close(socketFD) }
    let path = FileManager.default.temporaryDirectory.appending(path: "tender-descriptors-\(UUID().uuidString)")
        .path(percentEncoded: false)
    let fileFD = open(path, O_CREAT | O_RDWR, 0o600)
    try #require(fileFD >= 0)
    defer { close(fileFD); unlink(path) }

    let snapshot = try #require(DescriptorReader.read(pid: getpid()))
    #expect(snapshot.ports.contains(ListeningPort(proto: .tcp, address: "127.0.0.1", port: port, pid: getpid())))
    // /var is a symlink to /private/var, and libproc reports the resolved path.
    let file = try #require(snapshot.files.first { $0.fd == fileFD })
    #expect(file.path.hasSuffix(URL(filePath: path).lastPathComponent))
    #expect(file.mode == .readWrite)
    #expect((snapshot.counts[.socket] ?? 0) >= 1)
    #expect((snapshot.counts[.file] ?? 0) >= 1)
}

@Test func mergesAndBoundsWhatItReturns() throws {
    let (socketFD, port) = try listen()
    defer { close(socketFD) }
    let descriptors = try #require(DescriptorReader.read(service: "tests", instance: 0, node: NodeID("local"), pid: getpid()))
    #expect(descriptors.ports.contains { $0.port == port && $0.proto == .tcp })
    #expect(descriptors.files.count <= ProcessDescriptors.fileLimit)
    #expect(descriptors.total >= descriptors.files.count)
    // Most first.
    #expect(descriptors.counts.map(\.count) == descriptors.counts.map(\.count).sorted(by: >))
}

@Test func goneProcessIsNil() {
    #expect(DescriptorReader.read(pid: 999_999) == nil)
}

@Test func endpointsBracketIPv6() {
    #expect(ListeningPort(proto: .tcp, address: "::1", port: 80, pid: 1).endpoint == "[::1]:80")
    #expect(ListeningPort(proto: .tcp, address: "*", port: 80, pid: 1).endpoint == "*:80")
}
