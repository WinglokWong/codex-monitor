using System.ComponentModel;
using System.Globalization;
using System.Windows;
using System.Windows.Media;
using CodexMonitor.Core;
using MediaBrush = System.Windows.Media.Brush;

namespace CodexMonitor.Windows;

public sealed class MonitorViewModel : INotifyPropertyChanged
{
    private static readonly TimeZoneInfo Beijing = TimeZoneInfo.FindSystemTimeZoneById("China Standard Time");
    public static readonly MediaBrush Mint = new SolidColorBrush(System.Windows.Media.Color.FromRgb(138, 232, 181));
    public static readonly MediaBrush Muted = new SolidColorBrush(System.Windows.Media.Color.FromRgb(152, 164, 170));
    public static readonly MediaBrush Amber = new SolidColorBrush(System.Windows.Media.Color.FromRgb(245, 174, 76));
    private SystemSnapshot? system;
    public MonitorState State { get; private set; }
    public event PropertyChangedEventHandler? PropertyChanged;

    public MonitorViewModel(IQuotaClient client, int accountIntervalMinutes = 1, int quotaIntervalMinutes = 1)
    {
        State = new MonitorState(client, accountIntervalMinutes: accountIntervalMinutes, quotaIntervalMinutes: quotaIntervalMinutes);
        State.PropertyChanged += StateChanged;
    }

    private void StateChanged(object? sender, PropertyChangedEventArgs args) => NotifyAll();
    public void NotifyAll() => PropertyChanged?.Invoke(this, new PropertyChangedEventArgs(null));
    public void SetSystem(SystemSnapshot value) { system = value; NotifyAll(); }
    public void ReplaceClient(IQuotaClient client)
    {
        int accountInterval = State.AccountIntervalMinutes, quotaInterval = State.QuotaIntervalMinutes;
        State.PropertyChanged -= StateChanged;
        State.Stop();
        State = new MonitorState(client, accountIntervalMinutes: accountInterval, quotaIntervalMinutes: quotaInterval);
        State.PropertyChanged += StateChanged;
        NotifyAll();
    }

    public bool CanRefresh => !State.IsRefreshing && !State.IsStopped;
    public string AccountLabel => State.Account?.DisplayName ?? (State.Error is null ? "读取账号中…" : "账号待确认");
    public string PlanLabel => State.IsRefreshing ? "核对中" : State.Account?.PlanName ?? "—";
    public string RefreshTooltip => $"立即刷新账号与额度；账号每 {State.AccountIntervalMinutes} 分钟、周额度每 {State.QuotaIntervalMinutes} 分钟定时查询。";
    public string RemainingText => State.RemainingPercent is { } value ? value.ToString("0", CultureInfo.InvariantCulture) : "—";
    public double RemainingValue => State.RemainingPercent ?? 0;
    public string SyncLabel => State.IsRefreshing ? "核对中" : State.IsStale ? "待更新" : State.CurrentQuota is null ? "—" : "● 已同步";
    public MediaBrush SyncBrush => State.IsStale ? Amber : State.CurrentQuota is null ? Muted : Mint;
    public MediaBrush QuotaBrush => State.RemainingPercent is <= 10 ? System.Windows.Media.Brushes.IndianRed : State.RemainingPercent is <= 25 ? Amber : Mint;
    public Visibility BucketSelectorVisibility => State.Reading?.Windows.Count > 1 ? Visibility.Visible : Visibility.Collapsed;
    public Visibility DefaultBucketVisibility => BucketSelectorVisibility == Visibility.Visible ? Visibility.Collapsed : Visibility.Visible;
    public string ResetText => State.CurrentQuota?.ResetsAt is { } reset ? BeijingDate(reset) + " 重置" : "重置时间 —";
    public string CountdownText
    {
        get
        {
            if (State.CurrentQuota?.ResetsAt is not { } reset) return "重置时间暂不可用";
            var delta = reset - State.Now;
            if (delta <= TimeSpan.Zero) return "等待服务器更新";
            var minutes = (long)Math.Ceiling(delta.TotalMinutes);
            return minutes >= 1440 ? $"还有 {minutes / 1440} 天 {minutes % 1440 / 60} 小时" : minutes >= 60 ? $"还有 {minutes / 60} 小时 {minutes % 60} 分钟" : $"还有 {minutes} 分钟";
        }
    }
    public string CpuText => Percent(system?.CpuPercent);
    public double CpuValue => system?.CpuPercent ?? 0;
    public string CpuScope => system?.CpuScope ?? "全系统";
    private double? MemoryPercent => system?.MemoryUsedBytes is { } used && system.MemoryTotalBytes > 0 ? used * 100.0 / system.MemoryTotalBytes : null;
    public string MemoryText => Percent(MemoryPercent);
    public double MemoryValue => MemoryPercent ?? 0;
    public string MemoryDetail => system?.MemoryUsedBytes is { } used ? $"{used / 1073741824.0:0.0} / {system.MemoryTotalBytes / 1073741824.0:0.#} GiB" : "等待采样";
    public string DownloadText => Speed(system?.DownloadBytesPerSecond);
    public string UploadText => Speed(system?.UploadBytesPerSecond);
    public string NetworkTooltip => "活动物理网卡合计：" + (system?.Interfaces.Count > 0 ? string.Join(", ", system.Interfaces) : "暂无") + "。不重复计入 VPN/虚拟网卡。" + (system?.Error is { } error ? "\n" + error : "");
    public bool HasFailure => State.LastFailure is not null;
    public string StatusText
    {
        get
        {
            if (State.IsRefreshing) return State.ActiveQueryKind == "account" ? "正在查询账号…" : "正在查询周额度…";
            if (State.Error is not null) return State.LastFailure?.ShortDescription ?? "查询失败";
            if (State.HasExpired) return "窗口已到期 · 等待服务器确认";
            if (State.Account?.AuthType == "signedOut") return "未登录 Codex · 请先完成登录";
            if (State.Account is { } account && !account.SupportsWeeklyQuota) return "当前登录方式不提供周额度";
            if (State.Reading is null && State.Account is not null) return "账号已确认 · 等待周额度查询";
            if (State.Reading?.Windows.Count == 0) return "当前账号未返回周额度";
            return State.Reading is { } valid ? "额度更新于 " + TimeZoneInfo.ConvertTime(valid.ReceivedAt, Beijing).ToString("HH:mm:ss") : "正在读取 Codex 额度…";
        }
    }
    public string DetailText
    {
        get
        {
            if (State.NextRetryAt is { } deadline)
            {
                string kind = State.NextQuotaRetryAt == deadline ? "额度" : "账号";
                return $"{Math.Max(0, Math.Ceiling((deadline - State.Now).TotalSeconds)):0} 秒后重试{kind}（{State.RetryAttempt}/2）";
            }
            return State.Error is not null ? "可手动刷新 · 右侧查看错误详情" : $"账号 {State.AccountIntervalMinutes} 分钟 · 额度 {State.QuotaIntervalMinutes} 分钟";
        }
    }
    public string ErrorDetails => State.LastFailure is { } failure
        ? "上次失败：" + (State.LastFailureAt is { } at ? BeijingDate(at) : "—") + "\n\n" + failure.Message + "\n\n" + (State.Error is null ? "当前查询已恢复。" : "暂不显示旧账号与额度，避免误认。")
        : "本次运行尚无查询错误。";
    private static string BeijingDate(DateTimeOffset date) => TimeZoneInfo.ConvertTime(date, Beijing).ToString("M月d日 HH:mm", CultureInfo.InvariantCulture);
    private static string Percent(double? value) => value is { } n && double.IsFinite(n) ? Math.Clamp(n, 0, 100).ToString("0") + "%" : "—";
    private static string Speed(double? value) => value is not { } n || !double.IsFinite(n) || n < 0 ? "—" : n >= 1048576 ? $"{n / 1048576:0.0} MiB/s" : n >= 1024 ? $"{n / 1024:0.0} KiB/s" : $"{n:0} B/s";
}
