import Foundation

/// Who is talking to a runtime: every same-user process with an established
/// loopback TCP connection whose foreign port is one of the runtime's ports.
///
/// Limitation: a connection names a port, not a model. For runtimes that host
/// one model per port (llama-server, koboldcpp, whisper-server, Ollama's
/// runners) the client is the model's; for Ollama's main port, LM Studio and
/// ComfyUI the scanner attaches the port's clients to every model behind it.
///
/// A connection is usually held by a helper, not the app the user sees: an
/// Electron app's "<App> Helper (Networking)", a WebKit app's "<App>
/// Networking", a node or python child. `resolveApp(chain:)` collapses such a
/// process to its owning application by walking up the parent chain, and
/// `dedupe` keeps one entry per app.
nonisolated enum ClientFinder {
    /// Processes connected to each port, port by port.
    static func connections(to ports: Set<Int>, among processes: [ProcessRecord]) -> [Int: [ProcessRecord]] {
        guard !ports.isEmpty else { return [:] }
        var result: [Int: [ProcessRecord]] = [:]
        for process in processes {
            var hit = Set<Int>()
            for socket in ProcessFiles.sockets(pid: process.pid)
            where socket.state == .established && ports.contains(socket.remotePort)
                && (socket.remoteIsLoopback || socket.localIsLoopback) {
                hit.insert(socket.remotePort)
            }
            for port in hit { result[port, default: []].append(process) }
        }
        return result
    }

    /// A client before the main actor resolves it to an app:
    /// the executable name, with the script for interpreters.
    static func client(for process: ProcessRecord) -> ClientApp {
        ClientApp(pid: process.pid, name: displayName(for: process), bundleIdentifier: nil)
    }

    static func displayName(for process: ProcessRecord) -> String {
        let interpreters = ["python", "python3", "node", "ruby", "perl", "bun", "deno", "uv"]
        let lower = process.name.lowercased()
        if interpreters.contains(where: { lower.hasPrefix($0) }), process.arguments.count > 1 {
            let script = process.arguments.dropFirst().first { !$0.hasPrefix("-") }
            if let script, !script.isEmpty {
                return "\(process.name) \((script as NSString).lastPathComponent)"
            }
        }
        return process.name
    }

    // MARK: Parent chain

    /// At most this many ancestors are followed.
    static let chainLimit = 32

    /// Processes that end the walk: launchd, login and the shells. A tool
    /// started from a terminal is the user's own, not a helper of the
    /// terminal app above the shell.
    static let chainBoundaries: Set<String> = [
        "launchd", "login", "sh", "bash", "zsh", "fish", "dash", "tcsh", "csh", "ksh", "nu", "xonsh",
        "tmux", "screen", "sshd", "cron", "launchctl",
    ]

    /// The process and its ancestors, nearest first, stopping before launchd
    /// (pid 1), at a parent the listing doesn't know (another user's), at a
    /// loop, or after `chainLimit` links.
    static func chain(from process: ProcessRecord, among byPID: [pid_t: ProcessRecord]) -> [ProcessChainLink] {
        var links = [ProcessChainLink(process)]
        var seen: Set<pid_t> = [process.pid]
        var parent = process.parentPID
        while parent > 1, links.count < chainLimit, let record = byPID[parent], seen.insert(parent).inserted {
            links.append(ProcessChainLink(record))
            parent = record.parentPID
        }
        return links
    }

    /// Whether the chain passes through any of the pids (above the client
    /// itself): a child of the server is the server's, not a client.
    static func chain(_ chain: [ProcessChainLink], passesThrough pids: Set<pid_t>) -> Bool {
        chain.dropFirst().contains { pids.contains($0.pid) }
    }

    // MARK: Resolution

    /// The application a connecting process belongs to, from its parent
    /// chain (nearest first, as `chain(from:among:)` builds it, with names and
    /// bundle identifiers filled in from NSRunningApplication where known).
    ///
    /// The nearest link that is an app (a bundle identifier, or an executable
    /// inside `.app/Contents/MacOS/`) is the candidate; ancestors that are the
    /// same app (same outermost bundle, or the same name once helper suffixes
    /// are stripped) replace it, so the top-most process of the app stands for
    /// it. A different app above, or a boundary (shell, login), ends the walk.
    /// Nil when no link is an app: a command-line tool.
    static func resolveApp(chain: [ProcessChainLink]) -> ResolvedClient? {
        var found: AppCandidate?
        for link in chain {
            if isBoundary(link) { break }
            guard let candidate = AppCandidate(link) else { continue }
            if let current = found, !current.isSameApp(as: candidate) { break }
            found = candidate
        }
        guard let found else { return nil }
        return ResolvedClient(
            app: ClientApp(pid: found.link.pid, name: found.name, bundleIdentifier: found.link.bundleIdentifier),
            isHelper: found.isHelper)
    }

    static func isBoundary(_ link: ProcessChainLink) -> Bool {
        if link.pid <= 1 { return true }
        let name = link.executablePath.map { ($0 as NSString).lastPathComponent } ?? link.name
        var lower = name.lowercased()
        if lower.hasPrefix("-") { lower.removeFirst() }
        return chainBoundaries.contains(lower)
    }

    /// One entry per app: clients that resolved to the same name (case-
    /// insensitively) collapse into one, preferring the app itself over a
    /// helper and then the lower (older, usually the parent) pid.
    static func dedupe(_ clients: [ResolvedClient]) -> [ClientApp] {
        var best: [String: ResolvedClient] = [:]
        var order: [String] = []
        for client in clients {
            let key = client.app.name.lowercased()
            guard let current = best[key] else {
                best[key] = client
                order.append(key)
                continue
            }
            if client.ranksAbove(current) { best[key] = client }
        }
        return order.compactMap { best[$0]?.app }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    // MARK: Helper names

    /// "<App> Helper", "<App> Helper (Renderer)", "<App> Networking", "<App>
    /// GPU", "<App> Web Content": the names Electron, Chromium and WebKit
    /// give an app's helper processes. Returns the app's part, or the name
    /// unchanged when nothing would be left.
    static func stripHelperSuffix(_ name: String) -> String {
        var result = name.trimmingCharacters(in: .whitespaces)
        var changed = true
        while changed {
            changed = false
            // "Helper (anything)" first, then the bare words.
            if result.hasSuffix(")"), let open = result.range(of: " Helper (", options: .backwards) {
                let base = String(result[..<open.lowerBound])
                if !base.isEmpty {
                    result = base
                    changed = true
                    continue
                }
            }
            for suffix in helperSuffixes where result.hasSuffix(suffix) {
                let base = String(result.dropLast(suffix.count)).trimmingCharacters(in: .whitespaces)
                if !base.isEmpty {
                    result = base
                    changed = true
                    break
                }
            }
        }
        return result.isEmpty ? name : result
    }

    private static let helperSuffixes = [
        " Helper", " Networking", " GPU", " Renderer", " Plugin", " Web Content", " WebContent", " Utility", " Crashpad",
    ]

    // MARK: Bundles

    /// The outermost `.app` bundle on a path, and whether the executable sits
    /// inside a further bundle nested in it (a helper app).
    static func appBundle(onPath path: String) -> (path: String, name: String, nested: Bool)? {
        guard path.contains(".app/Contents/MacOS/"), let first = path.range(of: ".app/") else { return nil }
        let bundlePath = String(path[..<first.upperBound].dropLast()) // keep ".app", drop "/"
        let folder = (bundlePath as NSString).lastPathComponent
        let name = String(folder.dropLast(4))
        let nested = path[first.upperBound...].contains(".app/")
        return (bundlePath, name.isEmpty ? folder : name, nested)
    }

    private nonisolated struct AppCandidate {
        let link: ProcessChainLink
        let bundlePath: String?
        let name: String
        let isHelper: Bool

        init?(_ link: ProcessChainLink) {
            let bundle = link.executablePath.flatMap { ClientFinder.appBundle(onPath: $0) }
            guard bundle != nil || link.bundleIdentifier != nil else { return nil }
            self.link = link
            bundlePath = bundle?.path
            if let bundle, bundle.nested {
                // An Electron/Chromium helper: the outer bundle is the app.
                name = ClientFinder.stripHelperSuffix(bundle.name)
                isHelper = true
            } else {
                let own = link.name.isEmpty ? (bundle?.name ?? "") : link.name
                let stripped = ClientFinder.stripHelperSuffix(own)
                name = stripped.isEmpty ? (bundle?.name ?? own) : stripped
                isHelper = stripped != own
            }
        }

        func isSameApp(as other: AppCandidate) -> Bool {
            if let mine = bundlePath, let theirs = other.bundlePath, mine == theirs { return true }
            return name.caseInsensitiveCompare(other.name) == .orderedSame
        }
    }
}

/// One process on the way from a connecting process up towards launchd.
nonisolated struct ProcessChainLink: Hashable, Sendable {
    let pid: pid_t
    /// The executable name, or the app's localized name once the main actor
    /// has looked the pid up in NSRunningApplication.
    var name: String
    let executablePath: String?
    /// Set when NSRunningApplication knows the process: it is a GUI app.
    var bundleIdentifier: String?

    init(pid: pid_t, name: String, executablePath: String?, bundleIdentifier: String? = nil) {
        self.pid = pid
        self.name = name
        self.executablePath = executablePath
        self.bundleIdentifier = bundleIdentifier
    }

    init(_ record: ProcessRecord) {
        self.init(pid: record.pid, name: record.name, executablePath: record.executablePath)
    }
}

/// A client collapsed to its app, with what `dedupe` needs to pick one.
nonisolated struct ResolvedClient: Hashable, Sendable {
    let app: ClientApp
    /// The name came from a helper (suffix stripped or nested bundle), not
    /// from the app's own process.
    let isHelper: Bool

    func ranksAbove(_ other: ResolvedClient) -> Bool {
        if isHelper != other.isHelper { return !isHelper }
        if (app.bundleIdentifier == nil) != (other.app.bundleIdentifier == nil) { return app.bundleIdentifier != nil }
        return app.pid < other.app.pid
    }
}
