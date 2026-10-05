import Darwin
import Foundation

/// A short-lived process caught connecting to a runtime's port during a
/// burst: enough to make it a client and resolve it to its app.
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
    /// builds it; the main actor resolves it to an app.
    let chain: [ProcessChainLink]
}

/// Catches the clients a 5-second sampler never sees.
///
/// The owner's Qwen Image app drives sd-server with one helper process per
/// progress poll: each lives for milliseconds, connects to 127.0.0.1:1235,
/// reads its answer and exits. `netstat` during a generation shows only
/// TIME_WAIT entries whose pids climb; no scan ever lands on an
/// ESTABLISHED connection, and the app itself holds none. The launcher rule
/// doesn't help either when launchd started the server.
///
/// So, when asked, this watches for newborn processes for a short burst:
/// `proc_listallpids` every `interval` (cheap: one call, no per-process
/// work), and for each pid not seen before, its owner, parent and name,
/// then its TCP sockets. A newborn whose socket has a loopback foreign
/// address on one of the ports, in any state (SYN_SENT, ESTABLISHED,
/// CLOSE_WAIT all count), is a poller. A newborn may not have connected on
/// first sight, so a candidate's sockets are re-read on each tick for
/// `recheckWindow` while it is alive.
///
/// Budget: 60 listings of ~600 pids plus a handful of per-process reads is
/// well under 100 ms of CPU per burst. The actor keeps the loop off the
/// main actor whoever calls it. Read-only: it never signals, never connects.
actor PollerCatcher {
    /// How long a newborn is re-checked for a connection after first sight.
    static let recheckWindow: TimeInterval = 0.15

    init() {}

    /// Processes born during the next `duration` seconds that connect to any
    /// of `ports` on loopback, with their parent chains. `known` seeds the
    /// seen set (the pipeline's process snapshot: nothing there is new);
    /// `processes` is the same snapshot by pid, for the chains (the parent,
    /// usually the app, is almost always in it). Only the current user's
    /// processes can be read. Returns early, with what it has, when cancelled.
    func catchPollers(ports: Set<Int>, among known: Set<pid_t>, processes byPID: [pid_t: ProcessRecord] = [:],
                      duration: TimeInterval = 1.2, interval: TimeInterval = 0.02) async -> [CaughtPoller] {
        guard !ports.isEmpty, duration > 0 else { return [] }
        let uid = getuid()
        let selfPID = getpid()
        let clock = ContinuousClock()
        let deadline = clock.now + .seconds(duration)
        var seen = known
        seen.insert(selfPID)
        var candidates: [pid_t: (record: ProcessRecord, since: ContinuousClock.Instant)] = [:]
        var caught: [pid_t: CaughtPoller] = [:]
        let arguments = ArgumentReader()

        while true {
            let now = clock.now
            for pid in ProcessList.allPIDs() where pid > 0 && !seen.contains(pid) {
                seen.insert(pid)
                guard let info = ProcessList.bsdInfo(pid), info.pbi_uid == uid else { continue }
                let record = Self.record(pid: pid, info: info, arguments: arguments)
                if let port = Self.port(of: pid, among: ports) {
                    caught[pid] = Self.poller(record, port: port, among: byPID, arguments: arguments)
                } else {
                    candidates[pid] = (record, now)
                }
            }
            for (pid, candidate) in candidates {
                if let port = Self.port(of: pid, among: ports) {
                    caught[pid] = Self.poller(candidate.record, port: port, among: byPID, arguments: arguments)
                    candidates[pid] = nil
                } else if candidate.since.duration(to: now) > .seconds(Self.recheckWindow) || ProcessList.bsdInfo(pid) == nil {
                    candidates[pid] = nil
                }
            }
            guard now < deadline, !Task.isCancelled else { break }
            do { try await Task.sleep(for: .seconds(interval)) } catch { break }
        }
        return caught.values.sorted { $0.pid < $1.pid }
    }

    /// The port among `ports` that one of the process's TCP sockets is
    /// connected to over loopback, in whatever state; nil when none is (or
    /// the process is gone, when the kernel lists no descriptors).
    nonisolated static func port(of pid: pid_t, among ports: Set<Int>) -> Int? {
        ProcessFiles.sockets(pid: pid).first { matches($0, ports: ports) }?.remotePort
    }

    /// Whether the catcher's own match rule accepts a socket: a client of a
    /// runtime port on loopback, in any state but listening.
    nonisolated static func matches(_ socket: TCPSocket, ports: Set<Int>) -> Bool {
        socket.state != .listening && ports.contains(socket.remotePort) && (socket.remoteIsLoopback || socket.localIsLoopback)
    }

    /// A newborn as the kernel describes it right now: no argv yet (that is
    /// read only for a poller, once it is caught), no footprint.
    private nonisolated static func record(pid: pid_t, info: proc_bsdinfo, arguments: ArgumentReader) -> ProcessRecord {
        let path = ProcessList.executablePath(pid)
        var name = path.map { ($0 as NSString).lastPathComponent } ?? ""
        if name.isEmpty { name = ProcessList.processName(pid) ?? CStrings.string(info.pbi_comm) }
        return ProcessRecord(
            pid: pid, parentPID: pid_t(truncatingIfNeeded: info.pbi_ppid), uid: info.pbi_uid, name: name, executablePath: path,
            arguments: [], startTime: info.pbi_start_tvsec, footprintBytes: 0)
    }

    /// The caught process with its argv (for "python poll.py" names; empty
    /// when it has already gone) and its chain through the snapshot.
    private nonisolated static func poller(_ record: ProcessRecord, port: Int, among byPID: [pid_t: ProcessRecord],
                                           arguments: ArgumentReader) -> CaughtPoller {
        let full = ProcessRecord(
            pid: record.pid, parentPID: record.parentPID, uid: record.uid, name: record.name, executablePath: record.executablePath,
            arguments: arguments.arguments(record.pid), startTime: record.startTime, footprintBytes: 0)
        return CaughtPoller(
            pid: full.pid, name: ClientFinder.displayName(for: full), executablePath: full.executablePath, parentPID: full.parentPID,
            port: port, chain: ClientFinder.chain(from: full, among: byPID))
    }
}
