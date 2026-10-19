import Foundation
import CoreFoundation
import Darwin

struct WeeklyQuota {
    let id: String
    let label: String
    let usedPercent: Double
    let resetsAt: Date?

    var remainingPercent: Double { max(0, min(100, 100 - usedPercent)) }
}

struct QuotaReading {
    let windows: [WeeklyQuota]
    let receivedAt: Date
}

enum QuotaClientError: LocalizedError {
    case cliUnavailable, launchFailed, timedOut, cancelled, invalidResponse, serviceUnavailable

    var errorDescription: String? {
        switch self {
        case .cliUnavailable: return "未找到 Codex CLI，请检查桌面应用是否已安装。"
        case .launchFailed: return "无法启动 Codex 额度查询。"
        case .timedOut: return "额度查询超时，稍后重试。"
        case .cancelled: return "额度查询已取消。"
        case .invalidResponse: return "Codex 返回的额度数据无法识别。"
        case .serviceUnavailable: return "暂时无法获取额度，请检查 Codex 登录和网络连接。"
        }
    }
}

final class QuotaClient {
    private let lock = NSLock()
    private var activeRequest: QuotaRequest?

    /// Supersedes an outstanding read. Every completion, including cancellation, runs on main.
    func read(completion: @escaping (Result<QuotaReading, Error>) -> Void) {
        let request = QuotaRequest(completion: completion)
        lock.lock()
        let previous = activeRequest
        activeRequest = request
        lock.unlock()
        previous?.cancel()
        request.start()
    }

    func cancel() {
        lock.lock()
        let request = activeRequest
        activeRequest = nil
        lock.unlock()
        request?.cancel()
    }

    deinit { cancel() }

    static func parse(_ result: [String: Any], receivedAt: Date = Date()) throws -> QuotaReading {
        var buckets: [(String, [String: Any])] = []
        if let multi = result["rateLimitsByLimitId"] as? [String: Any] {
            buckets = multi.compactMap { key, value in
                guard let bucket = value as? [String: Any] else { return nil }
                return (key, bucket)
            }
        } else if let single = result["rateLimits"] as? [String: Any] {
            buckets = [(nonempty(single["limitId"]) ?? "codex", single)]
        } else if result["rateLimits"] == nil && result["rateLimitsByLimitId"] == nil {
            throw QuotaClientError.invalidResponse
        } else if let multi = result["rateLimitsByLimitId"], !(multi is NSNull) {
            throw QuotaClientError.invalidResponse
        } else if let single = result["rateLimits"], !(single is NSNull) {
            throw QuotaClientError.invalidResponse
        }

        buckets.sort { left, right in
            if (left.0 == "codex") != (right.0 == "codex") { return left.0 == "codex" }
            return left.0 < right.0
        }
        var windows: [WeeklyQuota] = []
        for (bucketID, bucket) in buckets {
            let label = nonempty(bucket["limitName"]) ?? (bucketID == "codex" ? "Codex" : bucketID)
            for windowName in ["primary", "secondary"] {
                guard let window = bucket[windowName] as? [String: Any],
                      number(window["windowDurationMins"]) == 10_080,
                      let used = number(window["usedPercent"]) else { continue }
                let reset = number(window["resetsAt"]).flatMap { seconds -> Date? in
                    // Date has a much wider range than a useful account reset timestamp.
                    guard seconds > 0, seconds < 253_402_300_800 else { return nil }
                    return Date(timeIntervalSince1970: seconds)
                }
                windows.append(WeeklyQuota(id: "\(bucketID).\(windowName)", label: label,
                                           usedPercent: used, resetsAt: reset))
            }
        }
        return QuotaReading(windows: windows, receivedAt: receivedAt)
    }

    private static func number(_ value: Any?) -> Double? {
        guard let value = value as? NSNumber,
              CFGetTypeID(value) != CFBooleanGetTypeID(),
              value.doubleValue.isFinite else { return nil }
        return value.doubleValue
    }

    private static func nonempty(_ value: Any?) -> String? {
        guard let value = value as? String, !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return nil
        }
        return value
    }
}

private final class QuotaRequest {
    private let lock = NSLock()
    private var cancelled = false
    private var completion: ((Result<QuotaReading, Error>) -> Void)?
    private var child: QuotaSubprocess?

    init(completion: @escaping (Result<QuotaReading, Error>) -> Void) {
        self.completion = completion
    }

    func cancel() {
        lock.lock()
        cancelled = true
        let child = self.child
        lock.unlock()
        // App shutdown may end the run loop immediately after this method returns.
        // Reap the child here as well as in the background worker's defer.
        child?.stopAndWait()
    }

    private var isCancelled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return cancelled
    }

    func start() {
        DispatchQueue.global(qos: .utility).async { [self] in
            let result: Result<QuotaReading, Error>
            do {
                let reading = try query()
                result = isCancelled ? .failure(QuotaClientError.cancelled) : .success(reading)
            }
            catch { result = .failure(isCancelled ? QuotaClientError.cancelled : error) }
            lock.lock()
            let callback = completion
            completion = nil
            lock.unlock()
            DispatchQueue.main.async { callback?(result) }
        }
    }

    private static func executableURL() throws -> URL {
        let environment = ProcessInfo.processInfo.environment
        let manager = FileManager.default
        if let override = environment["CODEX_MONITOR_CLI"], !override.isEmpty {
            let path = (override as NSString).expandingTildeInPath
            guard manager.isExecutableFile(atPath: path) else { throw QuotaClientError.cliUnavailable }
            return URL(fileURLWithPath: path)
        }
        let home = manager.homeDirectoryForCurrentUser.path
        var candidates: [String] = []
        for folder in ["/Applications", "\(home)/Applications"] {
            for app in ["ChatGPT.app", "Codex.app"] {
                candidates.append("\(folder)/\(app)/Contents/Resources/codex-cli/CodexCLI.app/Contents/MacOS/codex")
                candidates.append("\(folder)/\(app)/Contents/Resources/codex")
            }
        }
        let path = environment["PATH"] ?? "/usr/bin:/bin:/usr/sbin:/sbin"
        candidates += path.split(separator: ":").map { "\($0)/codex" }
        candidates += ["/opt/homebrew/bin/codex", "/usr/local/bin/codex"]
        guard let executable = candidates.first(where: { manager.isExecutableFile(atPath: $0) }) else {
            throw QuotaClientError.cliUnavailable
        }
        return URL(fileURLWithPath: executable)
    }

    private func query() throws -> QuotaReading {
        if isCancelled { throw QuotaClientError.cancelled }
        let process = Process()
        process.executableURL = try Self.executableURL()
        process.arguments = ["app-server", "--listen", "stdio://"]
        process.currentDirectoryURL = FileManager.default.homeDirectoryForCurrentUser
        let input = Pipe()
        let output = Pipe()
        process.standardInput = input
        process.standardOutput = output
        // Authentication/config diagnostics must never reach the monitor UI or logs.
        process.standardError = FileHandle.nullDevice
        let subprocess = QuotaSubprocess(process: process)
        let startedAt = DispatchTime.now().uptimeNanoseconds
        // Publishing the child and launching it are atomic with respect to cancel().
        lock.lock()
        if cancelled {
            lock.unlock()
            subprocess.didFailToLaunch()
            throw QuotaClientError.cancelled
        }
        do {
            try process.run()
            child = subprocess
            lock.unlock()
        }
        catch {
            lock.unlock()
            subprocess.didFailToLaunch()
            try? input.fileHandleForWriting.close()
            try? input.fileHandleForReading.close()
            try? output.fileHandleForReading.close()
            try? output.fileHandleForWriting.close()
            throw QuotaClientError.launchFailed
        }
        defer {
            try? input.fileHandleForWriting.close()
            subprocess.stopAndWait()
            try? input.fileHandleForReading.close()
            try? output.fileHandleForReading.close()
            try? output.fileHandleForWriting.close()
            lock.lock()
            child = nil
            lock.unlock()
        }

        let descriptor = output.fileHandleForReading.fileDescriptor
        let existingFlags = fcntl(descriptor, F_GETFL)
        guard existingFlags >= 0, fcntl(descriptor, F_SETFL, existingFlags | O_NONBLOCK) == 0 else {
            throw QuotaClientError.launchFailed
        }
        // A child that exits during the handshake must produce an error, not SIGPIPE in the UI.
        guard fcntl(input.fileHandleForWriting.fileDescriptor, F_SETNOSIGPIPE, 1) == 0 else {
            throw QuotaClientError.launchFailed
        }
        func send(_ message: [String: Any]) throws {
            var data = try JSONSerialization.data(withJSONObject: message)
            data.append(0x0A)
            do { try input.fileHandleForWriting.write(contentsOf: data) }
            catch { throw QuotaClientError.serviceUnavailable }
        }
        try send(["id": 0, "method": "initialize", "params": ["clientInfo": [
            "name": "codex_pet_monitor", "title": "Codex Pet Monitor", "version": "1.0.0"
        ]]])
        var initialized = false
        var buffer = Data()
        var bytes = [UInt8](repeating: 0, count: 8192)
        while true {
            if isCancelled { throw QuotaClientError.cancelled }
            if DispatchTime.now().uptimeNanoseconds - startedAt >= 20_000_000_000 {
                throw QuotaClientError.timedOut
            }
            var pollDescriptor = pollfd(fd: descriptor, events: Int16(POLLIN), revents: 0)
            let status = Darwin.poll(&pollDescriptor, 1, 100)
            if status < 0 {
                if errno == EINTR { continue }
                throw QuotaClientError.serviceUnavailable
            }
            if status == 0 { continue }
            let count = Darwin.read(descriptor, &bytes, bytes.count)
            if count < 0 {
                if errno == EAGAIN || errno == EWOULDBLOCK || errno == EINTR { continue }
                throw QuotaClientError.serviceUnavailable
            }
            if count == 0 { throw QuotaClientError.serviceUnavailable }
            buffer.append(contentsOf: bytes.prefix(count))
            guard buffer.count <= 1_048_576 else { throw QuotaClientError.invalidResponse }
            while let newline = buffer.firstIndex(of: 0x0A) {
                let line = Data(buffer[..<newline])
                buffer.removeSubrange(...newline)
                if line.isEmpty { continue }
                guard let message = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any] else {
                    throw QuotaClientError.invalidResponse
                }
                guard let id = message["id"] as? NSNumber,
                      CFGetTypeID(id) != CFBooleanGetTypeID() else { continue }
                if id.intValue == 0 && !initialized {
                    guard message["error"] == nil, message["result"] is [String: Any] else {
                        throw QuotaClientError.serviceUnavailable
                    }
                    initialized = true
                    try send(["method": "initialized", "params": [:]])
                    try send(["id": 1, "method": "account/rateLimits/read"])
                } else if id.intValue == 1 && initialized {
                    guard message["error"] == nil else { throw QuotaClientError.serviceUnavailable }
                    guard let result = message["result"] as? [String: Any] else {
                        throw QuotaClientError.invalidResponse
                    }
                    return try QuotaClient.parse(result)
                }
            }
        }
    }
}

/// All callers can wait for the same exit event; only one sends each signal.
private final class QuotaSubprocess {
    private let process: Process
    private let exited = DispatchGroup()
    private let lock = NSLock()
    private var terminationRequested = false
    private var killRequested = false

    init(process: Process) {
        self.process = process
        exited.enter()
        let exitEvent = exited
        process.terminationHandler = { _ in exitEvent.leave() }
    }

    func didFailToLaunch() { exited.leave() }

    func stopAndWait() {
        lock.lock()
        let shouldTerminate = !terminationRequested
        terminationRequested = true
        lock.unlock()
        if shouldTerminate && process.isRunning { process.terminate() }
        if exited.wait(timeout: .now() + 0.3) == .timedOut {
            lock.lock()
            let shouldKill = !killRequested
            killRequested = true
            lock.unlock()
            if shouldKill && process.isRunning { Darwin.kill(process.processIdentifier, SIGKILL) }
            _ = exited.wait(timeout: .now() + 1)
        }
    }
}

/// Runs without starting Codex, touching credentials, or making a network request.
func runQuotaTests() throws {
    struct TestFailure: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }
    func check(_ condition: @autoclosure () -> Bool, _ message: String) throws {
        if !condition() { throw TestFailure(message: message) }
    }
    let timestamp = Date(timeIntervalSince1970: 1_792_981_758)
    let weekly: [String: Any] = ["usedPercent": 1, "windowDurationMins": 10_080, "resetsAt": 1_792_981_758]
    let multi: [String: Any] = ["rateLimitsByLimitId": [
        "other": ["limitName": "Other", "secondary": weekly],
        "codex": ["primary": weekly, "secondary": ["usedPercent": 30, "windowDurationMins": 300]]
    ], "rateLimits": ["primary": ["usedPercent": 99, "windowDurationMins": 10_080]]]
    let reading = try QuotaClient.parse(multi, receivedAt: timestamp)
    try check(reading.windows.map(\.id) == ["codex.primary", "other.secondary"], "Bucket ordering/window selection")
    try check(reading.windows.first?.remainingPercent == 99, "Multi-bucket precedence/remaining percentage")
    try check(reading.windows.first?.resetsAt == timestamp && reading.receivedAt == timestamp, "Timestamp units")
    let missingReset = try QuotaClient.parse(["rateLimits": ["secondary": ["usedPercent": 25, "windowDurationMins": 10_080]]])
    try check(missingReset.windows.first?.resetsAt == nil, "Unknown reset must remain nil")
    for invalid in [true, Double.nan, Double.infinity, "12"] as [Any] {
        let parsed = try QuotaClient.parse(["rateLimits": ["primary": ["usedPercent": invalid, "windowDurationMins": 10_080]]])
        try check(parsed.windows.isEmpty, "Invalid percentage must not become a number")
    }
    let missingUsage = try QuotaClient.parse(["rateLimits": ["primary": ["windowDurationMins": 10_080]]])
    try check(missingUsage.windows.isEmpty, "Missing usage must not imply zero usage")
    let empty = try QuotaClient.parse(["rateLimits": NSNull(), "rateLimitsByLimitId": NSNull()])
    try check(empty.windows.isEmpty, "Unavailable quota must remain empty")
    let noWeekly = try QuotaClient.parse(["rateLimits": ["primary": ["usedPercent": 5, "windowDurationMins": 300]]])
    try check(noWeekly.windows.isEmpty, "Short-term quota must not be presented as weekly")
    let clamped = WeeklyQuota(id: "test", label: "Test", usedPercent: 101, resetsAt: nil)
    try check(clamped.remainingPercent == 0, "Remaining percentage clamp")
    do {
        _ = try QuotaClient.parse([:])
        throw TestFailure(message: "Malformed response accepted")
    } catch is QuotaClientError { }
}
