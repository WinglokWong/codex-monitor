# Codex Monitor for Windows

Windows 10/11 x64 原生悬浮监控工具，使用 C#、.NET 10 和 WPF 实现。macOS 版仍位于仓库根目录，两种平台分别构建。

## 运行

下载 Windows x64 ZIP，解压到一个固定文件夹，双击 `CodexMonitor.exe`。这是包含运行时的免安装包，不需要另外安装 .NET，也不要求管理员权限。

面向 Windows 10 22H2 和 Windows 11 x64。首个版本为预览版：通过 Windows 构建环境验证的范围会在发布页记录，尚不能替代不同 Windows 10/11 客户端机器、缩放比例及驱动组合的实机验证。

应用没有 Windows 代码签名证书，下载后的首次运行可能受到 SmartScreen 提示。确认下载来源及 SHA-256 校验值后按系统提供的正常流程处理，不需要关闭系统保护。

## 额度与账号

先在这台 Windows 电脑上安装并登录 [Codex CLI](https://learn.chatgpt.com/docs/cli)。确保终端中的 `codex` 能运行。监控读取的是这个本机 CLI 的当前账号，不会使用发布者的账号或 Mac 上的凭据。

- 默认在 PATH 中寻找 `codex.exe` / `codex.cmd`，并识别 npm 安装目录内的原生程序。
- 未能自动找到时，通过「… → 选择 Codex CLI」选择实际安装的程序，或在启动环境中指定 `CODEX_MONITOR_CLI`。
- 可通过「恢复自动查找 CLI」移除手动选择。
- 原样继承启动环境，由 Codex CLI 管理登录和代理；本程序不读取、复制或保存 token。
- 只有系统监控功能时不需要安装 Codex。

显示脱敏邮箱、套餐、周额度剩余百分比、北京时间重置时间与倒计时。额度每分钟刷新；遇到短暂故障在 3 秒、8 秒后各重试一次。正常状态通知不视为切换账号，查询结束前会再次核对身份。失败时不显示旧账号数据，错误详情保留在本次运行内存中。

## 窗口与系统监控

- 拖动标题栏移动，默认置顶，位置和置顶设置会保存。
- Windows 任务栏有独立图标；关闭窗口会隐藏到托盘。托盘双击或重新启动程序可以恢复面板。
- 从「…」或托盘菜单退出才会结束程序；重复启动不会创建多个监控实例。
- `Ctrl+R` 刷新额度。「上次查询错误」可查看安全处理后的错误及时间。
- 设置保存在 `%LOCALAPPDATA%\CodexMonitor\settings.json`，只包含窗口位置、置顶状态和可选 CLI 路径。

CPU、内存与网速每秒采样。CPU 使用 `GetSystemTimes` 的时间差；超过 64 个逻辑处理器时明确标记为「当前处理器组」。内存为物理总量减可用量。网速累加活动的物理 Ethernet/Wi-Fi 网卡 64 位计数，排除 VPN/虚拟接口，包含局域网及 VPN 外层流量；首次采样、接口变化、休眠或计数重置时暂显示 `—`。虚拟机可能没有被识别为物理网卡的接口。

## 开发与验证

Windows 开发环境安装 .NET 10 SDK，然后运行：

```powershell
./Windows/build-release.ps1
```

脚本编译应用及测试，运行解析、隐私、协议、重试生命周期和 Windows 原生采集测试，渲染合成数据的 WPF 预览图，最后输出 `Windows/artifacts/` 下的 ZIP 和 `SHA256SUMS.txt`。

也可在 Mac 上交叉编译检查：

```sh
dotnet build Windows/CodexMonitor.Tests/CodexMonitor.Tests.csproj -c Release -p:EnableWindowsTargeting=true
```

WPF 与 Windows 原生 API 只能在 Windows 执行。GitHub Actions 的 `Windows build and tests` 工作流用于实际 Windows 编译、自动测试、原生 API 冒烟和界面渲染；测试只使用合成账号，不需要 GitHub Secrets 或真实 Codex 凭据。

此项目是独立第三方工具，与 OpenAI 没有官方关联。Windows 包自带的 .NET/WPF 组件遵循相应的许可，运行时包提供的许可文本随发行包放在 `licenses/`。
