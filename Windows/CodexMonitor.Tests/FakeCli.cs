using System.Text;
using System.Text.Json;
using System.IO;

namespace CodexMonitor.Tests;

internal static class Synthetic
{
    internal const string Email = "synthetic.alice@example.test";
    internal const string ChangedEmail = "synthetic.bob@example.test";
    internal const string SameMaskEmail = "symphonic.anne@example.test";
    internal const string MaskedEmail = "sy***e@example.test";
    internal const string PrivateDiagnostic = "SYNTHETIC_PRIVATE_DIAGNOSTIC_DO_NOT_DISPLAY";
    internal static readonly DateTimeOffset Epoch = DateTimeOffset.FromUnixTimeSeconds(1_893_456_000);
    internal const string QuotaJson = """
        {"rateLimits":{"limitId":"codex","limitName":"Codex",
          "primary":{"usedPercent":5,"windowDurationMins":300,"resetsAt":1893456000},
          "secondary":{"usedPercent":27,"windowDurationMins":10080,"resetsAt":1893456000}},
         "rateLimitsByLimitId":null}
        """;
}

/// <summary>Re-entered through the test apphost. Uses only generated data and never starts real Codex.</summary>
internal static class FakeCli
{
    internal static async Task<int> RunAsync(string[] args)
    {
        if (!args.SequenceEqual(new[] { "app-server", "--listen", "stdio://" })) return 2;
        string scenario = Environment.GetEnvironmentVariable("CODEX_MONITOR_TEST_SCENARIO") ?? "chatgpt";
        string? trace = Environment.GetEnvironmentVariable("CODEX_MONITOR_TEST_TRACE");
        int accountReads = 0;
        object notification = new { method = "account/updated", @params = new { authMode = "chatgpt", planType = "plus" } };

        while (await Console.In.ReadLineAsync() is { } line)
        {
            if (trace is not null) await File.AppendAllTextAsync(trace, line + "\n");
            using JsonDocument document = JsonDocument.Parse(line);
            JsonElement request = document.RootElement;
            string? method = request.GetProperty("method").GetString();
            if (method == "initialized") continue;
            int id = request.GetProperty("id").GetInt32();
            if (method == "initialize")
            {
                await EmitAsync(new { id, result = new { userAgent = "SyntheticCodexTests" } });
                continue;
            }
            if (method == "account/read")
            {
                accountReads++;
                if (scenario == "account_error") { await FailAsync(id); continue; }
                if (scenario == "malformed_json")
                {
                    await Console.Out.WriteLineAsync("{synthetic invalid JSON");
                    await Console.Out.FlushAsync();
                    continue;
                }
                object? account;
                if (scenario == "signed_out") account = null;
                else if (scenario == "api_key") account = new { type = "apiKey" };
                else
                {
                    string email = accountReads > 1 && (scenario is "account_changed" or "silent_account_changed")
                        ? Synthetic.ChangedEmail
                        : accountReads > 1 && scenario == "same_mask_account_changed" ? Synthetic.SameMaskEmail : Synthetic.Email;
                    if (scenario == "same_mask_identity") email = Synthetic.SameMaskEmail;
                    account = new { type = "chatgpt", email, planType = "plus" };
                }
                object response = new { id, result = new { account, requiresOpenaiAuth = scenario != "api_key" } };
                if (accountReads > 1 && scenario == "benign_before_confirmation") await EmitAsync(notification);
                if (accountReads == 2 && scenario == "benign_after_confirmation")
                {
                    byte[] batch = Encoding.UTF8.GetBytes(JsonSerializer.Serialize(response) + "\n" + JsonSerializer.Serialize(notification) + "\n");
                    await Console.OpenStandardOutput().WriteAsync(batch);
                }
                else await EmitAsync(response);
                continue;
            }
            if (method == "account/rateLimits/read")
            {
                if (scenario == "quota_error") { await FailAsync(id); continue; }
                if (scenario == "structured_auth_error")
                {
                    await FailAsync(id, -32000, new { httpStatusCode = 401, detail = Synthetic.PrivateDiagnostic, email = Synthetic.Email });
                    continue;
                }
                if (scenario == "rate_limited") { await FailAsync(id, 429); continue; }
                if (scenario == "unknown_rpc_error")
                {
                    await FailAsync(id, -32071, new { detail = Synthetic.PrivateDiagnostic, email = Synthetic.Email });
                    continue;
                }
                if (scenario == "quota_eof")
                {
                    await Console.Error.WriteLineAsync(Synthetic.PrivateDiagnostic + ": " + Synthetic.Email);
                    return 0;
                }
                if (scenario is "account_changed" or "benign_before_quota") await EmitAsync(notification);
                using var quota = JsonDocument.Parse(Synthetic.QuotaJson);
                await EmitAsync(new { id, result = quota.RootElement });
                continue;
            }
            await FailAsync(id, -32601);
        }
        return 0;
    }

    private static async Task EmitAsync(object message)
    {
        await Console.Out.WriteLineAsync(JsonSerializer.Serialize(message));
        await Console.Out.FlushAsync();
    }

    private static Task FailAsync(int id, int code = -32603, object? data = null) => EmitAsync(new
    {
        id,
        error = new { code, message = Synthetic.PrivateDiagnostic + ": " + Synthetic.Email, data }
    });
}
