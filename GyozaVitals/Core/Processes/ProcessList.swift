import Darwin
import Foundation

// Process enumeration through libproc and sysctl. Everything here is
// read-only and tolerant: a process that vanishes mid-scan, or one the
// kernel refuses to describe, is simply left out.

/// One process as the kernel describes it: enough to classify it.
nonisolated struct ProcessRecord: Hashable, Sendable {
    let pid: pid_t
    let parentPID: pid_t
    let uid: uid_t
    /// Executable name: the path's last component, or the kernel's short name.
    let name: String
    let executablePath: String?
    /// argv as launched; empty when the kernel refused or the process is gone.
    let arguments: [String]
    /// Seconds since 1970 when the process started. With the pid, its identity.
    let startTime: UInt64
    /// Physical footprint in bytes (Activity Monitor's "Memory"); 0 when unknown.
    let footprintBytes: UInt64

    /// argv[0]'s last path component, e.g. "mflux-generate" for a Python script.
    var argumentName: String? {
        guard let first = arguments.first, !first.isEmpty else { return nil }
        return (first as NSString).lastPathComponent
    }
}

/// Fixed-size C character arrays arrive in Swift as tuples; this reads them.
nonisolated enum CStrings {
    /// The NUL-terminated string at the start of any C array (tuple) value.
    static func string<T>(_ value: T) -> String {
        withUnsafeBytes(of: value) { raw in
            String(decoding: raw.prefix { $0 != 0 }, as: UTF8.self)
        }
    }

    /// The NUL-terminated string in a buffer the kernel filled.
    static func string(_ buffer: [CChar], length: Int) -> String {
        let bytes = buffer.prefix(max(0, min(length, buffer.count))).map { UInt8(bitPattern: $0) }
        return String(decoding: bytes.prefix { $0 != 0 }, as: UTF8.self)
    }
}

nonisolated enum ProcessList {
    /// Every process owned by the current user, since the kernel describes no
    /// other user's files or sockets without root.
    static func currentUserProcesses() -> [ProcessRecord] {
        let uid = getuid()
        let reader = ArgumentReader()
        var records: [ProcessRecord] = []
        for pid in allPIDs() where pid > 0 {
            guard let info = bsdInfo(pid), info.pbi_uid == uid else { continue }
            let path = executablePath(pid)
            var name = path.map { ($0 as NSString).lastPathComponent } ?? ""
            if name.isEmpty { name = processName(pid) ?? CStrings.string(info.pbi_comm) }
            records.append(ProcessRecord(
                pid: pid,
                parentPID: pid_t(truncatingIfNeeded: info.pbi_ppid),
                uid: info.pbi_uid,
                name: name,
                executablePath: path,
                arguments: reader.arguments(pid),
                startTime: info.pbi_start_tvsec,
                footprintBytes: footprint(pid)))
        }
        return records
    }

    /// All pids on the system, any user.
    static func allPIDs() -> [pid_t] {
        let estimate = proc_listallpids(nil, 0)
        guard estimate > 0 else { return [] }
        var pids = [pid_t](repeating: 0, count: Int(estimate) + 64)
        let bytes = Int32(pids.count * MemoryLayout<pid_t>.stride)
        let count = pids.withUnsafeMutableBufferPointer { proc_listallpids($0.baseAddress, bytes) }
        guard count > 0 else { return [] }
        return Array(pids.prefix(Int(count)))
    }

    /// Ownership, parent, start time and short name.
    static func bsdInfo(_ pid: pid_t) -> proc_bsdinfo? {
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        let got = withUnsafeMutablePointer(to: &info) { proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, $0, size) }
        return got == size ? info : nil
    }

    /// The executable's full path, or nil when the kernel won't say.
    static func executablePath(_ pid: pid_t) -> String? {
        var buffer = [CChar](repeating: 0, count: 4096) // PROC_PIDPATHINFO_MAXSIZE
        let length = buffer.withUnsafeMutableBufferPointer { proc_pidpath(pid, $0.baseAddress, UInt32($0.count)) }
        guard length > 0 else { return nil }
        let path = CStrings.string(buffer, length: Int(length))
        return path.isEmpty ? nil : path
    }

    /// The kernel's name for the process (up to 32 characters).
    static func processName(_ pid: pid_t) -> String? {
        var buffer = [CChar](repeating: 0, count: 256)
        let length = buffer.withUnsafeMutableBufferPointer { proc_name(pid, $0.baseAddress, UInt32($0.count)) }
        guard length > 0 else { return nil }
        let name = CStrings.string(buffer, length: Int(length))
        return name.isEmpty ? nil : name
    }

    /// Physical footprint: what Activity Monitor calls Memory. 0 when refused.
    static func footprint(_ pid: pid_t) -> UInt64 {
        var usage = rusage_info_v4()
        let result = withUnsafeMutablePointer(to: &usage) {
            $0.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { proc_pid_rusage(pid, RUSAGE_INFO_V4, $0) }
        }
        return result == 0 ? usage.ri_phys_footprint : 0
    }
}

/// Reads argv through `kern.procargs2`, reusing one buffer across pids.
nonisolated final class ArgumentReader {
    private var buffer: [UInt8]

    init() {
        var mib: [Int32] = [CTL_KERN, KERN_ARGMAX]
        var argmax: Int32 = 0
        var length = MemoryLayout<Int32>.size
        _ = sysctl(&mib, 2, &argmax, &length, nil, 0)
        buffer = [UInt8](repeating: 0, count: max(Int(argmax), 65_536))
    }

    func arguments(_ pid: pid_t) -> [String] {
        var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
        var size = buffer.count
        let status = buffer.withUnsafeMutableBytes { raw in sysctl(&mib, 3, raw.baseAddress, &size, nil, 0) }
        guard status == 0, size > MemoryLayout<Int32>.size, size <= buffer.count else { return [] }
        return Self.parse(Array(buffer[0..<size]))
    }

    /// The procargs2 layout: argc as a native Int32, the executable path,
    /// NUL padding, then argc NUL-terminated arguments (the environment follows).
    static func parse(_ bytes: [UInt8]) -> [String] {
        guard bytes.count > 4 else { return [] }
        let argc = Int(bytes[0]) | Int(bytes[1]) << 8 | Int(bytes[2]) << 16 | Int(bytes[3]) << 24
        guard argc > 0, argc < 100_000 else { return [] }
        var index = 4
        // Executable path.
        while index < bytes.count, bytes[index] != 0 { index += 1 }
        // Padding.
        while index < bytes.count, bytes[index] == 0 { index += 1 }
        var arguments: [String] = []
        while arguments.count < argc, index < bytes.count {
            let start = index
            while index < bytes.count, bytes[index] != 0 { index += 1 }
            arguments.append(String(decoding: bytes[start..<index], as: UTF8.self))
            index += 1
        }
        return arguments
    }
}
