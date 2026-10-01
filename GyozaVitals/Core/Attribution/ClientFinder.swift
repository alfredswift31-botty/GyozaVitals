import Foundation

/// Who is talking to a runtime: every same-user process with an established
/// loopback TCP connection whose foreign port is one of the runtime's ports.
///
/// Limitation: a connection names a port, not a model. For runtimes that host
/// one model per port (llama-server, koboldcpp, whisper-server, Ollama's
/// runners) the client is the model's; for Ollama's main port, LM Studio and
/// ComfyUI the scanner attaches the port's clients to every model behind it.
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

    /// A client before the main actor looks it up in NSRunningApplication:
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
}
