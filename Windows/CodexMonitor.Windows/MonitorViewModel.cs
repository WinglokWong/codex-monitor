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

    public MonitorViewModel(IQuotaClient client)
    {
        State = new MonitorState(client);
        State.PropertyChanged += StateChanged;
    }

    private void StateChanged(object? sender, PropertyChangedEventArgs args) => NotifyAll();
    public void NotifyAll() => PropertyChanged?.Invoke(this, new PropertyChangedEventArgs(null));
    public void SetSystem(SystemSnapshot value) { system = value; NotifyAll(); }
    public void ReplaceClient(IQuotaClient client)
    {
        State.PropertyChanged -= StateChanged;
        State.Stop();
        State = new MonitorState(client);
        State.PropertyChanged += StateChanged;
        NotifyAll();
    }

    public bool CanRefresh => !State.IsRefreshing && !State.IsStopped;
    public string AccountLabel => State.Reading?.Account.DisplayName ?? (State.Error is null ? "读取账号中…" : "账号待确认");
    public string PlanLabel => State.IsRefreshing ? "核对中" : State.Reading?.Account.PlanName ?? "—";
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
            if (State.IsRefreshing) return "正在核对账号与额度…";
            if (State.Error is not null) return State.LastFailure?.ShortDescription ?? "查询失败";
            if (State.HasExpired) return "窗口已到期 · 等待服务器确认";
            if (State.Reading?.Account.AuthType == "signedOut") return "未登录 Codex · 请先完成登录";
            if (State.Reading is { } reading && !reading.Account.SupportsWeeklyQuota) return "当前登录方式不提供周额度";
            if (State.Reading?.Windows.Count == 0) return "当前账号未返回周额度";
            return State.Reading is { } valid ? "额度更新于 " + TimeZoneInfo.ConvertTime(valid.ReceivedAt, Beijing).ToString("HH:mm:ss") : "正在读取 Codex 额度…";
        }
    }
    public string DetailText => State.NextRetryAt is { } deadline ? $"{Math.Max(0, Math.Ceiling((deadline - State.Now).TotalSeconds)):0} 秒后自动重试（{State.RetryAttempt}/2）" : State.Error is not null ? "可手动刷新 · 右侧查看错误详情" : " ";
    public string ErrorDetails => State.LastFailure is { } failure
        ? "上次失败：" + (State.LastFailureAt is { } at ? BeijingDate(at) : "—") + "\n\n" + failure.Message + "\n\n" + (State.Error is null ? "当前查询已恢复。" : "暂不显示旧账号与额度，避免误认。")
        : "本次运行尚无查询错误。";
    private static string BeijingDate(DateTimeOffset date) => TimeZoneInfo.ConvertTime(date, Beijing).ToString("M月d日 HH:mm", CultureInfo.InvariantCulture);
    private static string Percent(double? value) => value is { } n && double.IsFinite(n) ? Math.Clamp(n, 0, 100).ToString("0") + "%" : "—";
    private static string Speed(double? value) => value is not { } n || !double.IsFinite(n) || n < 0 ? "—" : n >= 1048576 ? $"{n / 1048576:0.0} MiB/s" : n >= 1024 ? $"{n / 1024:0.0} KiB/s" : $"{n:0} B/s";
}
