import AppKit
import SwiftUI

enum MonitorFormat {
    static let resetDate: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.timeZone = TimeZone(identifier: "Asia/Shanghai")
        formatter.dateFormat = "M月d日 HH:mm"
        return formatter
    }()

    static let clock: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.timeZone = TimeZone(identifier: "Asia/Shanghai")
        formatter.dateFormat = "HH:mm:ss"
        return formatter
    }()

    static func percent(_ value: Double?) -> String {
        guard let value, value.isFinite else { return "—" }
        return String(format: "%.0f%%", min(100, max(0, value)))
    }

    static func speed(_ bytes: Double?) -> String {
        guard let bytes, bytes.isFinite, bytes >= 0 else { return "—" }
        if bytes >= 1_048_576 { return String(format: "%.1f MiB/s", bytes / 1_048_576) }
        if bytes >= 1024 { return String(format: "%.1f KiB/s", bytes / 1024) }
        return String(format: "%.0f B/s", bytes)
    }

    static func countdown(until date: Date?, now: Date) -> String {
        guard let date else { return "重置时间暂不可用" }
        let seconds = date.timeIntervalSince(now)
        guard seconds > 0 else { return "等待服务器更新" }
        let minutes = Int(ceil(seconds / 60))
        if minutes >= 1440 { return "还有 \(minutes / 1440) 天 \((minutes % 1440) / 60) 小时" }
        if minutes >= 60 { return "还有 \(minutes / 60) 小时 \(minutes % 60) 分钟" }
        return "还有 \(minutes) 分钟"
    }
}

protocol QuotaReadingClient: AnyObject {
    func read(completion: @escaping (Result<QuotaReading, Error>) -> Void)
    func cancel()
}

extension QuotaClient: QuotaReadingClient {}

struct QueryFailureDetail {
    let occurredAt: Date
    let summary: String
    let detail: String
}

final class MonitorModel: ObservableObject {
    @Published var system: SystemSnapshot?
    @Published var reading: QuotaReading?
    @Published var quotaError: String?
    @Published var isRefreshing = false
    @Published var now = Date()
    @Published var selectedBucket = "codex.primary"
    @Published var pinned = true
    @Published private(set) var nextQuotaRetryAt: Date?
    @Published private(set) var lastQueryFailure: QueryFailureDetail?

    private var sampler = SystemSampler()
    private let quotaClient: QuotaReadingClient
    private let clock: () -> Date
    private var systemTimer: Timer?
    private var quotaTimer: Timer?
    private var lastExpiredRefresh: Date?
    private let retryDelays: [TimeInterval] = [3, 8]
    private var retriesUsed = 0
    private var requestGeneration = 0
    private var acceptsRequests = true

    init(quotaClient: QuotaReadingClient = QuotaClient(), clock: @escaping () -> Date = Date.init) {
        self.quotaClient = quotaClient
        self.clock = clock
    }

    var quota: WeeklyQuota? {
        reading?.windows.first(where: { $0.id == selectedBucket }) ?? reading?.windows.first
    }

    var hasExpired: Bool { quota?.resetsAt.map { $0 <= now } ?? false }
    var quotaIsStale: Bool {
        isRefreshing || quotaError != nil || hasExpired || (reading.map { now.timeIntervalSince($0.receivedAt) > 180 } ?? false)
    }
    var remaining: Double? { hasExpired ? nil : quota?.remainingPercent }

    var accountLabel: String {
        reading?.account.displayName ?? (quotaError == nil ? "读取账号中…" : "账号待确认")
    }

    var accountPlanLabel: String {
        if isRefreshing { return "核对中" }
        return reading?.account.planName ?? "—"
    }

    var memoryPercent: Double? {
        guard let system, let used = system.memoryUsedBytes, system.memoryTotalBytes > 0 else { return nil }
        return Double(used) / Double(system.memoryTotalBytes) * 100
    }

    var memoryDetail: String {
        guard let system, let used = system.memoryUsedBytes else { return "等待采样" }
        return String(format: "%.1f / %.0f GiB", Double(used) / 1_073_741_824, Double(system.memoryTotalBytes) / 1_073_741_824)
    }

    var quotaStatus: String {
        if isRefreshing { return "正在核对账号与额度…" }
        if quotaError != nil { return lastQueryFailure?.summary ?? "查询失败" }
        if hasExpired { return "窗口已到期 · 等待服务器确认" }
        if reading?.account.authType == "signedOut" { return "未登录 Codex · 请先完成登录" }
        if let reading, !reading.account.supportsWeeklyQuota { return "当前登录方式不提供周额度" }
        if let reading, reading.windows.isEmpty { return "当前账户未返回周额度" }
        if let reading { return "额度更新于 \(MonitorFormat.clock.string(from: reading.receivedAt))" }
        return "正在读取 Codex 额度…"
    }

    var quotaDetailStatus: String {
        if let deadline = nextQuotaRetryAt {
            let seconds = max(0, Int(ceil(deadline.timeIntervalSince(now))))
            return "\(seconds) 秒后自动重试（\(retriesUsed)/\(retryDelays.count)）"
        }
        if quotaError != nil { return "可手动刷新 · 详情见右侧信息按钮" }
        return " "
    }

    var queryErrorDetails: String {
        guard let failure = lastQueryFailure else { return "本次运行尚无查询错误。" }
        let timestamp = MonitorFormat.resetDate.string(from: failure.occurredAt)
        return "上次失败：\(timestamp)\n\n\(failure.detail)\n\n" +
            (quotaError == nil ? "当前查询已恢复。" : "账号与额度暂不显示，以免误认旧账号数据。")
    }

    func start() {
        guard systemTimer == nil else { return }
        acceptsRequests = true
        systemTimer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in self?.tick() }
        quotaTimer = Timer(timeInterval: 60, repeats: true) { [weak self] _ in self?.refreshQuotaAutomatically() }
        if let systemTimer { RunLoop.main.add(systemTimer, forMode: .common) }
        if let quotaTimer { RunLoop.main.add(quotaTimer, forMode: .common) }
        refreshQuota()
        tick()
    }

    func tick() {
        guard acceptsRequests else { return }
        system = sampler.sample()
        checkQuotaTimers()
    }

    // Uses the existing one-second timer, so retries cannot leave an extra timer
    // running after stop(). The clock is injectable for deterministic tests.
    func checkQuotaTimers() {
        guard acceptsRequests else { return }
        now = clock()
        if let deadline = nextQuotaRetryAt, deadline <= now, !isRefreshing {
            beginQuotaRequest(resetRetries: false)
            return
        }
        if hasExpired, let reset = quota?.resetsAt, lastExpiredRefresh != reset,
           !isRefreshing, nextQuotaRetryAt == nil {
            lastExpiredRefresh = reset
            refreshQuotaAutomatically()
        }
    }

    func wake() {
        guard acceptsRequests else { return }
        sampler = SystemSampler()
        refreshQuota()
        tick()
    }

    func refreshQuota() {
        beginQuotaRequest(resetRetries: true)
    }

    func refreshQuotaAutomatically() {
        guard nextQuotaRetryAt == nil else { return }
        beginQuotaRequest(resetRetries: true)
    }

    private func beginQuotaRequest(resetRetries: Bool) {
        // Menu actions share this guard with the disabled refresh button.
        guard acceptsRequests, !isRefreshing else { return }
        if resetRetries { retriesUsed = 0 }
        nextQuotaRetryAt = nil
        isRefreshing = true
        requestGeneration += 1
        let generation = requestGeneration
        quotaClient.read { [weak self] result in
            guard let self, self.acceptsRequests, self.requestGeneration == generation else { return }
            self.isRefreshing = false
            self.applyQuotaResult(result)
        }
    }

    func applyQuotaResult(_ result: Result<QuotaReading, Error>) {
        switch result {
        case .success(let reading):
            // Publish identity and quota as a single snapshot from one CLI request.
            self.reading = reading
            self.quotaError = nil
            self.nextQuotaRetryAt = nil
            self.retriesUsed = 0
        case .failure(let error):
            // The login may have changed since the last success. Never present an
            // old account or its quota as the currently authenticated identity.
            self.reading = nil
            // Unknown error payloads are never shown verbatim: they may contain
            // server diagnostics or account data outside our safe classifications.
            let safeError = error as? QuotaClientError ?? .serviceUnavailable
            now = clock()
            self.quotaError = safeError.localizedDescription
            self.lastQueryFailure = QueryFailureDetail(occurredAt: now, summary: safeError.shortDescription,
                                                       detail: safeError.localizedDescription)
            if acceptsRequests, safeError.shouldRetry, retriesUsed < retryDelays.count {
                nextQuotaRetryAt = now.addingTimeInterval(retryDelays[retriesUsed])
                retriesUsed += 1
            } else {
                nextQuotaRetryAt = nil
            }
        }
    }

    func stop() {
        acceptsRequests = false
        requestGeneration += 1
        systemTimer?.invalidate()
        quotaTimer?.invalidate()
        systemTimer = nil
        quotaTimer = nil
        nextQuotaRetryAt = nil
        isRefreshing = false
        quotaClient.cancel()
    }
}
