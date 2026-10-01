import Foundation

// Shared pieces of the runtime probes: a GET-only HTTP client with a short
// timeout, lenient JSON access, and a deadline for concurrent work.

/// Loopback GETs with a 1.5 s timeout. Never POSTs: 1.0 is read-only.
nonisolated final class HTTPClient: @unchecked Sendable {
    let timeout: TimeInterval
    private let session: URLSession

    init(timeout: TimeInterval = 1.5) {
        self.timeout = timeout
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = timeout
        configuration.timeoutIntervalForResource = timeout + 0.5
        configuration.waitsForConnectivity = false
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        session = URLSession(configuration: configuration)
    }

    /// Status and body, or nil when nothing answered in time.
    func get(port: Int, path: String) async -> (status: Int, data: Data)? {
        guard let url = URL(string: "http://127.0.0.1:\(port)\(path)") else { return nil }
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = timeout
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        do {
            let (data, response) = try await session.data(for: request)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            return (status, data)
        } catch {
            return nil
        }
    }

    /// The body of a 2xx answer.
    func getData(port: Int, path: String) async -> Data? {
        guard let answer = await get(port: port, path: path), (200..<300).contains(answer.status) else { return nil }
        return answer.data
    }

    /// The same, for a port that may not exist.
    func getDataIfPort(_ port: Int?, path: String) async -> Data? {
        guard let port else { return nil }
        return await getData(port: port, path: path)
    }
}

/// JSON the way the probes need it: optional, tolerant of numbers as strings
/// and of the port being some other service entirely.
nonisolated enum JSON {
    static func object(_ data: Data?) -> [String: Any]? {
        guard let data else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    static func array(_ data: Data?) -> [Any]? {
        guard let data else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [Any]
    }

    static func string(_ value: Any?) -> String? {
        if let string = value as? String { return string }
        return nil
    }

    static func double(_ value: Any?) -> Double? {
        if let number = value as? NSNumber { return number.doubleValue }
        if let string = value as? String { return Double(string) }
        return nil
    }

    static func int(_ value: Any?) -> Int? {
        if let number = value as? NSNumber { return number.intValue }
        if let string = value as? String { return Int(string) }
        return nil
    }

    static func uint64(_ value: Any?) -> UInt64? {
        if let number = value as? NSNumber {
            let double = number.doubleValue
            return double > 0 ? UInt64(double) : 0
        }
        if let string = value as? String { return UInt64(string) }
        return nil
    }

    static func bool(_ value: Any?) -> Bool? {
        if let number = value as? NSNumber { return number.boolValue }
        if let string = value as? String { return string == "true" || string == "1" }
        return nil
    }

    static func objects(_ value: Any?) -> [[String: Any]] {
        (value as? [Any])?.compactMap { $0 as? [String: Any] } ?? []
    }

    static func strings(_ value: Any?) -> [String] {
        (value as? [Any])?.compactMap { $0 as? String } ?? []
    }
}

/// Runs work with a time limit; nil when the limit wins. The work is
/// cancelled, which URLSession honours.
nonisolated func withDeadline<T: Sendable>(seconds: Double, _ work: @escaping @Sendable () async -> T) async -> T? {
    await withTaskGroup(of: T?.self) { group in
        group.addTask { await work() }
        group.addTask {
            try? await Task.sleep(for: .seconds(seconds))
            return nil
        }
        let first = await group.next() ?? nil
        group.cancelAll()
        return first
    }
}

/// Dates the runtimes send: RFC 3339 with any number of fractional digits
/// (Go writes up to nine), e.g. "2026-10-01T14:02:11.123456+02:00".
nonisolated enum RFC3339 {
    static func date(_ text: String) -> Date? {
        var base = text
        var fraction: Double = 0
        if let dot = text.firstIndex(of: "."), let time = text.firstIndex(of: "T"), dot > time {
            let afterDot = text[text.index(after: dot)...]
            let digits = afterDot.prefix { $0.isNumber }
            base = String(text[..<dot]) + String(afterDot.dropFirst(digits.count))
            if !digits.isEmpty, let value = Double("0." + String(digits)) { fraction = value }
        }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        guard let date = formatter.date(from: base) else { return nil }
        // Go's zero time means "never expires".
        guard date.timeIntervalSince1970 > 0 else { return nil }
        return date.addingTimeInterval(fraction)
    }
}
