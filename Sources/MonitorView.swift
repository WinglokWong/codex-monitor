import AppKit
import SwiftUI

private let monitorGreen = Color(red: 0.54, green: 0.91, blue: 0.71)
private let monitorMuted = Color(red: 0.59, green: 0.64, blue: 0.67)

struct MonitorView: View {
    @ObservedObject var model: MonitorModel
    var hide: () -> Void
    var togglePinned: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 7) {
                Image(systemName: "waveform.path.ecg").font(.system(size: 14, weight: .semibold)).foregroundColor(monitorGreen)
                Text("CODEX MONITOR").font(.system(size: 10, weight: .bold, design: .rounded)).tracking(1.6)
                Spacer()
                Button(action: { model.refreshQuota() }) {
                    Image(systemName: "arrow.clockwise").font(.system(size: 11, weight: .medium))
                }.buttonStyle(.plain).disabled(model.isRefreshing).help("刷新周额度（每分钟自动更新）")
                Menu {
                    Button(model.pinned ? "取消置顶" : "保持置顶", action: togglePinned)
                    Button("隐藏面板", action: hide)
                    Divider()
                    Button("退出监控") { NSApp.terminate(nil) }
                } label: {
                    Image(systemName: "ellipsis").font(.system(size: 13, weight: .bold))
                }.menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize().help("面板菜单")
            }
            .foregroundColor(monitorMuted)
            .padding(.bottom, 12)

            HStack(spacing: 7) {
                Image(systemName: "person.crop.circle").font(.system(size: 13)).foregroundColor(monitorMuted)
                Text(model.accountLabel)
                    .font(.system(size: 11, weight: .medium)).lineLimit(1).truncationMode(.middle)
                Spacer(minLength: 4)
                Text(model.accountPlanLabel)
                    .font(.system(size: 9, weight: .semibold)).lineLimit(1).truncationMode(.tail)
                    .padding(.horizontal, 7).padding(.vertical, 3)
                    .foregroundColor(monitorGreen)
                    .background(Capsule().fill(monitorGreen.opacity(0.10)))
                    .frame(maxWidth: 92, alignment: .trailing)
            }
            .padding(.horizontal, 9).padding(.vertical, 8)
            .background(RoundedRectangle(cornerRadius: 9).fill(Color.white.opacity(0.04)))
            .padding(.bottom, 14)
            .help("额度来自本机 Codex CLI 的登录账号。邮箱已脱敏；可在 Codex 中登录或切换账号后刷新。")

            HStack(alignment: .center) {
                Text("本周剩余额度").font(.system(size: 12, weight: .medium))
                Spacer()
                if let windows = model.reading?.windows, windows.count > 1 {
                    Menu {
                        ForEach(windows, id: \.id) { quota in
                            Button(quota.label) { model.selectedBucket = quota.id }
                        }
                    } label: {
                        Text(model.quota?.label ?? "Codex").lineLimit(1).truncationMode(.middle).frame(maxWidth: 100)
                    }.font(.system(size: 10)).menuStyle(.borderlessButton).frame(maxWidth: 112)
                } else {
                    Text("7 DAYS").font(.system(size: 9, weight: .medium, design: .monospaced)).foregroundColor(monitorMuted)
                }
            }
            HStack(alignment: .lastTextBaseline, spacing: 3) {
                Text(model.remaining.map { String(format: "%.0f", $0) } ?? "—")
                    .font(.system(size: 43, weight: .medium, design: .rounded)).monospacedDigit()
                Text("%").font(.system(size: 20, weight: .regular, design: .rounded)).foregroundColor(monitorMuted)
                Spacer()
                if model.quotaIsStale {
                    Label("待更新", systemImage: "clock").font(.system(size: 10)).foregroundColor(.orange)
                } else if model.quota != nil {
                    Circle().fill(monitorGreen).frame(width: 5, height: 5)
                    Text("已同步").font(.system(size: 10)).foregroundColor(monitorGreen)
                }
            }
            .padding(.top, 5).padding(.bottom, 7)
            Meter(value: model.remaining, color: quotaColor).frame(height: 5)
            HStack {
                Text(model.quota?.resetsAt.map { "\(MonitorFormat.resetDate.string(from: $0)) 重置" } ?? "重置时间 —")
                Spacer()
                Text("北京时间").foregroundColor(monitorMuted)
            }.font(.system(size: 10)).padding(.top, 10)
            Text(MonitorFormat.countdown(until: model.quota?.resetsAt, now: model.now))
                .font(.system(size: 10)).foregroundColor(monitorMuted).padding(.top, 4)

            divider.padding(.vertical, 15)

            HStack(spacing: 21) {
                resource(label: "CPU", value: model.system?.cpuPercent, detail: "全系统", color: monitorGreen)
                resource(label: "内存", value: model.memoryPercent, detail: model.memoryDetail, color: Color(red: 0.63, green: 0.74, blue: 1))
                    .help("驻留非文件页（扣除可清除页）+ wired + 实际压缩内存；不含文件缓存。是估算值，可能与活动监视器略有差异。")
            }

            HStack(spacing: 21) {
                network(label: "下载", symbol: "arrow.down", value: model.system?.downloadBytesPerSecond)
                network(label: "上传", symbol: "arrow.up", value: model.system?.uploadBytesPerSecond)
            }.padding(.top, 17)
                .help("活动物理网卡合计：\(model.system?.interfaces.joined(separator: ", ") ?? "等待采样")。排除回环和 VPN 虚拟接口，单位为字节/秒。")

            divider.padding(.top, 15).padding(.bottom, 10)
            HStack(spacing: 5) {
                Circle().fill(model.quotaIsStale ? Color.orange : monitorMuted).frame(width: 4, height: 4)
                Text(model.quotaStatus).lineLimit(1)
                Spacer(minLength: 0)
            }.font(.system(size: 9)).foregroundColor(monitorMuted)
                .help(model.quotaError ?? model.system?.error ?? "系统资源每秒采样；额度每分钟刷新。拖动面板空白处可移动。")
        }
        .padding(18)
        .frame(width: 312)
        .foregroundColor(Color(red: 0.91, green: 0.94, blue: 0.95))
        .background(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .fill(Color(red: 0.075, green: 0.095, blue: 0.105).opacity(0.97))
                .overlay(RoundedRectangle(cornerRadius: 20, style: .continuous).strokeBorder(.white.opacity(0.10), lineWidth: 1))
        )
        .preferredColorScheme(.dark)
    }

    private var quotaColor: Color {
        guard let remaining = model.remaining else { return monitorMuted }
        return remaining <= 10 ? .red : remaining <= 25 ? .orange : monitorGreen
    }

    private var divider: some View { Rectangle().fill(Color.white.opacity(0.08)).frame(height: 1) }

    private func resource(label: String, value: Double?, detail: String, color: Color) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(label).font(.system(size: 10)).foregroundColor(monitorMuted)
                Spacer(minLength: 0)
                Text(MonitorFormat.percent(value)).font(.system(size: 17, weight: .medium, design: .rounded)).monospacedDigit()
            }
            Meter(value: value, color: color).frame(height: 3)
            Text(detail).font(.system(size: 9)).foregroundColor(monitorMuted).lineLimit(1)
        }.frame(maxWidth: .infinity, alignment: .leading)
    }

    private func network(label: String, symbol: String, value: Double?) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 5) {
                Image(systemName: symbol).foregroundColor(monitorGreen)
                Text(label).foregroundColor(monitorMuted)
            }.font(.system(size: 10))
            Text(MonitorFormat.speed(value)).font(.system(size: 14, weight: .medium, design: .rounded)).monospacedDigit().lineLimit(1)
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct Meter: View {
    var value: Double?
    var color: Color
    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.white.opacity(0.08))
                Capsule().fill(color).frame(width: geometry.size.width * CGFloat(min(100, max(0, value ?? 0)) / 100))
            }
        }
    }
}
