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
    func readAccount(completion: @escaping (Result<QuotaReading, Error>) -> Void)
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
    @Published private(set) var account: AccountSummary?
    @Published private(set) var accountIntervalMinutes: Int
    @Published private(set) var quotaIntervalMinutes: Int
    @Published private(set) var nextAccountPeriodicAt: Date
    @Published private(set) var nextQuotaPeriodicAt: Date
    @Published private(set) var nextAccountRetryAt: Date?
    @Published private(set) var nextQuotaRetryAt: Date?
    @Published private(set) var lastQueryFailure: QueryFailureDetail?

    private enum QueryKind { case account, quota }
    private enum DueReason { case newCycle, retry }
    private var sampler = SystemSampler()
    private let quotaClient: QuotaReadingClient
    private let clock: () -> Date
    private var systemTimer: Timer?
    private var lastExpiredRefresh: Date?
    private let retryDelays: [TimeInterval] = [3, 8]
    private var accountRetriesUsed = 0
    private var quotaRetriesUsed = 0
    private var activeKind: QueryKind?
    private var requestGeneration = 0
    private var acceptsRequests = true

    init(quotaClient: QuotaReadingClient = QuotaClient(), clock: @escaping () -> Date = Date.init,
         accountIntervalMinutes: Int = 1, quotaIntervalMinutes: Int = 1) {
        self.quotaClient = quotaClient
        self.clock = clock
        let accountMinutes = (1...10080).contains(accountIntervalMinutes) ? accountIntervalMinutes : 1
        let quotaMinutes = (1...10080).contains(quotaIntervalMinutes) ? quotaIntervalMinutes : 1
        self.accountIntervalMinutes = accountMinutes
        self.quotaIntervalMinutes = quotaMinutes
        let initial = clock()
        self.now = initial
        self.nextAccountPeriodicAt = initial.addingTimeInterval(Double(accountMinutes) * 60)
        self.nextQuotaPeriodicAt = initial.addingTimeInterval(Double(quotaMinutes) * 60)
    }

    var quota: WeeklyQuota? {
        reading?.windows.first(where: { $0.id == selectedBucket }) ?? reading?.windows.first
    }
    var hasExpired: Bool { quota?.resetsAt.map { $0 <= now } ?? false }
    var quotaIsStale: Bool {
        let threshold = max(180, Double(quotaIntervalMinutes) * 60 * 3)
        return isRefreshing || quotaError != nil || hasExpired ||
            (reading.map { now.timeIntervalSince($0.receivedAt) > threshold } ?? false)
    }
    var remaining: Double? { hasExpired ? nil : quota?.remainingPercent }
    var accountLabel: String { account?.displayName ?? (quotaError == nil ? "读取账号中…" : "账号待确认") }
    var accountPlanLabel: String { isRefreshing ? "核对中" : account?.planName ?? "—" }

    var memoryPercent: Double? {
        guard let system, let used = system.memoryUsedBytes, system.memoryTotalBytes > 0 else { return nil }
        return Double(used) / Double(system.memoryTotalBytes) * 100
    }
    var memoryDetail: String {
        guard let system, let used = system.memoryUsedBytes else { return "等待采样" }
        return String(format: "%.1f / %.0f GiB", Double(used) / 1_073_741_824, Double(system.memoryTotalBytes) / 1_073_741_824)
    }

    var quotaStatus: String {
        if isRefreshing { return activeKind == .account ? "正在查询账号…" : "正在核对账号与额度…" }
        if quotaError != nil { return lastQueryFailure?.summary ?? "查询失败" }
        if hasExpired { return "窗口已到期 · 等待服务器确认" }
        if account?.authType == "signedOut" { return "未登录 Codex · 请先完成登录" }
        if let account, !account.supportsWeeklyQuota { return "当前登录方式不提供周额度" }
        if let reading, reading.windows.isEmpty { return "当前账户未返回周额度" }
        if let reading { return "额度更新于 \(MonitorFormat.clock.string(from: reading.receivedAt))" }
        if account != nil { return "账号已更新 · 等待额度查询" }
        return "正在读取 Codex 额度…"
    }

    var quotaDetailStatus: String {
        let retries: [(Date, String, Int)] = [
            nextAccountRetryAt.map { ($0, "账号", accountRetriesUsed) },
            nextQuotaRetryAt.map { ($0, "额度", quotaRetriesUsed) }
        ].compactMap { $0 }
        if let next = retries.min(by: { $0.0 < $1.0 }) {
            let seconds = max(0, Int(ceil(next.0.timeIntervalSince(now))))
            return "\(seconds) 秒后重试\(next.1)（\(next.2)/\(retryDelays.count)）"
        }
        return quotaError != nil ? "可手动刷新 · 详情见右侧信息按钮" : "账号 \(accountIntervalMinutes) 分钟 · 额度 \(quotaIntervalMinutes) 分钟"
    }

    var queryErrorDetails: String {
        guard let failure = lastQueryFailure else { return "本次运行尚无查询错误。" }
        let timestamp = MonitorFormat.resetDate.string(from: failure.occurredAt)
        return "上次失败：\(timestamp)\n\n\(failure.detail)\n\n" +
            (quotaError == nil ? "当前查询已恢复。" : "账号与额度暂不显示，以免误认旧账号数据。")
    }

    @discardableResult
    func setQueryIntervals(accountMinutes: Int, quotaMinutes: Int) -> Bool {
        guard (1...10080).contains(accountMinutes), (1...10080).contains(quotaMinutes) else { return false }
        now = clock()
        if accountMinutes != accountIntervalMinutes {
            accountIntervalMinutes = accountMinutes
            nextAccountPeriodicAt = now.addingTimeInterval(Double(accountMinutes) * 60)
        }
        if quotaMinutes != quotaIntervalMinutes {
            quotaIntervalMinutes = quotaMinutes
            nextQuotaPeriodicAt = now.addingTimeInterval(Double(quotaMinutes) * 60)
        }
        return true
    }

    func start() {
        guard systemTimer == nil else { return }
        acceptsRequests = true
        systemTimer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in self?.tick() }
        if let systemTimer { RunLoop.main.add(systemTimer, forMode: .common) }
        refreshQuota()
        tick()
    }

    func tick() {
        guard acceptsRequests else { return }
        system = sampler.sample()
        checkQuotaTimers()
    }

    // One clock drives both independent schedules. All reads share a single serial slot.
    func checkQuotaTimers() {
        guard acceptsRequests else { return }
        now = clock()
        guard !isRefreshing else { return }
        let accountDue = dueReason(.account)
        var quotaDue = dueReason(.quota)
        if quotaDue == nil, nextQuotaRetryAt == nil, hasExpired,
           let reset = quota?.resetsAt, lastExpiredRefresh != reset {
            lastExpiredRefresh = reset
            quotaDue = .newCycle
        }
        if let quotaDue {
            beginRequest(.quota, accountReason: accountDue, quotaReason: quotaDue)
        } else if let accountDue {
            beginRequest(.account, accountReason: accountDue, quotaReason: nil)
        }
    }

    private func dueReason(_ kind: QueryKind) -> DueReason? {
        let retry = kind == .account ? nextAccountRetryAt : nextQuotaRetryAt
        if let retry { return retry <= now ? .retry : nil }
        let periodic = kind == .account ? nextAccountPeriodicAt : nextQuotaPeriodicAt
        return periodic <= now ? .newCycle : nil
    }

    func wake() {
        guard acceptsRequests else { return }
        sampler = SystemSampler()
        refreshQuota()
        tick()
    }

    // The manual action always obtains a full, verified account/quota snapshot.
    func refreshQuota() {
        beginRequest(.quota, accountReason: .newCycle, quotaReason: .newCycle)
    }

    // Retained for callers that explicitly signal a regular quota refresh.
    func refreshQuotaAutomatically() {
        guard nextQuotaRetryAt == nil else { return }
        now = clock()
        beginRequest(.quota, accountReason: dueReason(.account), quotaReason: .newCycle)
    }

    private func prepare(_ kind: QueryKind, reason: DueReason) {
        if kind == .account {
            nextAccountRetryAt = nil
            if reason == .newCycle {
                accountRetriesUsed = 0
                nextAccountPeriodicAt = now.addingTimeInterval(Double(accountIntervalMinutes) * 60)
            }
        } else {
            nextQuotaRetryAt = nil
            if reason == .newCycle {
                quotaRetriesUsed = 0
                nextQuotaPeriodicAt = now.addingTimeInterval(Double(quotaIntervalMinutes) * 60)
            }
        }
    }

    private func beginRequest(_ kind: QueryKind, accountReason: DueReason?, quotaReason: DueReason?) {
        guard acceptsRequests, !isRefreshing else { return }
        now = clock()
        if kind == .quota, let reset = quota?.resetsAt, reset <= now { lastExpiredRefresh = reset }
        if let accountReason { prepare(.account, reason: accountReason) }
        if let quotaReason { prepare(.quota, reason: quotaReason) }
        isRefreshing = true
        activeKind = kind
        requestGeneration += 1
        let generation = requestGeneration
        let completion: (Result<QuotaReading, Error>) -> Void = { [weak self] result in
            guard let self, self.acceptsRequests, self.requestGeneration == generation else { return }
            self.isRefreshing = false
            self.activeKind = nil
            self.applyResult(result, kind: kind, includesAccountCycle: accountReason != nil)
        }
        if kind == .account { quotaClient.readAccount(completion: completion) }
        else { quotaClient.read(completion: completion) }
    }

    // Existing test/probe callers can still apply a complete snapshot directly.
    func applyQuotaResult(_ result: Result<QuotaReading, Error>) {
        applyResult(result, kind: .quota, includesAccountCycle: true)
    }

    private func applyResult(_ result: Result<QuotaReading, Error>, kind: QueryKind, includesAccountCycle: Bool) {
        now = clock()
        switch result {
        case .success(let result):
            if kind == .quota {
                reading = result
                nextQuotaRetryAt = nil
                quotaRetriesUsed = 0
            } else if let previous = reading {
                // Missing identity evidence must not preserve potentially unrelated quota.
                let sameIdentity = previous.identityKey != nil && previous.identityKey == result.identityKey
                if !sameIdentity { reading = nil; lastExpiredRefresh = nil }
            }
            account = result.account
            quotaError = nil
            if kind == .account || includesAccountCycle {
                nextAccountRetryAt = nil
                accountRetriesUsed = 0
            }
        case .failure(let error):
            reading = nil
            account = nil
            let safe = error as? QuotaClientError ?? .serviceUnavailable
            let source = kind == .account ? "账号" : "额度"
            quotaError = source + "查询：" + safe.localizedDescription
            lastQueryFailure = QueryFailureDetail(occurredAt: now, summary: source + " · " + safe.shortDescription,
                                                  detail: source + "查询：" + safe.localizedDescription)
            scheduleRetry(kind, error: safe)
            if kind == .quota && includesAccountCycle { scheduleRetry(.account, error: safe) }
        }
    }

    private func scheduleRetry(_ kind: QueryKind, error: QuotaClientError) {
        let used = kind == .account ? accountRetriesUsed : quotaRetriesUsed
        let next = acceptsRequests && error.shouldRetry && used < retryDelays.count
            ? now.addingTimeInterval(retryDelays[used]) : nil
        if kind == .account {
            nextAccountRetryAt = next
            if next != nil { accountRetriesUsed += 1 }
        } else {
            nextQuotaRetryAt = next
            if next != nil { quotaRetriesUsed += 1 }
        }
    }

    func stop() {
        acceptsRequests = false
        requestGeneration += 1
        systemTimer?.invalidate()
        systemTimer = nil
        nextAccountRetryAt = nil
        nextQuotaRetryAt = nil
        activeKind = nil
        isRefreshing = false
        quotaClient.cancel()
    }
}
