import Darwin
import Foundation
import Testing
@testable import GyozaVitals

/// Numbers measured on the runner, for the CI log: printed, and appended
/// to a file the workflow prints after the tests (print alone doesn't
/// reach the xcodebuild log).
enum Measurements {
    static let directory = FileManager.default.temporaryDirectory.appendingPathComponent("gyozavitals-measurements", isDirectory: true)

    static func note(_ line: String) {
        print("[measure] \(line)")
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("measurements.txt")
        let data = Data((line + "\n").utf8)
        if let handle = try? FileHandle(forWritingTo: url) {
            handle.seekToEndOfFile()
            handle.write(data)
            try? handle.close()
        } else {
            try? data.write(to: url)
        }
    }
}

/// Plain BSD sockets on 127.0.0.1 for the tests that talk to themselves.
/// The tests connect to their own listener only, never to a runtime.
enum LoopbackSockets {
    /// A listening socket on a port of the kernel's choosing.
    static func listen() throws -> (fd: Int32, port: Int) {
        let server = socket(AF_INET, SOCK_STREAM, 0)
        try #require(server >= 0)
        var address = loopback(port: 0)
        let size = socklen_t(MemoryLayout<sockaddr_in>.size)
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(server, $0, size) }
        }
        try #require(bound == 0)
        try #require(Darwin.listen(server, 8) == 0)
        var length = size
        let named = withUnsafeMutablePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(server, $0, &length) }
        }
        try #require(named == 0)
        let port = Int(UInt16(bigEndian: address.sin_port))
        try #require(port > 0)
        return (server, port)
    }

    /// A connected client socket. A loopback connect completes without an
    /// accept; the connection waits in the listener's queue.
    static func connect(to port: Int) throws -> Int32 {
        let client = socket(AF_INET, SOCK_STREAM, 0)
        try #require(client >= 0)
        var address = loopback(port: port)
        let size = socklen_t(MemoryLayout<sockaddr_in>.size)
        let connected = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.connect(client, $0, size) }
        }
        try #require(connected == 0)
        return client
    }

    static func loopback(port: Int) -> sockaddr_in {
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = UInt16(port).bigEndian
        address.sin_addr.s_addr = UInt32(0x7f00_0001).bigEndian
        return address
    }
}

// MARK: - The kernel's TCP table

struct TCPTableTests {
    /// Builds a `pcblist_n` buffer the way bsd/netinet/in_pcblist.c does:
    /// an xinpgen, then per connection INPCB, SOCKET, RCVBUF, SNDBUF, STATS
    /// and TCPCB, each padded to 8 bytes, then an xinpgen trailer. The
    /// offsets here are written out from the struct definitions on their
    /// own, as a check on the reader's.
    private enum Kernel {
        static func put(_ value: UInt32, into bytes: inout [UInt8], at offset: Int) {
            for i in 0..<4 { bytes[offset + i] = UInt8((value >> (8 * i)) & 0xff) }
        }

        static func put(_ value: Int32, into bytes: inout [UInt8], at offset: Int) {
            put(UInt32(bitPattern: value), into: &bytes, at: offset)
        }

        /// Network byte order.
        static func put(port: UInt16, into bytes: inout [UInt8], at offset: Int) {
            bytes[offset] = UInt8(port >> 8)
            bytes[offset + 1] = UInt8(port & 0xff)
        }

        static func record(length: Int, kind: UInt32, fill: (inout [UInt8]) -> Void = { _ in }) -> [UInt8] {
            var bytes = [UInt8](repeating: 0, count: (length + 7) & ~7) // ADVANCE64
            put(UInt32(length), into: &bytes, at: 0)
            put(kind, into: &bytes, at: 4)
            fill(&bytes)
            return bytes
        }

        /// xinpgen: xig_len, xig_count, xig_gen, xig_sogen.
        static func generation(count: UInt32) -> [UInt8] {
            record(length: 24, kind: count)
        }

        static let v4Loopback: [UInt8] = [UInt8](repeating: 0, count: 12) + [127, 0, 0, 1]
        static let v4Lan: [UInt8] = [UInt8](repeating: 0, count: 12) + [192, 168, 1, 5]
        static let v6Loopback: [UInt8] = [UInt8](repeating: 0, count: 15) + [1]
        static let unspecified = [UInt8](repeating: 0, count: 16)

        static func connection(local: UInt16, localAddress: [UInt8], remote: UInt16, remoteAddress: [UInt8], ipv6: Bool,
                               state: Int32, lastPID: Int32, effectivePID: Int32, socket: Bool = true) -> [UInt8] {
            var bytes = record(length: 104, kind: 0x010) { inp in // xinpcb_n
                put(port: remote, into: &inp, at: 16) // inp_fport
                put(port: local, into: &inp, at: 18) // inp_lport
                inp[44] = ipv6 ? 0x2 : 0x1 // inp_vflag: INP_IPV6 / INP_IPV4
                for i in 0..<16 {
                    inp[48 + i] = remoteAddress[i] // inp_dependfaddr
                    inp[64 + i] = localAddress[i] // inp_dependladdr
                }
            }
            bytes += record(length: 104, kind: 0x001) { so in // xsocket_n: all zero when the socket is NULL
                guard socket else { return }
                put(Int32(getuid()), into: &so, at: 64) // so_uid
                put(lastPID, into: &so, at: 68) // so_last_pid
                put(effectivePID, into: &so, at: 72) // so_e_pid
            }
            bytes += record(length: 32, kind: 0x002) // xsockbuf_n, receive
            bytes += record(length: 32, kind: 0x004) // xsockbuf_n, send
            bytes += record(length: 136, kind: 0x008) // xsockstat_n
            bytes += record(length: 156, kind: 0x020) { tcp in // xtcpcb_n
                put(state, into: &tcp, at: 36) // t_state
            }
            return bytes
        }
    }

    @Test func parsesTheDocumentedRecordLayout() throws {
        var buffer = Kernel.generation(count: 3)
        // A helper's side of a finished poll: TIME_WAIT, its pid kept.
        buffer += Kernel.connection(local: 52_001, localAddress: Kernel.v4Loopback, remote: 1235, remoteAddress: Kernel.v4Loopback,
                                    ipv6: false, state: 10, lastPID: 38385, effectivePID: 38385)
        // The server, listening on IPv6.
        buffer += Kernel.connection(local: 1235, localAddress: Kernel.unspecified, remote: 0, remoteAddress: Kernel.unspecified,
                                    ipv6: true, state: 1, lastPID: 18226, effectivePID: 18226)
        // A LAN connection: not loopback either way.
        buffer += Kernel.connection(local: 52_002, localAddress: Kernel.v4Lan, remote: 443, remoteAddress: Kernel.v4Lan,
                                    ipv6: false, state: 4, lastPID: 7, effectivePID: 9)
        buffer += Kernel.generation(count: 3)
        buffer += [0xde, 0xad, 0xbe, 0xef] // nothing past the trailer is read

        let entries = TCPTable.parse(buffer)
        try #require(entries.count == 3, "\(entries)")
        #expect(entries[0] == TCPTableEntry(state: .timeWait, localPort: 52_001, remotePort: 1235, localIsLoopback: true,
                                            remoteIsLoopback: true, lastPID: 38385, effectivePID: 38385))
        #expect(entries[1] == TCPTableEntry(state: .listening, localPort: 1235, remotePort: 0, localIsLoopback: false,
                                            remoteIsLoopback: false, lastPID: 18226, effectivePID: 18226))
        #expect(entries[2] == TCPTableEntry(state: .established, localPort: 52_002, remotePort: 443, localIsLoopback: false,
                                            remoteIsLoopback: false, lastPID: 7, effectivePID: 9))
    }

    @Test func toleratesIPv6LoopbackUnknownKindsAndATruncatedTail() throws {
        var buffer = Kernel.generation(count: 2)
        buffer += Kernel.connection(local: 60_000, localAddress: Kernel.v6Loopback, remote: 8080, remoteAddress: Kernel.v6Loopback,
                                    ipv6: true, state: 5, lastPID: 41, effectivePID: 41)
        buffer += Kernel.record(length: 40, kind: 0x400) // a kind this reader doesn't know: skipped
        buffer += Kernel.connection(local: 60_001, localAddress: Kernel.v4Loopback, remote: 8080, remoteAddress: Kernel.v4Loopback,
                                    ipv6: false, state: 4, lastPID: 42, effectivePID: 42, socket: false)
        let whole = TCPTable.parse(buffer + Kernel.generation(count: 2))
        try #require(whole.count == 2)
        #expect(whole[0].state == .closeWait)
        #expect(whole[0].remoteIsLoopback && whole[0].localIsLoopback)
        #expect(whole[1].lastPID == 0, "a NULL socket leaves its pids zero")
        #expect(whole[1].effectivePID == nil, "and 0 reads as no delegate")

        // Cut inside the second connection: what was complete survives.
        let cut = TCPTable.parse(Array(buffer.prefix(buffer.count - 60)))
        #expect(cut.count == 1)
        #expect(cut.first?.lastPID == 41)
        #expect(TCPTable.parse([]).isEmpty)
        #expect(TCPTable.parse(Kernel.generation(count: 0)).isEmpty)
    }

    @Test func clientsAreLoopbackConnectionsToThePortsInAnyStateButListening() {
        func entry(_ state: TCPTableEntry.State, remote: Int, loopback: Bool = true, pid: pid_t = 9) -> TCPTableEntry {
            TCPTableEntry(state: state, localPort: 50_000, remotePort: remote, localIsLoopback: loopback, remoteIsLoopback: loopback,
                          lastPID: pid, effectivePID: pid)
        }
        let ports: Set<Int> = [1235]
        #expect(entry(.timeWait, remote: 1235).isClient(of: ports))
        #expect(entry(.established, remote: 1235).isClient(of: ports))
        #expect(entry(.closeWait, remote: 1235).isClient(of: ports), "SYN_SENT, CLOSE_WAIT and the rest count")
        #expect(!entry(.listening, remote: 0).isClient(of: ports))
        #expect(!entry(.timeWait, remote: 443).isClient(of: ports))
        #expect(!entry(.timeWait, remote: 1235, loopback: false).isClient(of: ports))
        let table = [entry(.timeWait, remote: 1235), entry(.listening, remote: 0), entry(.established, remote: 443)]
        #expect(TCPTable.clients(of: ports, in: table).count == 1)
        #expect(TCPTable.clients(of: [], in: table).isEmpty)
    }

}

// MARK: - The newborn ledger

struct NewbornLedgerTests {
    private static func born(_ pid: pid_t, parent: pid_t, _ name: String = "curl", at date: Date) -> Newborn {
        Newborn(pid: pid, parentPID: parent, name: name, executablePath: name.isEmpty ? nil : "/usr/bin/\(name)", bornAt: date)
    }

    @Test func remembersParentsAndForgetsTheOld() {
        let now = Date()
        var ledger = NewbornLedger()
        #expect(ledger.isEmpty)
        #expect(ledger.parent(of: 1) == nil)
        ledger.remember(Self.born(38384, parent: 50, "sh", at: now.addingTimeInterval(-200)))
        ledger.remember(contentsOf: [Self.born(38385, parent: 38384, at: now.addingTimeInterval(-1)), Self.born(38397, parent: 50, at: now)])
        #expect(ledger.count == 3)
        #expect(ledger.parent(of: 38385) == 38384)
        #expect(ledger.parent(of: 38384) == 50)
        #expect(ledger.contains(38397))
        #expect(ledger[38397]?.name == "curl")
        #expect(ledger[38397]?.executablePath == "/usr/bin/curl")

        ledger.forget(olderThan: now.addingTimeInterval(-NewbornLedger.memory))
        #expect(ledger.count == 2, "the shell born 200 s ago is gone")
        #expect(ledger.parent(of: 38384) == nil)
        #expect(ledger.parent(of: 38385) == 38384, "the child still names it, as a pid")
    }

    @Test func aReusedPidTakesTheLaterBirth() {
        let now = Date()
        var ledger = NewbornLedger()
        ledger.remember(Self.born(500, parent: 50, at: now.addingTimeInterval(-30)))
        ledger.remember(Self.born(500, parent: 77, "python3", at: now))
        #expect(ledger.count == 1)
        #expect(ledger.parent(of: 500) == 77)
        #expect(ledger[500]?.name == "python3")
        // An older sighting arriving late does not undo it.
        ledger.remember(Self.born(500, parent: 50, at: now.addingTimeInterval(-60)))
        #expect(ledger.parent(of: 500) == 77)
    }

    @Test func aNamelessNewbornIsAHelper() {
        let nameless = Self.born(600, parent: 50, "", at: Date())
        #expect(nameless.displayName == "helper")
        #expect(Self.born(601, parent: 50, "curl", at: Date()).displayName == "curl")
    }
}
