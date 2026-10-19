using System.Text.Json;
using System.IO;
using CodexMonitor.Core;

namespace CodexMonitor.Tests;

internal static class Program
{
    private static int _passed;

    private static async Task<int> Main(string[] args)
    {
        if (args.FirstOrDefault() == "app-server") return await FakeCli.RunAsync(args);
        try
        {
            await RunAsync("quota parsing and masked identity", TestParsingAsync);
            await RunAsync("bounded retries and minute cadence", TestRetryScheduleAsync);
            await RunAsync("manual recovery and safe failure retention", TestRecoveryAsync);
            await RunAsync("stop cancels and suppresses late completion", TestStopAsync);
            await RunAsync("expiry and overlapping requests", TestExpiryAndOverlapAsync);
            await RunAsync("non-retryable failures", TestNonRetryableAsync);
            foreach (string scenario in new[] { "chatgpt", "benign_before_quota", "benign_before_confirmation", "benign_after_confirmation",
                "signed_out", "api_key", "account_changed", "silent_account_changed", "same_mask_account_changed", "account_error",
                "quota_error", "malformed_json", "structured_auth_error", "rate_limited", "unknown_rpc_error", "quota_eof" })
                await RunAsync("synthetic protocol: " + scenario, () => TestProtocolAsync(scenario));
            await RunAsync("system metric counter self-tests", RunMetricTestsAsync);
            if (OperatingSystem.IsWindows()) await RunAsync("native Windows system metrics", RunNativeMetricSmokeAsync);
            Console.WriteLine($"PASS: {_passed} test groups. No real Codex login or model calls used.");
            return 0;
        }
        catch (Exception error)
        {
            Console.Error.WriteLine("FAIL: " + error.Message);
            return 1;
        }
    }

    private static async Task RunAsync(string name, Func<Task> test)
    {
        await test();
        _passed++;
        Console.WriteLine("PASS: " + name);
    }

    private static void Require(bool condition, string message)
    {
        if (!condition) throw new InvalidOperationException(message);
    }

    private static JsonElement Json(string value)
    {
        using var document = JsonDocument.Parse(value);
        return document.RootElement.Clone();
    }

    private static AccountSummary Account => QuotaClient.ParseAccount(Json("""
        {"account":{"type":"chatgpt","email":"synthetic.alice@example.test","planType":"plus"}}
        """));

    private static QuotaReading Reading(DateTimeOffset at, DateTimeOffset? reset = null) =>
        new([new WeeklyQuota("codex.secondary", "Codex", 27, reset ?? at.AddDays(7))], at, Account);

    private static Task TestParsingAsync()
    {
        var account = Account;
        Require(account.MaskedEmail == Synthetic.MaskedEmail && account.DisplayName == Synthetic.MaskedEmail, "Email was not masked");
        Require(account.PlanName == "Plus" && account.SupportsWeeklyQuota, "ChatGPT plan mapping");
        var reading = QuotaClient.ParseQuota(Json(Synthetic.QuotaJson), account, Synthetic.Epoch);
        Require(reading.Windows.Count == 1 && reading.Windows[0].RemainingPercent == 73, "Weekly quota selection or remaining usage");
        Require(reading.Windows[0].ResetsAt == Synthetic.Epoch && reading.ReceivedAt == Synthetic.Epoch, "Unix timestamp units");
        AssertPrivateDataAbsent(JsonSerializer.Serialize(reading));
        foreach (string invalidUsage in new[] { "true", "null", "\"12\"" })
        {
            var invalid = Json("{\"rateLimits\":{\"secondary\":{\"windowDurationMins\":10080,\"usedPercent\":" + invalidUsage + "}}}");
            Require(QuotaClient.ParseQuota(invalid, account).Windows.Count == 0, "Invalid usage must not become zero");
        }
        Require(new WeeklyQuota("test", "test", 101, null).RemainingPercent == 0, "Remaining percentage clamp");
        foreach (string email in new[] { "", "not-an-email", "a@@example.test", "a b@example.test" })
        {
            var invalid = QuotaClient.ParseAccount(Json(JsonSerializer.Serialize(new { account = new { type = "chatgpt", email } })));
            Require(invalid.MaskedEmail is null, "Malformed email must not display");
        }
        Require(QuotaClient.ParseAccount(Json("{\"account\":null}")).AuthType == "signedOut", "Null account must mean signed out");
        Require(!QuotaClient.ParseAccount(Json("{\"account\":{\"type\":\"apiKey\"}}")).SupportsWeeklyQuota, "API key cannot imply weekly quota");
        return Task.CompletedTask;
    }

    private static async Task TestRetryScheduleAsync()
    {
        var clock = new FakeClock();
        var client = new QueueClient();
        for (int index = 0; index < 4; index++) client.Fail(QuotaErrorKind.NetworkUnavailable);
        var state = new MonitorState(client, () => clock.Now);
        await state.RefreshAsync();
        Require(state.RetryAttempt == 1 && state.NextRetryAt == clock.Now.AddSeconds(3), "First retry must wait three seconds");
        await state.RefreshAsync(automatic: true);
        Require(client.Calls == 1, "Periodic request must respect pending retry");
        await TickAsync(state, clock, 2);
        Require(client.Calls == 1, "Retry ran early");
        await TickAsync(state, clock, 3);
        Require(client.Calls == 2 && state.RetryAttempt == 2 && state.NextRetryAt == clock.Now.AddSeconds(8), "Second retry must wait eight seconds");
        await TickAsync(state, clock, 10);
        Require(client.Calls == 2, "Second retry ran early");
        await TickAsync(state, clock, 11);
        Require(client.Calls == 3 && state.NextRetryAt is null && state.RetryAttempt == 2, "Retries must stop after two attempts");
        await TickAsync(state, clock, 59);
        Require(client.Calls == 3, "Periodic request ran before one minute");
        await TickAsync(state, clock, 60);
        Require(client.Calls == 4 && state.RetryAttempt == 1, "Minute refresh must start a new retry budget");
        state.Stop();
    }

    private static async Task TestRecoveryAsync()
    {
        var clock = new FakeClock();
        var client = new QueueClient();
        client.Succeed(Reading(clock.Now));
        client.Add(_ => Task.FromException<QuotaReading>(new InvalidOperationException(Synthetic.PrivateDiagnostic + Synthetic.Email)));
        client.Succeed(Reading(clock.Now));
        var state = new MonitorState(client, () => clock.Now);
        int changes = 0;
        state.PropertyChanged += (_, _) => changes++;
        await state.RefreshAsync();
        Require(state.RemainingPercent == 73 && state.Reading?.Account == Account, "Successful snapshot must contain identity and usage");
        await state.RefreshAsync();
        Require(state.Reading is null && state.Error is not null, "Failure must clear old identity and quota");
        AssertPrivateDataAbsent(state.Error!);
        Require(state.LastFailure?.Kind == QuotaErrorKind.Unavailable && state.LastFailureAt == clock.Now, "Unknown failures must be sanitized and timestamped");
        var retained = state.LastFailure;
        await state.RefreshAsync();
        Require(state.Error is null && state.NextRetryAt is null && state.RetryAttempt == 0, "Manual recovery must clear retry/error state");
        Require(state.LastFailure == retained, "Last safe diagnostic must remain available after recovery");
        await TickAsync(state, clock, 3);
        Require(client.Calls == 3 && changes > 0, "Old retry must be canceled and changes must notify UI");
        state.Stop();
    }

    private static async Task TestStopAsync()
    {
        foreach (bool lateFailure in new[] { false, true })
        {
            var clock = new FakeClock();
            var pending = new TaskCompletionSource<QuotaReading>(TaskCreationOptions.RunContinuationsAsynchronously);
            var client = new QueueClient();
            client.Add(_ => pending.Task); // Deliberately ignores cancellation to exercise generation protection.
            var state = new MonitorState(client, () => clock.Now);
            Task refresh = state.RefreshAsync();
            Require(state.IsRefreshing, "In-flight request must be visible");
            state.Stop();
            Require(client.LastToken.IsCancellationRequested && !state.IsRefreshing && state.NextRetryAt is null, "Stop must cancel and clear scheduling");
            if (lateFailure) pending.SetException(new QuotaException(QuotaErrorKind.NetworkUnavailable));
            else pending.SetResult(Reading(clock.Now));
            await refresh;
            await TickAsync(state, clock, 120);
            await state.RefreshAsync();
            Require(client.Calls == 1 && state.Reading is null && state.Error is null && state.LastFailure is null, "Late completion or tick mutated stopped state");
        }
    }

    private static async Task TestExpiryAndOverlapAsync()
    {
        var clock = new FakeClock();
        var pending = new TaskCompletionSource<QuotaReading>(TaskCreationOptions.RunContinuationsAsynchronously);
        var client = new QueueClient();
        client.Add(_ => pending.Task);
        client.Succeed(Reading(clock.Now, clock.Now.AddSeconds(1)));
        var state = new MonitorState(client, () => clock.Now);
        Task first = state.RefreshAsync();
        await state.RefreshAsync();
        await state.TickAsync(clock.Now);
        Require(client.Calls == 1, "Overlapping requests must be suppressed");
        pending.SetResult(Reading(clock.Now, clock.Now.AddSeconds(1)));
        await first;
        await TickAsync(state, clock, 2);
        Require(client.Calls == 2 && state.HasExpired && state.RemainingPercent is null, "Expired window must hide old percentage and refresh");
        await TickAsync(state, clock, 3);
        Require(client.Calls == 2, "Same expired reset must not trigger a refresh loop");
        state.Stop();
    }

    private static async Task TestNonRetryableAsync()
    {
        foreach (var kind in new[] { QuotaErrorKind.Authentication, QuotaErrorKind.RateLimited, QuotaErrorKind.Cancelled })
        {
            var client = new QueueClient();
            client.Fail(kind);
            var state = new MonitorState(client);
            await state.RefreshAsync();
            Require(state.NextRetryAt is null && state.RetryAttempt == 0, kind + " should not retry immediately");
            state.Stop();
        }
    }

    private static Task TickAsync(MonitorState state, FakeClock clock, int elapsedSeconds)
    {
        clock.Now = Synthetic.Epoch.AddSeconds(elapsedSeconds);
        return state.TickAsync(clock.Now);
    }

    private static async Task TestProtocolAsync(string scenario)
    {
        string executable = Path.ChangeExtension(typeof(Program).Assembly.Location, OperatingSystem.IsWindows() ? ".exe" : null);
        Require(File.Exists(executable), "Tests need their generated apphost, not the dotnet host");
        string temporary = Path.Combine(Path.GetTempPath(), "CodexMonitor-Protocol-" + Guid.NewGuid().ToString("N"));
        Directory.CreateDirectory(temporary);
        string trace = Path.Combine(temporary, "requests.jsonl");
        string? oldScenario = Environment.GetEnvironmentVariable("CODEX_MONITOR_TEST_SCENARIO");
        string? oldTrace = Environment.GetEnvironmentVariable("CODEX_MONITOR_TEST_TRACE");
        try
        {
            Environment.SetEnvironmentVariable("CODEX_MONITOR_TEST_SCENARIO", scenario);
            Environment.SetEnvironmentVariable("CODEX_MONITOR_TEST_TRACE", trace);
            var client = new QuotaClient(executable);
            QuotaReading? reading = null;
            QuotaException? failure = null;
            using var deadline = new CancellationTokenSource(TimeSpan.FromSeconds(25));
            try { reading = await client.ReadAsync(deadline.Token); }
            catch (QuotaException error) { failure = error; }
            bool success = scenario is "chatgpt" or "benign_before_quota" or "benign_before_confirmation" or "benign_after_confirmation" or "signed_out" or "api_key";
            Require(success == (reading is not null && failure is null), "Unexpected protocol outcome: " + scenario);
            if (reading is not null)
            {
                AssertPrivateDataAbsent(JsonSerializer.Serialize(reading));
                if (scenario is "signed_out" or "api_key")
                    Require(reading.Windows.Count == 0 && !reading.Account.SupportsWeeklyQuota && reading.Account.MaskedEmail is null,
                        "Unsupported login published old quota or identity");
                else
                    Require(reading.Account.MaskedEmail == Synthetic.MaskedEmail && reading.Account.PlanName == "Plus"
                        && reading.Windows.Count == 1 && reading.Windows[0].RemainingPercent == 73, "Identity/quota pairing failed");
            }
            if (failure is not null)
            {
                AssertPrivateDataAbsent(failure.Message + failure.ShortDescription);
                if (scenario.Contains("account_changed", StringComparison.Ordinal))
                    Require(failure.Kind == QuotaErrorKind.AccountChanged, "True identity switch must fail confirmation");
                if (scenario == "structured_auth_error") Require(failure.Kind == QuotaErrorKind.Authentication && !failure.ShouldRetry, "Structured 401 classification");
                if (scenario == "rate_limited") Require(failure.Kind == QuotaErrorKind.RateLimited && !failure.ShouldRetry, "429 classification");
                if (scenario == "unknown_rpc_error") Require(failure.Kind == QuotaErrorKind.RpcFailure && failure.RpcCode == -32071 && failure.ShouldRetry, "Safe unknown RPC diagnostic");
                if (scenario == "quota_eof") Require(failure.Kind == QuotaErrorKind.ProcessExited && failure.Stage == "quota" && failure.ShouldRetry, "EOF stage diagnostic");
            }
            var requests = File.ReadAllLines(trace).Select(Json).ToArray();
            var methods = requests.Select(item => item.GetProperty("method").GetString()).ToList();
            var expected = new List<string> { "initialize", "initialized", "account/read" };
            bool quota = scenario is not ("signed_out" or "api_key" or "account_error" or "malformed_json");
            bool confirm = scenario is "chatgpt" or "benign_before_quota" or "benign_before_confirmation" or "benign_after_confirmation"
                or "account_changed" or "silent_account_changed" or "same_mask_account_changed";
            if (quota) expected.Add("account/rateLimits/read");
            if (confirm) expected.Add("account/read");
            if (scenario == "benign_after_confirmation") expected.Add("account/read");
            Require(methods.SequenceEqual(expected), "Unexpected request sequence: " + scenario);
            foreach (var request in requests.Where(item => item.GetProperty("method").GetString() == "account/read"))
                Require(!request.GetProperty("params").GetProperty("refreshToken").GetBoolean(), "Monitor must not force token refresh");
            var ids = requests.Where(item => item.TryGetProperty("id", out _)).Select(item => item.GetProperty("id").GetInt32()).ToArray();
            Require(ids.Distinct().Count() == ids.Length, "Request IDs must be unique");
        }
        finally
        {
            Environment.SetEnvironmentVariable("CODEX_MONITOR_TEST_SCENARIO", oldScenario);
            Environment.SetEnvironmentVariable("CODEX_MONITOR_TEST_TRACE", oldTrace);
            Directory.Delete(temporary, recursive: true);
        }
    }

    private static void AssertPrivateDataAbsent(string text)
    {
        foreach (string secret in new[] { Synthetic.Email, Synthetic.ChangedEmail, Synthetic.SameMaskEmail, Synthetic.PrivateDiagnostic })
            Require(!text.Contains(secret, StringComparison.Ordinal), "Raw synthetic account or diagnostic data leaked");
    }

    // The metric implementation exposes these entry points without test-framework packages.
    private static Task RunMetricTestsAsync()
    {
        CodexMonitor.Windows.SystemMetricsSelfTests.Run();
        return Task.CompletedTask;
    }

    private static Task RunNativeMetricSmokeAsync()
    {
        Console.WriteLine(CodexMonitor.Windows.SystemMetricsSelfTests.RunNativeSmoke());
        return Task.CompletedTask;
    }

    private sealed class FakeClock { internal DateTimeOffset Now = Synthetic.Epoch; }

    private sealed class QueueClient : IQuotaClient
    {
        private readonly Queue<Func<CancellationToken, Task<QuotaReading>>> _responses = new();
        internal int Calls { get; private set; }
        internal CancellationToken LastToken { get; private set; }
        internal void Add(Func<CancellationToken, Task<QuotaReading>> response) => _responses.Enqueue(response);
        internal void Succeed(QuotaReading reading) => Add(_ => Task.FromResult(reading));
        internal void Fail(QuotaErrorKind kind) => Add(_ => Task.FromException<QuotaReading>(new QuotaException(kind)));
        public Task<QuotaReading> ReadAsync(CancellationToken cancellationToken = default)
        {
            Calls++;
            LastToken = cancellationToken;
            Require(_responses.Count > 0, "Unexpected extra state request");
            return _responses.Dequeue()(cancellationToken);
        }
    }
}
