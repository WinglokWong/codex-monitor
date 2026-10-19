using System;
using System.ComponentModel;
using System.Linq;
using System.Threading;
using System.Threading.Tasks;

namespace CodexMonitor.Core;

/// <summary>
/// Quota presentation state and scheduling. Call from one UI context; await keeps
/// that context for notifications. The host supplies its existing one-second tick.
/// </summary>
public sealed class MonitorState : INotifyPropertyChanged
{
    private static readonly TimeSpan[] RetryDelays = [TimeSpan.FromSeconds(3), TimeSpan.FromSeconds(8)];
    private readonly IQuotaClient _client;
    private readonly Func<DateTimeOffset> _clock;
    private CancellationTokenSource? _activeCancellation;
    private DateTimeOffset _nextPeriodicAt;
    private DateTimeOffset? _lastExpiredReset;
    private long _generation;
    private bool _stopped;
    private string _selectedBucketId = "codex.primary";

    public MonitorState(IQuotaClient client, Func<DateTimeOffset>? clock = null)
    {
        _client = client ?? throw new ArgumentNullException(nameof(client));
        _clock = clock ?? (() => DateTimeOffset.UtcNow);
        Now = _clock();
        _nextPeriodicAt = Now.AddMinutes(1);
    }

    public event PropertyChangedEventHandler? PropertyChanged;

    public QuotaReading? Reading { get; private set; }
    public string? Error { get; private set; }
    public QuotaException? LastFailure { get; private set; }
    public DateTimeOffset? LastFailureAt { get; private set; }
    public bool IsRefreshing { get; private set; }
    public DateTimeOffset? NextRetryAt { get; private set; }
    public DateTimeOffset Now { get; private set; }
    public int RetryAttempt { get; private set; }
    public bool IsStopped => _stopped;

    public string SelectedBucketId
    {
        get => _selectedBucketId;
        set
        {
            // WPF clears SelectedValue briefly while replacing ItemsSource.
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
        || (Reading is not null && Now - Reading.ReceivedAt > TimeSpan.FromMinutes(3));

    /// <summary>Manual refresh starts a new retry budget. Automatic refresh respects a pending retry.</summary>
    public Task RefreshAsync(bool automatic = false)
    {
        if (_stopped || IsRefreshing || (automatic && NextRetryAt is not null)) return Task.CompletedTask;
        return BeginRefreshAsync(resetRetries: true);
    }

    /// <summary>Updates the displayed clock and handles retries, reset expiry, and the 60-second cadence.</summary>
    public Task TickAsync(DateTimeOffset now)
    {
        if (_stopped) return Task.CompletedTask;
        Now = now;
        NotifyChanged();
        if (IsRefreshing) return Task.CompletedTask;
        if (NextRetryAt is { } retry)
            return retry <= now ? BeginRefreshAsync(resetRetries: false) : Task.CompletedTask;
        if (HasExpired && CurrentQuota?.ResetsAt is { } reset && _lastExpiredReset != reset)
        {
            _lastExpiredReset = reset;
            return BeginRefreshAsync(resetRetries: true);
        }
        return now >= _nextPeriodicAt ? BeginRefreshAsync(resetRetries: true) : Task.CompletedTask;
    }

    private async Task BeginRefreshAsync(bool resetRetries)
    {
        if (_stopped || IsRefreshing) return;
        Now = _clock();
        if (resetRetries)
        {
            RetryAttempt = 0;
            _nextPeriodicAt = Now.AddMinutes(1);
        }
        NextRetryAt = null;
        IsRefreshing = true;
        long generation = ++_generation;
        using var cancellation = new CancellationTokenSource();
        _activeCancellation = cancellation;
        NotifyChanged();

        try
        {
            QuotaReading reading = await _client.ReadAsync(cancellation.Token);
            if (_stopped || generation != _generation) return;
            Now = _clock();
            // Identity and usage are published atomically from one confirmed read.
            Reading = reading;
            if (!reading.Windows.Any(window => window.Id == _selectedBucketId))
                _selectedBucketId = reading.Windows.FirstOrDefault()?.Id ?? "codex.primary";
            Error = null;
            NextRetryAt = null;
            RetryAttempt = 0;
        }
        catch (Exception exception)
        {
            if (_stopped || generation != _generation) return;
            // Never copy an arbitrary exception message into the UI: it can
            // contain upstream account details or subprocess diagnostics.
            var safe = exception as QuotaException ?? new QuotaException(
                exception is OperationCanceledException ? QuotaErrorKind.Cancelled : QuotaErrorKind.Unavailable);
            Now = _clock();
            Reading = null;
            Error = safe.Message;
            LastFailure = safe;
            LastFailureAt = Now;
            if (safe.ShouldRetry && RetryAttempt < RetryDelays.Length)
                NextRetryAt = Now.Add(RetryDelays[RetryAttempt++]);
            else
                NextRetryAt = null;
        }
        finally
        {
            if (ReferenceEquals(_activeCancellation, cancellation)) _activeCancellation = null;
            if (!_stopped && generation == _generation)
            {
                IsRefreshing = false;
                NotifyChanged();
            }
        }
    }

    /// <summary>Cancels the active read and prevents late completions or future ticks from publishing.</summary>
    public void Stop()
    {
        if (_stopped) return;
        _stopped = true;
        ++_generation;
        NextRetryAt = null;
        IsRefreshing = false;
        _activeCancellation?.Cancel();
        NotifyChanged();
    }

    private void NotifyChanged() => PropertyChanged?.Invoke(this, new PropertyChangedEventArgs(null));
}
