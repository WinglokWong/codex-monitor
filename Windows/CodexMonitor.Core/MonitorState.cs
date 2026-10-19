using System.ComponentModel;

namespace CodexMonitor.Core;

/// <summary>Two independent schedules sharing one serialized client and the host's one-second timer.</summary>
public sealed class MonitorState : INotifyPropertyChanged
{
    private static readonly TimeSpan[] RetryDelays = [TimeSpan.FromSeconds(3), TimeSpan.FromSeconds(8)];
    private readonly IQuotaClient _client;
    private readonly Func<DateTimeOffset> _clock;
    private readonly Schedule _accountSchedule = new();
    private readonly Schedule _quotaSchedule = new();
    private CancellationTokenSource? _activeCancellation;
    private DateTimeOffset? _lastExpiredReset;
    private long _generation;
    private bool _stopped;
    private string _selectedBucketId = "codex.primary";
    private string _lastQueryKind = "quota";

    public MonitorState(IQuotaClient client, Func<DateTimeOffset>? clock = null,
        int accountIntervalMinutes = 1, int quotaIntervalMinutes = 1)
    {
        _client = client ?? throw new ArgumentNullException(nameof(client));
        if (!ValidInterval(accountIntervalMinutes)) throw new ArgumentOutOfRangeException(nameof(accountIntervalMinutes));
        if (!ValidInterval(quotaIntervalMinutes)) throw new ArgumentOutOfRangeException(nameof(quotaIntervalMinutes));
        _clock = clock ?? (() => DateTimeOffset.UtcNow);
        Now = _clock();
        AccountIntervalMinutes = accountIntervalMinutes;
        QuotaIntervalMinutes = quotaIntervalMinutes;
        _accountSchedule.NextAt = Now.AddMinutes(accountIntervalMinutes);
        _quotaSchedule.NextAt = Now.AddMinutes(quotaIntervalMinutes);
    }

    public event PropertyChangedEventHandler? PropertyChanged;
    public QuotaReading? Reading { get; private set; }
    public AccountSummary? Account { get; private set; }
    public string? Error { get; private set; }
    public QuotaException? LastFailure { get; private set; }
    public DateTimeOffset? LastFailureAt { get; private set; }
    public bool IsRefreshing { get; private set; }
    public string? ActiveQueryKind { get; private set; }
    public DateTimeOffset Now { get; private set; }
    public int AccountIntervalMinutes { get; private set; }
    public int QuotaIntervalMinutes { get; private set; }
    public DateTimeOffset NextAccountQueryAt => _accountSchedule.NextAt;
    public DateTimeOffset NextQuotaQueryAt => _quotaSchedule.NextAt;
    public DateTimeOffset? NextAccountRetryAt => _accountSchedule.RetryAt;
    public DateTimeOffset? NextQuotaRetryAt => _quotaSchedule.RetryAt;
    public DateTimeOffset? NextRetryAt => EarliestRetry()?.RetryAt;
    public int RetryAttempt => (EarliestRetry() ?? (_lastQueryKind == "account" ? _accountSchedule : _quotaSchedule)).RetriesUsed;
    public bool IsStopped => _stopped;

    public string SelectedBucketId
    {
        get => _selectedBucketId;
        set
        {
            if (string.IsNullOrWhiteSpace(value) || _selectedBucketId == value) return;
            _selectedBucketId = value;
            NotifyChanged();
        }
    }

    public WeeklyQuota? CurrentQuota => Reading?.Windows.FirstOrDefault(window => window.Id == SelectedBucketId)
        ?? Reading?.Windows.FirstOrDefault();
    public bool HasExpired => CurrentQuota?.ResetsAt is { } reset && reset <= Now;
    public double? RemainingPercent => HasExpired ? null : CurrentQuota?.RemainingPercent;
    public bool IsStale => IsRefreshing || Error is not null || HasExpired
        || (Reading is not null && Now - Reading.ReceivedAt > TimeSpan.FromSeconds(Math.Max(180, QuotaIntervalMinutes * 180)));

    /// <summary>Validates both values atomically; only changed periodic deadlines move. Retries and active work remain intact.</summary>
    public bool SetQueryIntervals(int accountMinutes, int quotaMinutes)
    {
        if (!ValidInterval(accountMinutes) || !ValidInterval(quotaMinutes)) return false;
        Now = _clock();
        if (accountMinutes != AccountIntervalMinutes)
        {
            AccountIntervalMinutes = accountMinutes;
            _accountSchedule.NextAt = Now.AddMinutes(accountMinutes);
        }
        if (quotaMinutes != QuotaIntervalMinutes)
        {
            QuotaIntervalMinutes = quotaMinutes;
            _quotaSchedule.NextAt = Now.AddMinutes(quotaMinutes);
        }
        NotifyChanged();
        return true;
    }

    /// <summary>A manual full refresh resets both cycles. An automatic one respects the quota retry and future account schedule.</summary>
    public Task RefreshAsync(bool automatic = false)
    {
        if (_stopped || IsRefreshing || (automatic && _quotaSchedule.RetryAt is not null)) return Task.CompletedTask;
        Now = _clock();
        bool includeAccount = !automatic || _accountSchedule.IsDue(Now);
        return BeginAsync("quota", resetRetries: true, includeAccount,
            resetAccountRetries: !automatic || _accountSchedule.RetryAt is null);
    }

    public Task TickAsync(DateTimeOffset now)
    {
        if (_stopped) return Task.CompletedTask;
        Now = now;
        NotifyChanged();
        if (IsRefreshing) return Task.CompletedTask;
        bool accountDue = _accountSchedule.IsDue(now);
        bool quotaDue = _quotaSchedule.IsDue(now);
        if (_quotaSchedule.RetryAt is null && HasExpired && CurrentQuota?.ResetsAt is { } reset && _lastExpiredReset != reset)
        {
            _lastExpiredReset = reset;
            quotaDue = true;
        }
        // One quota read also verifies identity. Coalesce only an account task that
        // is actually due; incidental verification never delays its future schedule.
        if (quotaDue)
            return BeginAsync("quota", _quotaSchedule.RetryAt is null, accountDue, _accountSchedule.RetryAt is null);
        if (accountDue)
            return BeginAsync("account", _accountSchedule.RetryAt is null, includeAccount: false, resetAccountRetries: false);
        return Task.CompletedTask;
    }

    private async Task BeginAsync(string kind, bool resetRetries, bool includeAccount, bool resetAccountRetries)
    {
        if (_stopped || IsRefreshing) return;
        Now = _clock();
        Schedule schedule = kind == "account" ? _accountSchedule : _quotaSchedule;
        StartSchedule(schedule, resetRetries, kind == "account" ? AccountIntervalMinutes : QuotaIntervalMinutes);
        if (kind == "quota" && includeAccount) StartSchedule(_accountSchedule, resetAccountRetries, AccountIntervalMinutes);
        IsRefreshing = true;
        ActiveQueryKind = _lastQueryKind = kind;
        long generation = ++_generation;
        using var cancellation = new CancellationTokenSource();
        _activeCancellation = cancellation;
        NotifyChanged();
        try
        {
            QuotaReading result = kind == "account"
                ? await _client.ReadAccountAsync(cancellation.Token)
                : await _client.ReadAsync(cancellation.Token);
            if (_stopped || generation != _generation) return;
            Now = _clock();
            Account = result.Account;
            if (kind == "quota")
            {
                Reading = result;
                if (!result.Windows.Any(window => window.Id == _selectedBucketId))
                    _selectedBucketId = result.Windows.FirstOrDefault()?.Id ?? "codex.primary";
            }
            else if (Reading is { } old &&
                (string.IsNullOrEmpty(old.IdentityKey) || string.IsNullOrEmpty(result.IdentityKey)
                 || old.IdentityKey != result.IdentityKey || old.Account != result.Account))
            {
                // A masked email is not an identity key. Unknown or changed identity
                // clears the old quota, without bringing its next query forward.
                Reading = null;
            }
            Error = null;
            schedule.Succeed();
            if (kind == "quota" && includeAccount) _accountSchedule.Succeed();
        }
        catch (Exception exception)
        {
            if (_stopped || generation != _generation) return;
            var safe = exception as QuotaException ?? new QuotaException(
                exception is OperationCanceledException ? QuotaErrorKind.Cancelled : QuotaErrorKind.Unavailable, kind);
            Now = _clock();
            Account = null;
            Reading = null;
            Error = safe.Message;
            LastFailure = safe;
            LastFailureAt = Now;
            FailSchedule(schedule, safe);
            if (kind == "quota" && includeAccount) FailSchedule(_accountSchedule, safe);
        }
        finally
        {
            if (ReferenceEquals(_activeCancellation, cancellation)) _activeCancellation = null;
            if (!_stopped && generation == _generation)
            {
                IsRefreshing = false;
                ActiveQueryKind = null;
                NotifyChanged();
            }
        }
    }

    private void StartSchedule(Schedule schedule, bool resetRetries, int intervalMinutes)
    {
        if (resetRetries)
        {
            schedule.RetriesUsed = 0;
            schedule.NextAt = Now.AddMinutes(intervalMinutes);
        }
        schedule.RetryAt = null;
    }

    private void FailSchedule(Schedule schedule, QuotaException error)
    {
        schedule.RetryAt = error.ShouldRetry && schedule.RetriesUsed < RetryDelays.Length
            ? Now.Add(RetryDelays[schedule.RetriesUsed++]) : null;
    }

    private Schedule? EarliestRetry()
    {
        if (_accountSchedule.RetryAt is null) return _quotaSchedule.RetryAt is null ? null : _quotaSchedule;
        if (_quotaSchedule.RetryAt is null) return _accountSchedule;
        return _accountSchedule.RetryAt < _quotaSchedule.RetryAt ? _accountSchedule : _quotaSchedule;
    }

    public void Stop()
    {
        if (_stopped) return;
        _stopped = true;
        ++_generation;
        _accountSchedule.RetryAt = _quotaSchedule.RetryAt = null;
        IsRefreshing = false;
        ActiveQueryKind = null;
        _activeCancellation?.Cancel();
        NotifyChanged();
    }

    private static bool ValidInterval(int value) => value is >= 1 and <= 10_080;
    private void NotifyChanged() => PropertyChanged?.Invoke(this, new PropertyChangedEventArgs(null));

    private sealed class Schedule
    {
        internal DateTimeOffset NextAt;
        internal DateTimeOffset? RetryAt;
        internal int RetriesUsed;
        internal bool IsDue(DateTimeOffset now) => RetryAt is { } retry ? retry <= now : NextAt <= now;
        internal void Succeed() { RetryAt = null; RetriesUsed = 0; }
    }
}
