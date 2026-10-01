import Darwin
import Foundation

// What a process holds: mapped files, open files, TCP sockets, working
// directory. All through proc_pidinfo / proc_pidfdinfo, all same-user only.

/// One TCP socket of a process, as the kernel reports it.
nonisolated struct TCPSocket: Hashable, Sendable {
    nonisolated enum State: Hashable, Sendable { case listening, established, other }
    let state: State
    let localPort: Int
    let remotePort: Int
    let localIsLoopback: Bool
    let remoteIsLoopback: Bool
}

nonisolated enum ProcessFiles {
    /// PROC_PIDREGIONPATHINFO2 in <sys/proc_info.h>: like PROC_PIDREGIONPATHINFO,
    /// it returns the region at or after the given address with its vnode path.
    private static let regionPathInfo2: Int32 = 22

    /// Paths of every file-backed memory region, in address order, unique.
    /// llama.cpp, MLX and ComfyUI mmap their weights, so this is where model
    /// files show up. Empty for another user's process.
    static func mappedFiles(pid: pid_t, maximumRegions: Int = 60_000) -> [String] {
        // ~1.5 KB per call; keep it off the stack and reuse it.
        let info = UnsafeMutablePointer<proc_regionwithpathinfo>.allocate(capacity: 1)
        info.initialize(to: proc_regionwithpathinfo())
        defer {
            info.deinitialize(count: 1)
            info.deallocate()
        }
        let size = Int32(MemoryLayout<proc_regionwithpathinfo>.size)
        var seen = Set<String>()
        var paths: [String] = []
        var address: UInt64 = 0
        for _ in 0..<maximumRegions {
            let got = proc_pidinfo(pid, regionPathInfo2, address, info, size)
            guard got > 0 else { break }
            let region = info.pointee.prp_prinfo
            let path = CStrings.string(info.pointee.prp_vip.vip_path)
            if !path.isEmpty, seen.insert(path).inserted { paths.append(path) }
            let next = region.pri_address &+ region.pri_size
            guard next > address else { break }
            address = next
        }
        return paths
    }

    /// The process's file descriptors with their types.
    static func fileDescriptors(pid: pid_t) -> [proc_fdinfo] {
        let bytes = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, nil, 0)
        guard bytes > 0 else { return [] }
        let stride = MemoryLayout<proc_fdinfo>.stride
        var descriptors = [proc_fdinfo](repeating: proc_fdinfo(), count: Int(bytes) / stride + 16)
        let got = descriptors.withUnsafeMutableBytes { raw in
            proc_pidinfo(pid, PROC_PIDLISTFDS, 0, raw.baseAddress, Int32(raw.count))
        }
        guard got > 0 else { return [] }
        return Array(descriptors.prefix(Int(got) / stride))
    }

    /// Paths of open regular files (vnodes), unique. For runtimes that read
    /// their weights instead of mapping them.
    static func openFiles(pid: pid_t) -> [String] {
        var seen = Set<String>()
        var paths: [String] = []
        let size = Int32(MemoryLayout<vnode_fdinfowithpath>.size)
        for descriptor in fileDescriptors(pid: pid) where descriptor.proc_fdtype == UInt32(PROX_FDTYPE_VNODE) {
            var info = vnode_fdinfowithpath()
            let got = withUnsafeMutablePointer(to: &info) {
                proc_pidfdinfo(pid, descriptor.proc_fd, PROC_PIDFDVNODEPATHINFO, $0, size)
            }
            guard got == size else { continue }
            let path = CStrings.string(info.pvip.vip_path)
            if !path.isEmpty, seen.insert(path).inserted { paths.append(path) }
        }
        return paths
    }

    /// The process's TCP sockets: listening ports and live connections.
    static func sockets(pid: pid_t) -> [TCPSocket] {
        var sockets: [TCPSocket] = []
        let size = Int32(MemoryLayout<socket_fdinfo>.size)
        for descriptor in fileDescriptors(pid: pid) where descriptor.proc_fdtype == UInt32(PROX_FDTYPE_SOCKET) {
            var info = socket_fdinfo()
            let got = withUnsafeMutablePointer(to: &info) {
                proc_pidfdinfo(pid, descriptor.proc_fd, PROC_PIDFDSOCKETINFO, $0, size)
            }
            guard got == size, info.psi.soi_kind == SOCKINFO_TCP else { continue }
            let tcp = info.psi.soi_proto.pri_tcp
            let inet = tcp.tcpsi_ini
            let state: TCPSocket.State
            switch tcp.tcpsi_state {
            case TSI_S_LISTEN: state = .listening
            case TSI_S_ESTABLISHED: state = .established
            default: state = .other
            }
            let isIPv6 = (Int32(inet.insi_vflag) & INI_IPV6) != 0
            sockets.append(TCPSocket(
                state: state,
                localPort: port(inet.insi_lport),
                remotePort: port(inet.insi_fport),
                localIsLoopback: isLoopback(inet.insi_laddr, ipv6: isIPv6),
                remoteIsLoopback: isLoopback(inet.insi_faddr, ipv6: isIPv6)))
        }
        return sockets
    }

    /// Ports the process accepts connections on.
    static func listeningPorts(pid: pid_t) -> [Int] {
        Array(Set(sockets(pid: pid).filter { $0.state == .listening }.map(\.localPort))).sorted()
    }

    /// The process's current working directory, to resolve relative paths in its argv.
    static func currentDirectory(pid: pid_t) -> String? {
        var info = vnode_pathinfo()
        let size = Int32(MemoryLayout<vnode_pathinfo>.size)
        let got = withUnsafeMutablePointer(to: &info) { proc_pidinfo(pid, PROC_PIDVNODEPATHINFO, 0, $0, size) }
        guard got == size else { return nil }
        let path = CStrings.string(info.pvi_cdir.vip_path)
        return path.isEmpty ? nil : path
    }

    // MARK: Byte order

    /// insi_lport / insi_fport carry the 16-bit port in network byte order.
    private static func port(_ raw: Int32) -> Int {
        Int(UInt16(bigEndian: UInt16(truncatingIfNeeded: raw)))
    }

    /// The address union is 16 bytes: an in6_addr, or 12 bytes of padding
    /// followed by an in_addr (in4in6_addr). Both are in network byte order.
    private static func isLoopback<T>(_ address: T, ipv6: Bool) -> Bool {
        withUnsafeBytes(of: address) { raw -> Bool in
            guard raw.count >= 16 else { return false }
            if ipv6 {
                let isV6Loopback = raw[0..<15].allSatisfy { $0 == 0 } && raw[15] == 1
                let isMappedV4Loopback = raw[0..<10].allSatisfy { $0 == 0 } && raw[10] == 0xff && raw[11] == 0xff && raw[12] == 127
                return isV6Loopback || isMappedV4Loopback
            }
            return raw[12] == 127
        }
    }
}
