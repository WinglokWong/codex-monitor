# Codex Monitor for Windows

Windows 10/11 x64 原生悬浮监控工具，使用 C#、.NET 10 和 WPF 实现。macOS 版仍位于仓库根目录，两种平台分别构建。

## 运行

从 [v1.2.0-beta.2 发布页](https://github.com/WinglokWong/codex-monitor/releases/tag/v1.2.0-beta.2) 下载 `Codex-Monitor-1.2.0-beta.2-windows-x64.zip`，解压到一个固定文件夹，双击 `CodexMonitor.exe`。这是包含运行时的免安装包，不需要另外安装 .NET，也不要求管理员权限。

面向 Windows 10 22H2 和 Windows 11 x64，目前为预览版：通过 Windows 构建环境验证的范围会在发布页记录，尚不能替代不同 Windows 10/11 客户端机器、缩放比例及驱动组合的实机验证。

升级时从面板或托盘菜单退出旧版，再替换解压目录中的程序文件。窗口位置、置顶状态和已选择的 CLI 路径会保留；首次使用刷新间隔设置时，两项均为 1 分钟。

应用没有 Windows 代码签名证书，下载后的首次运行可能受到 SmartScreen 提示。确认下载来源及 SHA-256 校验值后按系统提供的正常流程处理，不需要关闭系统保护。

## 额度与账号

先在这台 Windows 电脑上安装并登录 [Codex CLI](https://learn.chatgpt.com/docs/cli)。确保终端中的 `codex` 能运行。监控读取的是这个本机 CLI 的当前账号，不会使用发布者的账号或 Mac 上的凭据。

- 默认在 PATH 中寻找 `codex.exe` / `codex.cmd`，并识别 npm 安装目录内的原生程序。
- 未能自动找到时，通过「… → 选择 Codex CLI」选择实际安装的程序，或在启动环境中指定 `CODEX_MONITOR_CLI`。
- 可通过「恢复自动查找 CLI」移除手动选择。
- 原样继承启动环境，由 Codex CLI 管理登录和代理；本程序不读取、复制或保存 token。
- 只有系统监控功能时不需要安装 Codex。

显示脱敏邮箱、套餐、周额度剩余百分比、北京时间重置时间与倒计时。正常状态通知不视为切换账号，完整额度查询结束前会再次核对身份。账号单独刷新确认身份变化后，立即清空旧额度，等待下一次周额度刷新或手动刷新成功后再显示新额度。失败时不显示旧账号数据，错误详情保留在本次运行内存中。

## 刷新间隔

打开面板右上角「… → 查询间隔」，分别设置「账号查询」和「周额度查询」。两项默认均为 **1 分钟**，只接受 **1–10080 的整数分钟**；空值、小数或超出范围的值不能保存。保存后用于后续自动刷新，并在重启后保留。CPU、内存、网速和倒计时继续每秒更新。

账号定时刷新只读取账号信息。周额度刷新执行完整查询，在读取额度前后额外核对身份，因此账号信息也可能随周额度查询更新。启动、手动刷新和失败重试仍可能触发额外查询；设置值是常规定时周期，不是所有请求的最小间隔。两类查询串行执行。

暂时故障的重试规则不变：当前查询最多追加两次快速重试，首次失败后等待 3 秒，第一次重试失败后再等待 8 秒；之后等待该类查询的下一次定时刷新，也可手动刷新。登录失效、CLI 未安装或请求过于频繁等错误不快速重试。

## 窗口与系统监控

- 拖动标题栏移动，默认置顶，位置和置顶设置会保存。
- Windows 任务栏有独立图标；关闭窗口会隐藏到托盘。托盘双击或重新启动程序可以恢复面板。
- 从「…」或托盘菜单退出才会结束程序；重复启动不会创建多个监控实例。
- `Ctrl+R` 立即刷新账号和额度。「上次查询错误」可查看安全处理后的错误及时间。
- 设置保存在 `%LOCALAPPDATA%\CodexMonitor\settings.json`，包含窗口位置、置顶状态、可选 CLI 路径和两项刷新间隔，不包含账号凭据。

CPU、内存与网速每秒采样。CPU 使用 `GetSystemTimes` 的时间差；超过 64 个逻辑处理器时明确标记为「当前处理器组」。内存为物理总量减可用量。网速累加活动的物理 Ethernet/Wi-Fi 网卡 64 位计数，排除 VPN/虚拟接口，包含局域网及 VPN 外层流量；首次采样、接口变化、休眠或计数重置时暂显示 `—`。虚拟机可能没有被识别为物理网卡的接口。

## 开发与验证

Windows 开发环境安装 .NET 10 SDK，然后运行：

```powershell
./Windows/build-release.ps1
```

脚本编译应用及测试，运行解析、隐私、协议、独立刷新周期、间隔校验、重试生命周期和 Windows 原生采集测试，渲染合成数据的 WPF 预览图，最后输出 `Windows/artifacts/` 下的 ZIP 和 `SHA256SUMS.txt`。

也可在 Mac 上交叉编译检查：

```sh
dotnet build Windows/CodexMonitor.Tests/CodexMonitor.Tests.csproj -c Release -p:EnableWindowsTargeting=true
```

WPF 与 Windows 原生 API 只能在 Windows 执行。GitHub Actions 的 `Windows build and tests` 工作流用于实际 Windows 编译、自动测试、原生 API 冒烟和界面渲染；测试只使用合成账号，不需要 GitHub Secrets 或真实 Codex 凭据。

此项目是独立第三方工具，与 OpenAI 没有官方关联。Windows 包自带的 .NET/WPF 组件遵循相应的许可，运行时包提供的许可文本随发行包放在 `licenses/`。
