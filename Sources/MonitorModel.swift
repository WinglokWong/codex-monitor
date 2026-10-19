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

final class MonitorModel: ObservableObject {
    @Published var system: SystemSnapshot?
    @Published var reading: QuotaReading?
    @Published var quotaError: String?
    @Published var isRefreshing = false
    @Published var now = Date()
    @Published var selectedBucket = "codex.primary"
    @Published var pinned = true

    private var sampler = SystemSampler()
    private let quotaClient = QuotaClient()
    private var systemTimer: Timer?
    private var quotaTimer: Timer?
    private var lastExpiredRefresh: Date?

    var quota: WeeklyQuota? {
        reading?.windows.first(where: { $0.id == selectedBucket }) ?? reading?.windows.first
    }

    var hasExpired: Bool { quota?.resetsAt.map { $0 <= now } ?? false }
    var quotaIsStale: Bool {
        quotaError != nil || hasExpired || (reading.map { now.timeIntervalSince($0.receivedAt) > 180 } ?? false)
    }
    var remaining: Double? { hasExpired ? nil : quota?.remainingPercent }

    var memoryPercent: Double? {
        guard let system, let used = system.memoryUsedBytes, system.memoryTotalBytes > 0 else { return nil }
        return Double(used) / Double(system.memoryTotalBytes) * 100
    }

    var memoryDetail: String {
        guard let system, let used = system.memoryUsedBytes else { return "等待采样" }
        return String(format: "%.1f / %.0f GiB", Double(used) / 1_073_741_824, Double(system.memoryTotalBytes) / 1_073_741_824)
    }

    var quotaStatus: String {
        if isRefreshing { return "正在刷新额度…" }
        if quotaError != nil {
            return reading.map { "更新失败 · 上次成功 \(MonitorFormat.clock.string(from: $0.receivedAt))" } ?? "额度暂不可用 · 可点右上角重试"
        }
        if hasExpired { return "窗口已到期 · 等待服务器确认" }
        if let reading, reading.windows.isEmpty { return "当前账户未返回周额度" }
        if let reading { return "额度更新于 \(MonitorFormat.clock.string(from: reading.receivedAt))" }
        return "正在读取 Codex 额度…"
    }

    func start() {
        tick()
        systemTimer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in self?.tick() }
        quotaTimer = Timer(timeInterval: 60, repeats: true) { [weak self] _ in self?.refreshQuota() }
        if let systemTimer { RunLoop.main.add(systemTimer, forMode: .common) }
        if let quotaTimer { RunLoop.main.add(quotaTimer, forMode: .common) }
        refreshQuota()
    }

    func tick() {
        now = Date()
        system = sampler.sample()
        if hasExpired, let reset = quota?.resetsAt, lastExpiredRefresh != reset, !isRefreshing {
            lastExpiredRefresh = reset
            refreshQuota()
        }
    }

    func wake() {
        sampler = SystemSampler()
        tick()
        refreshQuota()
    }

    func refreshQuota() {
        guard !isRefreshing else { return }
        isRefreshing = true
        quotaClient.read { [weak self] result in
            guard let self else { return }
            self.isRefreshing = false
            switch result {
            case .success(let reading):
                self.reading = reading
                self.quotaError = nil
            case .failure(let error):
                self.quotaError = error.localizedDescription
            }
        }
    }

    func stop() {
        systemTimer?.invalidate()
        quotaTimer?.invalidate()
        quotaClient.cancel()
    }
}
