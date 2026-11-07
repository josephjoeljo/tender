import Darwin
import Foundation
import TenderCore

/// Reads what a process holds open through libproc: listening ports, open files and a
/// count of every descriptor. Needs the same user as the process, or root.
public enum DescriptorReader {
    /// One process's descriptors, or nil when it's gone or can't be read.
    public struct Snapshot: Sendable, Equatable {
        public var ports: [ListeningPort] = []
        public var files: [OpenFile] = []
        public var counts: [DescriptorCount.Kind: Int] = [:]
    }

    /// `pid` and its descendants, merged. A child that can't be read is counted in
    /// `unreadable`; a root that can't be read gives nil.
    public static func read(service: String, instance: Int, node: NodeID, pid: Int32) -> ProcessDescriptors? {
        guard let root = read(pid: pid) else { return nil }
        var snapshots = [root]
        var unreadable = 0
        for child in ProcessTree.descendants(of: pid) {
            if let snapshot = read(pid: child) { snapshots.append(snapshot) } else { unreadable += 1 }
        }
        var ports = Set<ListeningPort>()
        var files: [OpenFile] = []
        var counts: [DescriptorCount.Kind: Int] = [:]
        for snapshot in snapshots {
            ports.formUnion(snapshot.ports)
            files += snapshot.files
            counts.merge(snapshot.counts, uniquingKeysWith: +)
        }
        let sortedFiles = files.sorted { ($0.pid, $0.fd) < ($1.pid, $1.fd) }
        return ProcessDescriptors(
            service: service, instance: instance, node: node, pid: pid,
            ports: ports.sorted { ($0.port, $0.proto.rawValue, $0.address, $0.pid) < ($1.port, $1.proto.rawValue, $1.address, $1.pid) },
            files: Array(sortedFiles.prefix(ProcessDescriptors.fileLimit)),
            filesOmitted: max(sortedFiles.count - ProcessDescriptors.fileLimit, 0),
            counts: counts.map { DescriptorCount(kind: $0.key, count: $0.value) }
                .sorted { ($1.count, $0.kind.rawValue) < ($0.count, $1.kind.rawValue) },
            unreadable: unreadable)
    }

    public static func read(pid: Int32) -> Snapshot? {
        guard let fds = descriptors(of: pid) else { return nil }
        var snapshot = Snapshot()
        for fd in fds {
            switch Int32(fd.proc_fdtype) {
            case PROX_FDTYPE_VNODE:
                snapshot.counts[.file, default: 0] += 1
                if let file = file(pid: pid, fd: fd.proc_fd) { snapshot.files.append(file) }
            case PROX_FDTYPE_SOCKET:
                snapshot.counts[.socket, default: 0] += 1
                if let port = listeningPort(pid: pid, fd: fd.proc_fd) { snapshot.ports.append(port) }
            case PROX_FDTYPE_PIPE:
                snapshot.counts[.pipe, default: 0] += 1
            case PROX_FDTYPE_KQUEUE:
                snapshot.counts[.kqueue, default: 0] += 1
            default:
                snapshot.counts[.other, default: 0] += 1
            }
        }
        return snapshot
    }

    static func descriptors(of pid: Int32) -> [proc_fdinfo]? {
        // With no buffer, libproc returns a size with room to spare; the second call returns the real one.
        let estimate = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, nil, 0)
        guard estimate > 0 else { return nil }
        let stride = MemoryLayout<proc_fdinfo>.stride
        var buffer = [proc_fdinfo](repeating: proc_fdinfo(), count: Int(estimate) / stride + 1)
        let used = buffer.withUnsafeMutableBytes {
            proc_pidinfo(pid, PROC_PIDLISTFDS, 0, $0.baseAddress, Int32($0.count))
        }
        guard used > 0 else { return nil }
        return Array(buffer.prefix(Int(used) / stride))
    }

    static func file(pid: Int32, fd: Int32) -> OpenFile? {
        var info = vnode_fdinfowithpath()
        let size = Int32(MemoryLayout<vnode_fdinfowithpath>.size)
        guard proc_pidfdinfo(pid, fd, PROC_PIDFDVNODEPATHINFO, &info, size) == size else { return nil }
        let path = withUnsafeBytes(of: info.pvip.vip_path) { bytes in
            String(decoding: bytes.prefix { $0 != 0 }, as: UTF8.self)
        }
        guard !path.isEmpty else { return nil }
        let flags = info.pfi.fi_openflags
        let mode: OpenFile.Mode = switch (flags & UInt32(FREAD) != 0, flags & UInt32(FWRITE) != 0) {
        case (true, true): .readWrite
        case (false, true): .write
        default: .read
        }
        return OpenFile(fd: fd, path: path, mode: mode, pid: pid)
    }

    /// A TCP socket in LISTEN, or a UDP socket bound to a port. Connected and Unix sockets give nil.
    static func listeningPort(pid: Int32, fd: Int32) -> ListeningPort? {
        var info = socket_fdinfo()
        let size = Int32(MemoryLayout<socket_fdinfo>.size)
        guard proc_pidfdinfo(pid, fd, PROC_PIDFDSOCKETINFO, &info, size) == size else { return nil }
        let socket = info.psi
        let inet: in_sockinfo
        let proto: ListeningPort.Proto
        switch socket.soi_kind {
        case Int32(SOCKINFO_TCP):
            guard socket.soi_proto.pri_tcp.tcpsi_state == TSI_S_LISTEN else { return nil }
            inet = socket.soi_proto.pri_tcp.tcpsi_ini
            proto = .tcp
        case Int32(SOCKINFO_IN) where socket.soi_protocol == IPPROTO_UDP:
            inet = socket.soi_proto.pri_in
            proto = .udp
        default:
            return nil
        }
        let port = Int(UInt16(bigEndian: UInt16(truncatingIfNeeded: inet.insi_lport)))
        guard port != 0 else { return nil }
        return ListeningPort(proto: proto, address: address(inet), port: port, pid: pid)
    }

    /// `*` for a wildcard bind, else the address as `inet_ntop` writes it.
    static func address(_ inet: in_sockinfo) -> String {
        var buffer = [CChar](repeating: 0, count: Int(INET6_ADDRSTRLEN))
        if inet.insi_vflag & UInt8(INI_IPV6) != 0 {
            var address = inet.insi_laddr.ina_6
            let isAny = withUnsafeBytes(of: address) { $0.allSatisfy { $0 == 0 } }
            if isAny { return "*" }
            guard inet_ntop(AF_INET6, &address, &buffer, socklen_t(buffer.count)) != nil else { return "?" }
        } else {
            var address = inet.insi_laddr.ina_46.i46a_addr4
            if address.s_addr == 0 { return "*" }
            guard inet_ntop(AF_INET, &address, &buffer, socklen_t(buffer.count)) != nil else { return "?" }
        }
        return String(cString: buffer)
    }
}
