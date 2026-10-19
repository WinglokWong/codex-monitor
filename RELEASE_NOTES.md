# Codex Monitor v1.1.0

新增账户信息行，便于确认当前显示的是哪个 Codex CLI 账户的周额度。

- 显示脱敏邮箱与账户套餐，通过同一个本地 Codex CLI 的 `account/read` 和 `account/rateLimits/read` 查询账户及额度，每分钟自动刷新，也支持手动刷新。
- 明确显示 API key 模式和未登录状态；邮箱缺失或为 `null` 时显示无邮箱信息。
- 刷新失败时清空旧账户和旧额度，显示错误状态，避免切换登录后误认旧账户数据。
- 原始邮箱仅在内存中处理，不持久化或提交到仓库；token 仍由 Codex 管理。账户自测使用虚构数据。

未增加登录或切换账户界面。在现有 Codex CLI 中更换登录后，下一次成功刷新会显示新账户。CLI 与桌面应用使用不同登录时，以 CLI 当前账户为准。

继续提供剩余周额度、北京时间重置倒计时，以及每秒更新的 CPU、内存、上传／下载速率。保留可拖动置顶面板、位置记忆、Dock 和菜单栏入口及快捷键。

## 下载与安装

从 [最新 GitHub Release](https://github.com/WinglokWong/codex-monitor/releases/latest) 下载 `Codex-Monitor-1.1.0-universal.dmg`。支持 macOS 13 及更新版本，包含 Apple Silicon（arm64）和 Intel（x86_64）架构。

已在 macOS 26 / Apple Silicon 实机验证。Intel 二进制已构建，尚未在 Intel Mac 实机验证。

打开 DMG，将 **Codex Monitor.app** 拖入 **Applications**，再从“应用程序”启动。周额度需要本机已安装 Codex，并登录支持额度查询的账户。启动后，将面板拖到宠物旁即可。

同时下载发布附件中的 `SHA256SUMS.txt`，在两个下载文件所在的目录执行 `shasum -a 256 -c SHA256SUMS.txt`，可核对 DMG 是否完整。

## 签名与已知限制

Codex Monitor 是独立的第三方应用，与 OpenAI 没有官方关联。它通过本机 Codex CLI 查询账户额度；CLI 接口变化可能影响额度读取。

本版本使用本地 **ad-hoc 签名**，尚未使用 **Apple Developer ID 签名或 Apple 公证**。首次打开时，macOS 可能要求在“隐私与安全性”中明确确认。请核对下载来源与 SHA256 校验值，再决定是否打开。

内存使用率为物理内存估算值，可能与活动监视器略有差异。网速汇总活动物理网卡流量，单位为字节/秒，包含局域网流量和 VPN 的物理传输开销；接口变化或电脑唤醒后需要重新采样。
