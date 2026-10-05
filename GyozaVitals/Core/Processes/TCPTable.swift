import Darwin
import Foundation

/// One TCP connection as the kernel's table lists it, with the pid that
/// last touched its socket. Unlike a per-process socket read, this does not
/// need the process to be alive: a connection in TIME_WAIT keeps its pid
/// for 2 MSL (30 s on macOS) after the process that made it has exited.
nonisolated struct TCPTableEntry: Hashable, Sendable {
    /// `t_state` of the connection (netinet/tcp_fsm.h).
    nonisolated enum State: Int32, Hashable, Sendable {
        case closed = 0, listening, synSent, synReceived, established, closeWait, finWait1, closing, lastAck, finWait2, timeWait
    }

    let state: State
    let localPort: Int
    let remotePort: Int
    let localIsLoopback: Bool
    let remoteIsLoopback: Bool
    /// `so_last_pid`: the process that last operated on the socket; for a
    /// client connection, the client, alive or not.
    let lastPID: pid_t
    /// `so_e_pid`: the pid a delegated socket acts for; nil when the socket
    /// was not delegated (the kernel reports 0 then, the usual case). Never
    /// a stand-in for `lastPID`.
    let effectivePID: pid_t?

    /// A client of one of the ports over loopback, in any state but listening.
    func isClient(of ports: Set<Int>) -> Bool {
        state != .listening && ports.contains(remotePort) && (remoteIsLoopback || localIsLoopback)
    }
}

/// Reads the kernel's TCP connection table, `net.inet.tcp.pcblist_n`, the
/// sysctl netstat uses. Readable without root. Read-only.
///
/// The buffer is an `xinpgen` header, then for each connection a group of
/// records, then an `xinpgen` trailer. Every record starts with a 32-bit
/// length and a 32-bit kind (`XSO_*`), and the kernel advances by the
/// length rounded up to 8 (`ADVANCE64` in bsd/netinet/in_pcblist.c). The
/// records of one connection come in the order INPCB, SOCKET, RCVBUF,
/// SNDBUF, STATS, TCPCB; the reader chains by length and kind and does not
/// depend on the order beyond "INPCB starts a connection".
///
/// The record structs (`xinpcb_n`, `xtcpcb_n`, `xsocket_n`) and the `XSO_*`
/// kinds are `#ifdef PRIVATE` in xnu and absent from the public SDK, so the
/// fields are read at offsets derived from the struct definitions. All
/// three are declared under `#pragma pack(4)`, so 64-bit fields are
/// 4-aligned; the offsets below follow from that (verified against xnu's
/// bsd/netinet/in_pcb.h, bsd/sys/socketvar.h and bsd/netinet/tcp_var.h,
/// and by the real test against the running kernel).
///
/// ```
/// struct xinpgen (24 bytes)               struct xsocket_n (XSO_SOCKET, 0x001)
///   0 u32 xig_len                           0 u32 xso_len      52 u16 so_error
///   4 u32 xig_count                         4 u32 xso_kind     56 i32 so_pgid
///   8 u64 xig_gen                           8 u64 xso_so       60 u32 so_oobmark
///  16 u64 xig_sogen                        16 i16 so_type      64 u32 so_uid
///                                          20 u32 so_options   68 i32 so_last_pid
/// struct xinpcb_n (XSO_INPCB, 0x010)       24 i16 so_linger    72 i32 so_e_pid
///   0 u32 xi_len                           26 i16 so_state     76 u64 so_gencnt
///   4 u32 xi_kind                          28 u64 so_pcb       84 u32 so_flags
///   8 u64 xi_inpp                          36 i32 xso_protocol 88 u32 so_flags1
///  16 u16 inp_fport (network order)        40 i32 xso_family   92 i32 so_usecount
///  18 u16 inp_lport (network order)        44 i16 so_qlen      96 i32 so_retaincnt
///  20 u64 inp_ppcb                         46 i16 so_incqlen  100 u32 xso_filter_flags
///  28 u64 inp_gencnt                       48 i16 so_qlimit   104 = sizeof
///  36 i32 inp_flags                        50 i16 so_timeo
///  40 u32 inp_flow
///  44 u8  inp_vflag (INP_IPV4 1, INP_IPV6 2)
///  45 u8  inp_ip_ttl                     struct xtcpcb_n (XSO_TCPCB, 0x020)
///  46 u8  inp_ip_p                         0 u32 xt_len
///  48 [16] inp_dependfaddr                 4 u32 xt_kind
///         (in6_addr, or 12 bytes of        8 u64 t_segq
///          padding then the in_addr)      16 i32 t_dupacks
///  64 [16] inp_dependladdr                20 i32 t_timer[4]
///  80 u8  inp_depend4.inp4_ip_tos         36 i32 t_state
///  84 inp_depend6 (hlim, cksum, ifindex,  40 ... (the rest is unused here)
///         hops: 12 bytes)
///  96 u32 inp_flowhash
/// 100 u32 inp_flags2
/// 104 = sizeof
/// ```
nonisolated enum TCPTable {
    static let sysctlName = "net.inet.tcp.pcblist_n"

    /// Record kinds (sys/socketvar.h, PRIVATE).
    static let kindSocket: UInt32 = 0x001
    static let kindInPCB: UInt32 = 0x010
    static let kindTCPCB: UInt32 = 0x020

    /// sizeof(struct xinpgen): the header and the trailer, and the only
    /// record this short; netstat stops at it, so does this.
    static let headerLength = 24

    /// Field offsets in `xinpcb_n`.
    nonisolated enum InPCB {
        static let foreignPort = 16
        static let localPort = 18
        static let vflag = 44
        static let foreignAddress = 48
        static let localAddress = 64
        /// Enough to hold the fields read here.
        static let minimumLength = 80
    }

    /// Field offsets in `xtcpcb_n`.
    nonisolated enum TCPCB {
        static let state = 36
        static let minimumLength = 40
    }

    /// Field offsets in `xsocket_n`.
    nonisolated enum Socket {
        static let lastPID = 68
        static let effectivePID = 72
        static let minimumLength = 76
    }

    static let ipv4Flag: UInt8 = 0x1

    /// Every TCP connection on the system right now. Empty when the sysctl
    /// refuses (it never has for a user process) or the table changed under
    /// the read twice in a row.
    static func read() -> [TCPTableEntry] {
        var needed = 0
        guard sysctlbyname(sysctlName, nil, &needed, nil, 0) == 0, needed > 0 else { return [] }
        // The kernel's estimate already carries slack (n + n/8 items); add a
        // little more and try twice in case the table grew meanwhile.
        for attempt in 0..<2 {
            var size = needed + 32 * 1024 * (attempt + 1)
            var buffer = [UInt8](repeating: 0, count: size)
            let status = buffer.withUnsafeMutableBytes { raw in sysctlbyname(sysctlName, raw.baseAddress, &size, nil, 0) }
            if status == 0 { return parse(Array(buffer.prefix(size))) }
            guard errno == ENOMEM else { return [] }
            _ = sysctlbyname(sysctlName, nil, &needed, nil, 0)
        }
        return []
    }

    /// The connections in a `pcblist_n` buffer.
    static func parse(_ bytes: [UInt8]) -> [TCPTableEntry] {
        bytes.withUnsafeBytes { parse($0) }
    }

    static func parse(_ raw: UnsafeRawBufferPointer) -> [TCPTableEntry] {
        guard raw.count >= headerLength else { return [] }
        var entries: [TCPTableEntry] = []
        var offset = roundedUp(Int(u32(raw, 0)))
        guard offset >= headerLength else { return [] }
        var pending: PendingConnection?
        while offset + 8 <= raw.count {
            let length = Int(u32(raw, offset))
            let kind = u32(raw, offset + 4)
            // The trailer, or garbage: stop.
            guard length > headerLength, offset + length <= raw.count else { break }
            let record = UnsafeRawBufferPointer(rebasing: raw[offset..<offset + length])
            switch kind {
            case kindInPCB:
                if let entry = pending?.entry { entries.append(entry) }
                pending = PendingConnection(inpcb: record)
            case kindSocket:
                pending?.read(socket: record)
            case kindTCPCB:
                pending?.read(tcpcb: record)
            default:
                break
            }
            offset += roundedUp(length)
        }
        if let entry = pending?.entry { entries.append(entry) }
        return entries
    }

    /// Entries that are clients of the ports: loopback, not listening.
    static func clients(of ports: Set<Int>, in entries: [TCPTableEntry]) -> [TCPTableEntry] {
        guard !ports.isEmpty else { return [] }
        return entries.filter { $0.isClient(of: ports) }
    }

    // MARK: Records

    /// One connection's records as they arrive; an entry once the INPCB,
    /// TCPCB and SOCKET records are all in (the kernel always writes all
    /// three, or none of them).
    private nonisolated struct PendingConnection {
        var localPort = 0
        var remotePort = 0
        var localIsLoopback = false
        var remoteIsLoopback = false
        var state: TCPTableEntry.State?
        var pids: (last: pid_t, effective: pid_t)?

        init?(inpcb raw: UnsafeRawBufferPointer) {
            guard raw.count >= InPCB.minimumLength else { return nil }
            remotePort = Int(UInt16(bigEndian: raw.loadUnaligned(fromByteOffset: InPCB.foreignPort, as: UInt16.self)))
            localPort = Int(UInt16(bigEndian: raw.loadUnaligned(fromByteOffset: InPCB.localPort, as: UInt16.self)))
            let ipv6 = raw[InPCB.vflag] & ipv4Flag == 0
            remoteIsLoopback = InetAddress.isLoopback(UnsafeRawBufferPointer(rebasing: raw[InPCB.foreignAddress..<InPCB.foreignAddress + 16]), ipv6: ipv6)
            localIsLoopback = InetAddress.isLoopback(UnsafeRawBufferPointer(rebasing: raw[InPCB.localAddress..<InPCB.localAddress + 16]), ipv6: ipv6)
        }

        mutating func read(tcpcb raw: UnsafeRawBufferPointer) {
            guard raw.count >= TCPCB.minimumLength else { return }
            state = TCPTableEntry.State(rawValue: raw.loadUnaligned(fromByteOffset: TCPCB.state, as: Int32.self)) ?? .closed
        }

        mutating func read(socket raw: UnsafeRawBufferPointer) {
            guard raw.count >= Socket.minimumLength else { return }
            pids = (raw.loadUnaligned(fromByteOffset: Socket.lastPID, as: pid_t.self),
                    raw.loadUnaligned(fromByteOffset: Socket.effectivePID, as: pid_t.self))
        }

        var entry: TCPTableEntry? {
            guard let state, let pids else { return nil }
            return TCPTableEntry(state: state, localPort: localPort, remotePort: remotePort, localIsLoopback: localIsLoopback,
                                 remoteIsLoopback: remoteIsLoopback, lastPID: pids.last, effectivePID: pids.effective > 0 ? pids.effective : nil)
        }
    }

    private static func u32(_ raw: UnsafeRawBufferPointer, _ offset: Int) -> UInt32 {
        raw.loadUnaligned(fromByteOffset: offset, as: UInt32.self)
    }

    /// ROUNDUP64: records are laid out on 8-byte boundaries.
    static func roundedUp(_ length: Int) -> Int {
        (length + 7) & ~7
    }
}

/// The 16-byte address slot the kernel uses for both families: an in6_addr,
/// or 12 bytes of padding followed by an in_addr (in_addr_4in6). Network
/// byte order either way.
nonisolated enum InetAddress {
    static func isLoopback(_ raw: UnsafeRawBufferPointer, ipv6: Bool) -> Bool {
        guard raw.count >= 16 else { return false }
        if ipv6 {
            let isV6Loopback = raw[0..<15].allSatisfy { $0 == 0 } && raw[15] == 1
            let isMappedV4Loopback = raw[0..<10].allSatisfy { $0 == 0 } && raw[10] == 0xff && raw[11] == 0xff && raw[12] == 127
            return isV6Loopback || isMappedV4Loopback
        }
        return raw[12] == 127
    }
}
