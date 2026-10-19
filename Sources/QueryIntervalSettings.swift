import Foundation
import CoreFoundation
import SwiftUI

enum QueryIntervalPreferences {
    static let allowedRange = 1...10_080
    static let accountKey = "accountQueryIntervalMinutes"
    static let quotaKey = "quotaQueryIntervalMinutes"

    static func load(from defaults: UserDefaults = .standard) -> (accountMinutes: Int, quotaMinutes: Int) {
        func minutes(_ key: String) -> Int {
            guard let number = defaults.object(forKey: key) as? NSNumber,
                  CFGetTypeID(number) != CFBooleanGetTypeID(), number.doubleValue.isFinite,
                  number.doubleValue.rounded() == number.doubleValue,
                  number.doubleValue >= 1, number.doubleValue <= 10_080 else { return 1 }
            return number.intValue
        }
        return (minutes(accountKey), minutes(quotaKey))
    }

    @discardableResult
    static func save(accountMinutes: Int, quotaMinutes: Int, to defaults: UserDefaults = .standard) -> Bool {
        guard allowedRange.contains(accountMinutes), allowedRange.contains(quotaMinutes) else { return false }
        defaults.set(accountMinutes, forKey: accountKey)
        defaults.set(quotaMinutes, forKey: quotaKey)
        return true
    }
}

struct QueryIntervalSettingsView: View {
    @ObservedObject var model: MonitorModel
    @Environment(\.dismiss) private var dismiss
    @State private var accountText: String
    @State private var quotaText: String

    init(model: MonitorModel) {
        self.model = model
        _accountText = State(initialValue: String(model.accountIntervalMinutes))
        _quotaText = State(initialValue: String(model.quotaIntervalMinutes))
    }

    private var values: (Int, Int)? {
        guard let account = Int(accountText.trimmingCharacters(in: .whitespacesAndNewlines)),
              let quota = Int(quotaText.trimmingCharacters(in: .whitespacesAndNewlines)),
              QueryIntervalPreferences.allowedRange.contains(account), QueryIntervalPreferences.allowedRange.contains(quota) else { return nil }
        return (account, quota)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 15) {
            Text("查询间隔").font(.headline)
            Text("账号和周额度分别设置，默认均为 1 分钟。")
                .font(.system(size: 12)).foregroundColor(.secondary)
            HStack {
                Text("账号查询").frame(width: 75, alignment: .leading)
                TextField("分钟", text: $accountText).textFieldStyle(.roundedBorder)
                    .accessibilityLabel("账号查询间隔")
                Text("分钟").foregroundColor(.secondary)
            }
            HStack {
                Text("周额度查询").frame(width: 75, alignment: .leading)
                TextField("分钟", text: $quotaText).textFieldStyle(.roundedBorder)
                    .accessibilityLabel("周额度查询间隔")
                Text("分钟").foregroundColor(.secondary)
            }
            Text(values == nil ? "请输入 1–10080 之间的整数分钟。" : "可设置 1–10080 分钟，保存后安排下一次定时查询。")
                .font(.system(size: 11)).foregroundColor(values == nil ? .orange : .secondary)
            Text("周额度查询仍会核对账号身份，以免数据配错。系统资源保持每秒刷新，手动刷新与故障重试不受上述间隔限制。")
                .font(.system(size: 11)).foregroundColor(.secondary).fixedSize(horizontal: false, vertical: true)
            HStack {
                Button("恢复默认") { accountText = "1"; quotaText = "1" }
                Spacer()
                Button("取消") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("保存") {
                    if let (account, quota) = values,
                       model.setQueryIntervals(accountMinutes: account, quotaMinutes: quota) {
                        QueryIntervalPreferences.save(accountMinutes: account, quotaMinutes: quota)
                        dismiss()
                    }
                }.keyboardShortcut(.defaultAction).disabled(values == nil)
            }
        }
        .padding(22).frame(width: 360)
    }
}

func runIntervalPreferenceTests() throws {
    let suite = "CodexMonitor.IntervalTests.\(UUID().uuidString)"
    guard let defaults = UserDefaults(suiteName: suite) else { throw MonitorTestError(description: "Cannot create isolated preferences") }
    defer { defaults.removePersistentDomain(forName: suite) }
    func check(_ condition: Bool, _ message: String) throws { if !condition { throw MonitorTestError(description: message) } }
    let initial = QueryIntervalPreferences.load(from: defaults)
    try check(initial.accountMinutes == 1 && initial.quotaMinutes == 1, "Both query intervals must default to one minute")
    try check(QueryIntervalPreferences.save(accountMinutes: 2, quotaMinutes: 7, to: defaults), "Separate interval values must save")
    let saved = QueryIntervalPreferences.load(from: defaults)
    try check(saved.accountMinutes == 2 && saved.quotaMinutes == 7, "Separate intervals must survive reloading preferences")
    try check(!QueryIntervalPreferences.save(accountMinutes: 0, quotaMinutes: 4, to: defaults), "Invalid input must not overwrite either preference")
    try check(QueryIntervalPreferences.load(from: defaults).quotaMinutes == 7, "Rejected pair must be atomic")
    for invalid in [0, -1, 10_081, 1.5, true, "bad"] as [Any] {
        defaults.set(invalid, forKey: QueryIntervalPreferences.accountKey)
        try check(QueryIntervalPreferences.load(from: defaults).accountMinutes == 1, "Corrupted stored interval must fall back to one minute")
    }
}
