import Foundation

/// What a running instance holds open: the ports it listens on, the files it has open,
/// and a count of every descriptor by kind. Covers the instance's child processes too,
/// since a service is often a script that starts the real server.
public struct ProcessDescriptors: Codable, Sendable, Equatable {
    public var service: String
    public var instance: Int
    public var node: NodeID
    /// The instance's own PID. Entries name the process that holds them.
    public var pid: Int32
    /// Listening TCP sockets and bound UDP sockets, by port.
    public var ports: [ListeningPort]
    /// Regular files, directories and devices, by path. At most `fileLimit`.
    public var files: [OpenFile]
    /// Files left out past the limit.
    public var filesOmitted: Int
    /// Every descriptor, by kind, most first.
    public var counts: [DescriptorCount]
    /// Child processes that couldn't be read, for example ones that exited mid-read.
    public var unreadable: Int

    public static let fileLimit = 500

    public init(service: String, instance: Int, node: NodeID, pid: Int32, ports: [ListeningPort] = [],
                files: [OpenFile] = [], filesOmitted: Int = 0, counts: [DescriptorCount] = [], unreadable: Int = 0) {
        self.service = service
        self.instance = instance
        self.node = node
        self.pid = pid
        self.ports = ports
        self.files = files
        self.filesOmitted = filesOmitted
        self.counts = counts
        self.unreadable = unreadable
    }

    /// All descriptors across the instance and its children.
    public var total: Int { counts.reduce(0) { $0 + $1.count } }
}

public struct ListeningPort: Codable, Sendable, Equatable, Hashable {
    public enum Proto: String, Codable, Sendable { case tcp, udp }

    public var proto: Proto
    /// `*` for every interface, else the bound address (`127.0.0.1`, `::1`, a tailnet IP).
    public var address: String
    public var port: Int
    public var pid: Int32

    public init(proto: Proto, address: String, port: Int, pid: Int32) {
        self.proto = proto
        self.address = address
        self.port = port
        self.pid = pid
    }

    /// `127.0.0.1:8080`, `[::1]:8080`, `*:8080`.
    public var endpoint: String {
        address.contains(":") ? "[\(address)]:\(port)" : "\(address):\(port)"
    }
}

public struct OpenFile: Codable, Sendable, Equatable {
    public enum Mode: String, Codable, Sendable { case read = "r", write = "w", readWrite = "rw" }

    public var fd: Int32
    public var path: String
    public var mode: Mode
    public var pid: Int32

    public init(fd: Int32, path: String, mode: Mode, pid: Int32) {
        self.fd = fd
        self.path = path
        self.mode = mode
        self.pid = pid
    }
}

public struct DescriptorCount: Codable, Sendable, Equatable {
    public enum Kind: String, Codable, Sendable, CaseIterable {
        case file, socket, pipe, kqueue, other
    }

    public var kind: Kind
    public var count: Int

    public init(kind: Kind, count: Int) {
        self.kind = kind
        self.count = count
    }
}
