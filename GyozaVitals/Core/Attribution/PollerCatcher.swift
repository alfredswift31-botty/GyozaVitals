import Darwin
import Foundation

/// A short-lived process that connected to a runtime's port: enough to make
/// it a client and resolve it to its app. Built from the kernel's TCP table
/// (which keeps the pid of a closed connection) and the newborn ledger
/// (which keeps the parent of a process that has already exited).
nonisolated struct CaughtPoller: Hashable, Sendable {
    let pid: pid_t
    /// The executable name, with the script for interpreters (see
    /// `ClientFinder.displayName`).
    let name: String
    let executablePath: String?
    let parentPID: pid_t
    /// The runtime port it connected to.
    let port: Int
    /// The process and its ancestors, nearest first, as `ClientFinder.chain`
    /// builds it, with the links that have exited taken from the ledger; the
    /// main actor resolves it to an app.
    let chain: [ProcessChainLink]
}

/// A process seen being born during a burst, as the kernel described it on
/// first sight. The owner's Qwen Image app drives sd-server with one helper
/// per progress poll that lives for ten or twenty milliseconds; by the time
/// a scan looks, it is gone and only its parent knew where it came from.
nonisolated struct Newborn: Hashable, Sendable {
    let pid: pid_t
    let parentPID: pid_t
    /// The executable name; empty when the process was gone before it could
    /// be read.
    let name: String
    let executablePath: String?
    let bornAt: Date

    /// The name for a chain link: "helper" when the kernel never said.
    var displayName: String { name.isEmpty ? "helper" : name }
}

/// Newborns remembered for `memory` seconds, by pid, so that a connection
/// the TCP table attributes to a pid that has exited can still be walked up
/// to the app that spawned it. A pid is reused after a wrap, so a later
/// birth of the same pid replaces the earlier one.
nonisolated struct NewbornLedger: Sendable {
    static let memory: TimeInterval = 180

    private var entries: [pid_t: Newborn] = [:]

    init() {}

    var count: Int { entries.count }
    var isEmpty: Bool { entries.isEmpty }

    subscript(pid: pid_t) -> Newborn? { entries[pid] }

    func contains(_ pid: pid_t) -> Bool { entries[pid] != nil }

    func parent(of pid: pid_t) -> pid_t? { entries[pid]?.parentPID }

    mutating func remember(_ newborn: Newborn) {
        if let known = entries[newborn.pid], known.bornAt > newborn.bornAt { return }
        entries[newborn.pid] = newborn
    }

    mutating func remember(contentsOf newborns: [Newborn]) {
        for newborn in newborns { remember(newborn) }
    }

    mutating func forget(olderThan cutoff: Date) {
        entries = entries.filter { $0.value.bornAt >= cutoff }
    }
}

/// What one burst saw and what it cost.
nonisolated struct Burst: Sendable {
    let newborns: [Newborn]
    /// CPU time the burst's own thread spent listing pids and reading
    /// newborns, in seconds: the cost of the burst, not of the process.
    let cpuSeconds: Double
    let ticks: Int
    /// The tick interval the burst ended on: doubled, up to 20 ms, each
    /// time a listing cost more than a millisecond.
    let interval: TimeInterval

    static let none = Burst(newborns: [], cpuSeconds: 0, ticks: 0, interval: 0)
}

/// When a runtime was last watched for newborns, how many were born, and
/// what the burst cost.
nonisolated struct BurstRecord: Hashable, Sendable {
    let at: Date
    let born: Int
    let cpuSeconds: Double
}

/// Watches for processes being born, for a short burst.
///
/// 1.0.7 watched the same way but counted a newborn only if it read the
/// newborn's TCP socket to the runtime's port while the socket was open.
/// Measured on the owner's Mac, that never happened: a curl-sized helper
/// lives ten to twenty milliseconds, most of it in dyld, and its socket is
/// open for the last one or two, so a 20 ms sampler read the socket list of
/// a process that had not connected yet, or of one that was gone. So this
/// reads no sockets at all. It lists pids every `interval` (one syscall, no
/// per-process work) and, for each pid not seen before, reads its bsdinfo
/// once: owner, parent, start time; plus the executable path. That is what
/// survives: the kernel's TCP table keeps the pid of a closed connection
/// for 2 MSL, and the ledger keeps the parent of the pid for three minutes.
///
/// Budget: 240 listings of ~600 pids plus one bsdinfo per newborn is well
/// under 100 ms of CPU per burst. The actor keeps the loop off the main
/// actor whoever calls it. Read-only: it never signals, never connects.
actor PollerCatcher {
    init() {}

    /// A tick that costs more than this doubles the interval, up to
    /// `slowestInterval`: a slow machine is not asked for 240 listings.
    static let costlyTick: TimeInterval = 0.001
    static let slowestInterval: TimeInterval = 0.02

    /// Processes born during the next `duration` seconds that belong to the
    /// current user. `known` seeds the seen set (the pipeline's process
    /// snapshot: nothing there is new). A zero duration returns at once.
    /// Returns early, with what it has, when cancelled.
    func watchNewborns(among known: Set<pid_t>, duration: TimeInterval = 1.2, interval: TimeInterval = 0.005) async -> Burst {
        guard duration > 0 else { return .none }
        let uid = getuid()
        let clock = ContinuousClock()
        let deadline = clock.now + .seconds(duration)
        var seen = known
        seen.insert(getpid())
        var newborns: [Newborn] = []
        var cpuSeconds = 0.0
        var ticks = 0
        var interval = interval

        while true {
            // One tick runs on one thread without suspending, so its own
            // thread's CPU time, before and after, is what the tick cost.
            let before = Self.threadCPUSeconds()
            for pid in ProcessList.allPIDs() where pid > 0 && !seen.contains(pid) {
                seen.insert(pid)
                guard let info = ProcessList.bsdInfo(pid), info.pbi_uid == uid else { continue }
                newborns.append(Self.newborn(pid: pid, info: info, at: Date()))
            }
            let cost = max(0, Self.threadCPUSeconds() - before)
            cpuSeconds += cost
            ticks += 1
            if cost > Self.costlyTick { interval = min(interval * 2, Self.slowestInterval) }
            guard clock.now < deadline, !Task.isCancelled else { break }
            do { try await Task.sleep(for: .seconds(interval)) } catch { break }
        }
        return Burst(newborns: newborns, cpuSeconds: cpuSeconds, ticks: ticks, interval: interval)
    }

    /// User plus system time of the calling thread, from `thread_info`.
    nonisolated static func threadCPUSeconds() -> Double {
        var info = thread_basic_info()
        var count = mach_msg_type_number_t(MemoryLayout<thread_basic_info>.size / MemoryLayout<integer_t>.size)
        let thread = mach_thread_self()
        defer { mach_port_deallocate(mach_task_self_, thread) }
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { thread_info(thread, thread_flavor_t(THREAD_BASIC_INFO), $0, &count) }
        }
        guard result == KERN_SUCCESS else { return 0 }
        return Double(info.user_time.seconds) + Double(info.user_time.microseconds) / 1e6
            + Double(info.system_time.seconds) + Double(info.system_time.microseconds) / 1e6
    }

    /// A newborn as the kernel describes it right now: parent and name, no
    /// argv (it would be gone before anyone asked), no footprint.
    nonisolated static func newborn(pid: pid_t, info: proc_bsdinfo, at date: Date) -> Newborn {
        let path = ProcessList.executablePath(pid)
        var name = path.map { ($0 as NSString).lastPathComponent } ?? ""
        if name.isEmpty { name = ProcessList.processName(pid) ?? CStrings.string(info.pbi_comm) }
        return Newborn(pid: pid, parentPID: pid_t(truncatingIfNeeded: info.pbi_ppid), name: name, executablePath: path, bornAt: date)
    }
}
