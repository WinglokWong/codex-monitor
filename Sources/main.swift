import AppKit
import SwiftUI

final class MonitorPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

final class DraggableHostingView<Content: View>: NSHostingView<Content> {
    override var mouseDownCanMoveWindow: Bool { true }
}

final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate, NSMenuDelegate {
    let model = MonitorModel()
    private var panel: MonitorPanel!
    private var statusItem: NSStatusItem!
    private var visibilityItem: NSMenuItem!
    private var pinItem: NSMenuItem!
    private var wakeObserver: NSObjectProtocol?
    private var screenObserver: NSObjectProtocol?

    func applicationDidFinishLaunching(_ notification: Notification) {
        let otherInstances = NSRunningApplication.runningApplications(withBundleIdentifier: "local.winglok.codex-monitor")
            .filter { $0.processIdentifier != ProcessInfo.processInfo.processIdentifier }
        if let existing = otherInstances.first {
            existing.activate(options: .activateAllWindows)
            NSApp.terminate(nil)
            return
        }

        model.pinned = UserDefaults.standard.object(forKey: "keepOnTop") as? Bool ?? true
        buildApplicationMenu()
        let content = MonitorView(model: model, hide: { [weak self] in self?.hidePanel() }, togglePinned: { [weak self] in self?.togglePin() })
        let host = DraggableHostingView(rootView: content)
        panel = MonitorPanel(contentRect: NSRect(x: 0, y: 0, width: 312, height: 375),
                             styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.title = "Codex Monitor"
        panel.contentView = host
        panel.setContentSize(host.fittingSize)
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        panel.isMovableByWindowBackground = true
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.level = model.pinned ? .floating : .normal
        panel.delegate = self
        if !panel.setFrameUsingName("CodexMonitorPanel") {
            if let screen = NSScreen.main {
                let bounds = screen.visibleFrame
                panel.setFrameOrigin(NSPoint(x: bounds.maxX - panel.frame.width - 30, y: bounds.minY + 90))
            }
        }
        // Autosaved frames from earlier versions include the old content height.
        // Preserve their top-left position while fitting the new account row.
        let restoredTop = panel.frame.maxY
        panel.setContentSize(host.fittingSize)
        panel.setFrameOrigin(NSPoint(x: panel.frame.minX, y: restoredTop - panel.frame.height))
        panel.setFrameAutosaveName("CodexMonitorPanel")
        ensureVisible()
        buildStatusMenu()
        panel.orderFrontRegardless()
        model.start()
        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in self?.model.wake() }
        screenObserver = NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in self?.ensureVisible() }
    }

    private func buildStatusMenu() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.image = NSImage(systemSymbolName: "waveform.path.ecg", accessibilityDescription: "Codex Monitor")
        statusItem.button?.toolTip = "Codex Monitor · 周额度与系统资源"
        let menu = NSMenu()
        let title = menu.addItem(withTitle: "Codex Monitor", action: nil, keyEquivalent: "")
        title.isEnabled = false
        menu.addItem(.separator())
        visibilityItem = menu.addItem(withTitle: "隐藏面板", action: #selector(toggleVisibility), keyEquivalent: "")
        visibilityItem.target = self
        let refresh = menu.addItem(withTitle: "刷新额度", action: #selector(refreshQuota), keyEquivalent: "r")
        refresh.target = self
        pinItem = menu.addItem(withTitle: "保持置顶", action: #selector(togglePin), keyEquivalent: "")
        pinItem.target = self
        menu.addItem(.separator())
        let quit = menu.addItem(withTitle: "退出监控", action: #selector(quit), keyEquivalent: "q")
        quit.target = self
        menu.delegate = self
        statusItem.menu = menu
    }

    private func buildApplicationMenu() {
        let menuBar = NSMenu()
        let appItem = NSMenuItem()
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "关于 Codex Monitor", action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
        appMenu.addItem(.separator())
        let show = appMenu.addItem(withTitle: "显示监控面板", action: #selector(showPanel), keyEquivalent: "1")
        show.target = self
        let refresh = appMenu.addItem(withTitle: "刷新额度", action: #selector(refreshQuota), keyEquivalent: "r")
        refresh.target = self
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "隐藏 Codex Monitor", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "退出 Codex Monitor", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = appMenu
        menuBar.addItem(appItem)
        NSApp.mainMenu = menuBar
    }

    func applicationDockMenu(_ sender: NSApplication) -> NSMenu? {
        let menu = NSMenu()
        let show = menu.addItem(withTitle: "显示监控面板", action: #selector(showPanel), keyEquivalent: "")
        show.target = self
        let refresh = menu.addItem(withTitle: "刷新额度", action: #selector(refreshQuota), keyEquivalent: "")
        refresh.target = self
        return menu
    }

    func menuWillOpen(_ menu: NSMenu) {
        visibilityItem.title = panel.isVisible ? "隐藏面板" : "显示面板"
        pinItem.state = model.pinned ? .on : .off
    }

    func ensureVisible() {
        guard let panel else { return }
        let frame = panel.frame
        if NSScreen.screens.contains(where: { $0.visibleFrame.contains(frame) }) { return }
        guard let screen = NSScreen.screens.max(by: { a, b in
            area(a.visibleFrame.intersection(frame)) < area(b.visibleFrame.intersection(frame))
        }) ?? NSScreen.main else { return }
        let bounds = screen.visibleFrame
        panel.setFrameOrigin(NSPoint(x: min(max(frame.minX, bounds.minX), bounds.maxX - frame.width),
                                     y: min(max(frame.minY, bounds.minY), bounds.maxY - frame.height)))
    }

    private func area(_ rect: NSRect) -> CGFloat { rect.isNull ? 0 : rect.width * rect.height }
    @objc func showPanel() {
        ensureVisible()
        NSApp.unhide(nil)
        panel?.orderFrontRegardless()
    }
    @objc func hidePanel() { panel.orderOut(nil) }
    @objc func toggleVisibility() {
        if panel.isVisible { hidePanel() } else { ensureVisible(); panel.orderFrontRegardless() }
    }
    @objc func togglePin() {
        model.pinned.toggle()
        panel.level = model.pinned ? .floating : .normal
        UserDefaults.standard.set(model.pinned, forKey: "keepOnTop")
    }
    @objc func refreshQuota() { model.refreshQuota() }
    @objc func quit() { NSApp.terminate(nil) }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showPanel()
        return true
    }
    func applicationDidBecomeActive(_ notification: Notification) {
        if panel != nil { showPanel() }
    }
    func applicationWillTerminate(_ notification: Notification) { model.stop() }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
}

struct MonitorTestError: Error, CustomStringConvertible { let description: String }

func runFormatTests() throws {
    func check(_ condition: Bool, _ message: String) throws {
        if !condition { throw MonitorTestError(description: message) }
    }
    let now = Date(timeIntervalSince1970: 1000)
    try check(MonitorFormat.percent(nil) == "—", "Missing measurements must not appear as zero")
    try check(MonitorFormat.speed(1024) == "1.0 KiB/s", "Network rate unit boundary")
    try check(MonitorFormat.speed(-1) == "—", "Counter reset must not show negative speed")
    try check(MonitorFormat.countdown(until: now, now: now) == "等待服务器更新", "Expired quota must await server confirmation")
    try check(MonitorFormat.countdown(until: now.addingTimeInterval(30), now: now) == "还有 1 分钟", "Countdown rounds up to avoid premature reset")
    try check(MonitorFormat.resetDate.string(from: Date(timeIntervalSince1970: 1792981758)) == "10月26日 10:29", "Reset timestamp must use Asia/Shanghai")
}

func runAccountStateTests() throws {
    func check(_ condition: Bool, _ message: String) throws {
        if !condition { throw MonitorTestError(description: message) }
    }
    let model = MonitorModel()
    let first = try QuotaClient.parseAccount(["account": ["type": "chatgpt", "email": "alice@example.com", "planType": "plus"]])
    let second = try QuotaClient.parseAccount(["account": ["type": "chatgpt", "email": "bob@example.com", "planType": "pro"]])
    let quota = WeeklyQuota(id: "codex.primary", label: "Codex", usedPercent: 20, resetsAt: nil)
    model.applyQuotaResult(.success(QuotaReading(windows: [quota], receivedAt: Date(), account: first)))
    try check(model.accountLabel == first.displayName && model.remaining == 80, "First account and quota must publish together")
    model.applyQuotaResult(.failure(QuotaClientError.serviceUnavailable))
    try check(model.reading == nil && model.remaining == nil && model.accountLabel == "账号待确认", "Failure must clear old identity and quota")
    model.applyQuotaResult(.success(QuotaReading(windows: [], receivedAt: Date(), account: second)))
    try check(model.accountLabel == second.displayName && model.remaining == nil && model.quotaError == nil, "Switching accounts must not reuse the first account's quota")
    let signedOut = try QuotaClient.parseAccount(["account": NSNull()])
    model.applyQuotaResult(.success(QuotaReading(windows: [], receivedAt: Date(), account: signedOut)))
    try check(model.remaining == nil && model.quotaStatus.contains("未登录"), "Signed-out state must not retain a previous balance")
}

func runProbe() -> Int32 {
    let sampler = SystemSampler()
    _ = sampler.sample()
    Thread.sleep(forTimeInterval: 1)
    let sample = sampler.sample()
    let client = QuotaClient()
    var result: Result<QuotaReading, Error>?
    client.read { result = $0 }
    let deadline = Date().addingTimeInterval(23)
    while result == nil && Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.1)) }
    client.cancel()
    var output: [String: Any] = [
        "cpuPercent": sample.cpuPercent as Any? ?? NSNull(),
        "memoryUsedBytes": sample.memoryUsedBytes as Any? ?? NSNull(),
        "memoryTotalBytes": sample.memoryTotalBytes,
        "downloadBytesPerSecond": sample.downloadBytesPerSecond as Any? ?? NSNull(),
        "uploadBytesPerSecond": sample.uploadBytesPerSecond as Any? ?? NSNull(),
        "interfaces": sample.interfaces
    ]
    var success = false
    switch result {
    case .success(let reading):
        output["account"] = [
            "authType": reading.account.authType,
            "displayName": reading.account.displayName,
            "maskedEmail": reading.account.maskedEmail as Any? ?? NSNull(),
            "planName": reading.account.planName as Any? ?? NSNull()
        ] as [String: Any]
        output["weeklyQuota"] = reading.windows.map { quota in
            ["id": quota.id, "remainingPercent": quota.remainingPercent,
             "resetsAt": quota.resetsAt.map { MonitorFormat.resetDate.string(from: $0) } as Any? ?? NSNull()] as [String: Any]
        }
        success = true
    case .failure(let error): output["quotaError"] = error.localizedDescription
    case .none: output["quotaError"] = "Probe timed out"
    }
    if let data = try? JSONSerialization.data(withJSONObject: output, options: [.prettyPrinted, .sortedKeys]), let text = String(data: data, encoding: .utf8) { print(text) }
    return success ? 0 : 1
}

if CommandLine.arguments.contains("--self-test") {
    do {
        try runQuotaTests()
        try runSystemMetricTests()
        try runFormatTests()
        try runAccountStateTests()
        print("PASS: quota and account parsing, identity state, system counters, and display semantics")
        exit(0)
    } catch { fputs("FAIL: \(error)\n", stderr); exit(1) }
}
if CommandLine.arguments.contains("--probe") { exit(runProbe()) }

let app = NSApplication.shared
app.setActivationPolicy(.regular)
let delegate = AppDelegate()
app.delegate = delegate
app.run()
