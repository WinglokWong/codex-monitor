using System.ComponentModel;
using System.Diagnostics;
using System.Globalization;
using System.Security.Cryptography;
using System.Text;
using System.Text.Json;
using System.Text.Json.Serialization;

namespace CodexMonitor.Core;

public sealed record AccountSummary(string? MaskedEmail, string? PlanName, string AuthType)
{
    public static AccountSummary Unavailable { get; } = new(null, null, "unavailable");
    public bool SupportsWeeklyQuota => AuthType == "chatgpt";
    public string DisplayName => AuthType switch
    {
        "chatgpt" => MaskedEmail ?? "ChatGPT（无邮箱）",
        "signedOut" => "未登录",
        "apiKey" => "API Key",
        "amazonBedrock" => "Amazon Bedrock",
        "unavailable" => "账户暂不可用",
        _ => "其他认证方式"
    };
}

public sealed record WeeklyQuota(string Id, string Label, double UsedPercent, DateTimeOffset? ResetsAt)
{
    public double RemainingPercent => Math.Clamp(100 - UsedPercent, 0, 100);
}

public sealed record QuotaReading(IReadOnlyList<WeeklyQuota> Windows, DateTimeOffset ReceivedAt, AccountSummary Account,
    [property: JsonIgnore] string? IdentityKey = null);

public interface IQuotaClient
{
    Task<QuotaReading> ReadAsync(CancellationToken cancellationToken);
    Task<QuotaReading> ReadAccountAsync(CancellationToken cancellationToken);
}

public enum QuotaErrorKind
{
    Timeout, Unavailable, AccountChanged, InvalidResponse, CliUnavailable, Authentication,
    RateLimited, Rejected, ProcessExited, RpcFailure, LaunchFailed, NetworkUnavailable, Cancelled
}

/// <summary>Safe diagnostics: never retain a server message, email, token or child-process stderr.</summary>
public sealed class QuotaException : Exception
{
    public QuotaErrorKind Kind { get; }
    public string Stage { get; }
    public int? RpcCode { get; }

    public QuotaException(QuotaErrorKind kind, string stage = "quota", int? rpcCode = null)
        : base(Describe(kind, SafeStage(stage), rpcCode))
    {
        Kind = kind;
        Stage = SafeStage(stage);
        RpcCode = rpcCode;
    }

    public string ShortDescription => Kind switch
    {
        QuotaErrorKind.Timeout => "查询超时",
        QuotaErrorKind.Unavailable => "服务暂不可用",
        QuotaErrorKind.AccountChanged => "账户已变化",
        QuotaErrorKind.InvalidResponse => "数据无法识别",
        QuotaErrorKind.CliUnavailable => "未找到 Codex",
        QuotaErrorKind.Authentication => "需要重新登录",
        QuotaErrorKind.RateLimited => "请求过于频繁",
        QuotaErrorKind.Rejected => "请求被拒绝",
        QuotaErrorKind.ProcessExited => StageName(Stage) + "中断",
        QuotaErrorKind.RpcFailure => StageName(Stage) + "失败",
        QuotaErrorKind.LaunchFailed => "Codex 启动失败",
        QuotaErrorKind.NetworkUnavailable => "网络暂不可用",
        QuotaErrorKind.Cancelled => "已取消",
        _ => "额度查询失败"
    };

    public bool ShouldRetry => Retryable(Kind, RpcCode);

    public static QuotaException FromRpcError(JsonElement error, string stage)
    {
        if (error.ValueKind != JsonValueKind.Object)
            return new(QuotaErrorKind.InvalidResponse, stage);

        int? code = error.TryGetProperty("code", out var codeValue) ? ReadInteger(codeValue) : null;
        var objects = new List<JsonElement> { error };
        if (error.TryGetProperty("data", out var data) && data.ValueKind == JsonValueKind.Object)
        {
            objects.Add(data);
            foreach (var key in new[] { "http", "response" })
                if (data.TryGetProperty(key, out var nested) && nested.ValueKind == JsonValueKind.Object)
                    objects.Add(nested);
        }

        int? status = null;
        string[] statusKeys = ["httpStatusCode", "httpStatus", "statusCode", "status", "http_status_code", "http_status"];
        foreach (var item in objects)
        {
            foreach (var key in statusKeys)
            {
                if (!item.TryGetProperty(key, out var raw)) continue;
                var candidate = ReadInteger(raw, allowNumericString: true);
                if (candidate is >= 400 and <= 599) { status = candidate; break; }
            }
            if (status.HasValue) break;
        }

        // A JSON-RPC internal error (-32603) alone says nothing about authentication.
        var kind = (status ?? code) switch
        {
            401 => QuotaErrorKind.Authentication,
            403 => QuotaErrorKind.Rejected,
            429 => QuotaErrorKind.RateLimited,
            408 => QuotaErrorKind.Timeout,
            502 or 503 or 504 => QuotaErrorKind.NetworkUnavailable,
            >= 400 and <= 499 => QuotaErrorKind.Rejected,
            _ => QuotaErrorKind.RpcFailure
        };
        return new(kind, stage, code);
    }

    private static int? ReadInteger(JsonElement value, bool allowNumericString = false)
    {
        if (value.ValueKind == JsonValueKind.Number && value.TryGetInt32(out int number)) return number;
        if (allowNumericString && value.ValueKind == JsonValueKind.String)
        {
            var text = value.GetString();
            if (text is { Length: 3 } && text.All(c => c is >= '0' and <= '9') &&
                int.TryParse(text, NumberStyles.None, CultureInfo.InvariantCulture, out number)) return number;
        }
        return null;
    }

    private static bool Retryable(QuotaErrorKind kind, int? code) => kind switch
    {
        QuotaErrorKind.CliUnavailable or QuotaErrorKind.Cancelled or QuotaErrorKind.InvalidResponse or
        QuotaErrorKind.Authentication or QuotaErrorKind.Rejected or QuotaErrorKind.RateLimited => false,
        QuotaErrorKind.RpcFailure => code is not (-32600 or -32601 or -32602),
        _ => true
    };

    private static string SafeStage(string stage) => stage is "init" or "account" or "quota" or "confirm" ? stage : "unknown";
    private static string StageName(string stage) => stage switch
    {
        "init" => "初始化", "account" => "账户读取", "quota" => "额度读取", "confirm" => "账户确认", _ => "额度查询"
    };

    private static string Describe(QuotaErrorKind kind, string stage, int? code) => kind switch
    {
        QuotaErrorKind.Timeout => "额度查询超时，稍后重试。",
        QuotaErrorKind.Unavailable => "暂时无法获取额度，请检查 Codex 登录和网络连接。",
        QuotaErrorKind.AccountChanged => "查询期间账户已变化，请重新刷新。",
        QuotaErrorKind.InvalidResponse => "Codex 返回的额度数据无法识别。",
        QuotaErrorKind.CliUnavailable => "未找到 Codex CLI。请安装 CLI 并加入 PATH，或在设置中选择 codex.exe。",
        QuotaErrorKind.Authentication => "Codex 登录已失效或尚未登录，请在 Codex 中重新登录后刷新。",
        QuotaErrorKind.RateLimited => "Codex 请求过于频繁，请稍后再试。",
        QuotaErrorKind.Rejected => "Codex 拒绝了请求，请检查账户权限或客户端版本。",
        QuotaErrorKind.ProcessExited => $"Codex 子进程在{StageName(stage)}时退出，请稍后重试。",
        QuotaErrorKind.RpcFailure => $"Codex {StageName(stage)}失败" +
            (code.HasValue ? $"（RPC 代码 {code.Value}）" : "（未返回错误代码）") +
            (Retryable(kind, code) ? "，请稍后重试。" : "，请检查 Codex 客户端版本或请求配置。"),
        QuotaErrorKind.LaunchFailed => "无法启动 Codex CLI，请检查所选程序是否可运行。",
        QuotaErrorKind.NetworkUnavailable => "Codex 服务暂时无法连接，请检查网络或稍后重试。",
        QuotaErrorKind.Cancelled => "额度查询已取消。",
        _ => "额度查询失败。"
    };
}

/// <summary>Reads quota through an isolated Codex app-server, without starting a model turn.</summary>
public sealed class QuotaClient(string? executableOverride = null) : IQuotaClient
{
    private const int MaximumBufferedCharacters = 1_048_576;
    private const string ClientVersion = "1.2.0";
    private static readonly UTF8Encoding Utf8 = new(false, true);

    public Task<QuotaReading> ReadAsync(CancellationToken cancellationToken) => ReadInternalAsync(cancellationToken, accountOnly: false);

    public Task<QuotaReading> ReadAccountAsync(CancellationToken cancellationToken) => ReadInternalAsync(cancellationToken, accountOnly: true);

    private async Task<QuotaReading> ReadInternalAsync(CancellationToken cancellationToken, bool accountOnly)
    {
        cancellationToken.ThrowIfCancellationRequested();
        using var deadline = new CancellationTokenSource(TimeSpan.FromSeconds(20));
        using var linked = CancellationTokenSource.CreateLinkedTokenSource(cancellationToken, deadline.Token);
        var token = linked.Token;
        using var process = new Process { StartInfo = CreateStartInfo(FindExecutable(executableOverride)) };
        string stage = "init";
        bool started = false;
        Task stderrDrain = Task.CompletedTask;
        CancellationTokenRegistration killOnCancel = default;
        try
        {
            token.ThrowIfCancellationRequested();
            try
            {
                started = process.Start();
                if (!started) throw new QuotaException(QuotaErrorKind.LaunchFailed, stage);
            }
            catch (Exception error) when (error is Win32Exception or IOException or InvalidOperationException or UnauthorizedAccessException)
            {
                throw new QuotaException(QuotaErrorKind.LaunchFailed, stage);
            }

            // Cancellation sends a synchronous kill request, including descendants, even if
            // the caller's UI is closing before the awaited read can finish its cleanup.
            killOnCancel = token.Register(() => KillTree(process));
            stderrDrain = DrainWithoutRetainingAsync(process.StandardError);
            process.StandardInput.AutoFlush = true;
            async Task SendAsync(object message)
            {
                string json = JsonSerializer.Serialize(message);
                await process.StandardInput.WriteLineAsync(json.AsMemory(), token).ConfigureAwait(false);
                await process.StandardInput.FlushAsync(token).ConfigureAwait(false);
            }

            await SendAsync(new
            {
                id = 0, method = "initialize",
                @params = new { clientInfo = new { name = "codex_pet_monitor", title = "Codex Monitor", version = ClientVersion } }
            }).ConfigureAwait(false);

            bool initialized = false;
            AccountSummary? account = null;
            byte[]? identityFingerprint = null;
            QuotaReading? pendingReading = null;
            QuotaReading? confirmedReading = null;
            int confirmationId = 3;
            string pendingText = "";
            var characters = new char[8192];
            while (true)
            {
                token.ThrowIfCancellationRequested();
                int count = await process.StandardOutput.ReadAsync(characters.AsMemory(), token).ConfigureAwait(false);
                token.ThrowIfCancellationRequested();
                if (count == 0) throw new QuotaException(QuotaErrorKind.ProcessExited, stage);
                pendingText += new string(characters, 0, count);
                if (pendingText.Length > MaximumBufferedCharacters) throw new QuotaException(QuotaErrorKind.InvalidResponse, stage);

                int newline;
                while ((newline = pendingText.IndexOf('\n')) >= 0)
                {
                    string line = pendingText[..newline].TrimEnd('\r');
                    pendingText = pendingText[(newline + 1)..];
                    if (line.Length == 0) continue;
                    using var document = JsonDocument.Parse(line, new JsonDocumentOptions { MaxDepth = 64 });
                    var message = document.RootElement;
                    if (message.ValueKind != JsonValueKind.Object) throw new QuotaException(QuotaErrorKind.InvalidResponse, stage);
                    if (GetString(message, "method") == "account/updated")
                    {
                        // Token/plan refresh notifications are not proof of an account switch.
                        // If a notification follows confirmation in the same read, confirm again.
                        if (confirmedReading is not null)
                        {
                            confirmedReading = null;
                            confirmationId++;
                            await SendAsync(new { id = confirmationId, method = "account/read", @params = new { refreshToken = false } }).ConfigureAwait(false);
                        }
                        continue;
                    }
                    if (!message.TryGetProperty("id", out var rawId) || rawId.ValueKind != JsonValueKind.Number || !rawId.TryGetInt32(out int id)) continue;

                    if (id == 0 && !initialized)
                    {
                        _ = GetResult(message, stage);
                        initialized = true;
                        await SendAsync(new { method = "initialized", @params = new { } }).ConfigureAwait(false);
                        stage = "account";
                        await SendAsync(new { id = 1, method = "account/read", @params = new { refreshToken = false } }).ConfigureAwait(false);
                    }
                    else if (id == 1 && initialized && account is null)
                    {
                        var result = GetResult(message, stage);
                        account = ParseAccount(result);
                        identityFingerprint = Fingerprint(result);
                        if (accountOnly || !account.SupportsWeeklyQuota)
                            return new(Array.Empty<WeeklyQuota>(), DateTimeOffset.UtcNow, account, StorageIdentityKey(account, identityFingerprint));
                        stage = "quota";
                        await SendAsync(new { id = 2, method = "account/rateLimits/read" }).ConfigureAwait(false);
                    }
                    else if (id == 2 && initialized && account is not null && pendingReading is null)
                    {
                        pendingReading = ParseQuota(GetResult(message, stage), account) with
                        {
                            IdentityKey = StorageIdentityKey(account, identityFingerprint!)
                        };
                        stage = "confirm";
                        await SendAsync(new { id = confirmationId, method = "account/read", @params = new { refreshToken = false } }).ConfigureAwait(false);
                    }
                    else if (id == confirmationId && pendingReading is not null)
                    {
                        var result = GetResult(message, stage);
                        var confirmed = ParseAccount(result);
                        if (confirmed != account || identityFingerprint is null ||
                            !CryptographicOperations.FixedTimeEquals(Fingerprint(result), identityFingerprint))
                            throw new QuotaException(QuotaErrorKind.AccountChanged, stage);
                        confirmedReading = pendingReading;
                    }
                }
                // This is a checked snapshot, not an atomic cross-request account transaction.
                if (confirmedReading is not null && pendingText.Length == 0) return confirmedReading;
            }
        }
        catch (OperationCanceledException)
        {
            if (cancellationToken.IsCancellationRequested) throw new OperationCanceledException(cancellationToken);
            throw new QuotaException(QuotaErrorKind.Timeout, stage);
        }
        catch (Exception error) when (error is JsonException or DecoderFallbackException)
        {
            throw new QuotaException(QuotaErrorKind.InvalidResponse, stage);
        }
        catch (IOException)
        {
            if (cancellationToken.IsCancellationRequested) throw new OperationCanceledException(cancellationToken);
            if (deadline.IsCancellationRequested) throw new QuotaException(QuotaErrorKind.Timeout, stage);
            throw new QuotaException(HasExited(process) ? QuotaErrorKind.ProcessExited : QuotaErrorKind.Unavailable, stage);
        }
        finally
        {
            killOnCancel.Dispose();
            if (started)
            {
                KillTree(process);
                try { await process.WaitForExitAsync().WaitAsync(TimeSpan.FromSeconds(2)).ConfigureAwait(false); }
                catch (Exception error) when (error is TimeoutException or InvalidOperationException or Win32Exception) { }
                try { await stderrDrain.WaitAsync(TimeSpan.FromMilliseconds(500)).ConfigureAwait(false); }
                catch (TimeoutException) { }
            }
        }
    }

    public static AccountSummary ParseAccount(JsonElement result)
    {
        if (result.ValueKind != JsonValueKind.Object || !result.TryGetProperty("account", out var account))
            throw new QuotaException(QuotaErrorKind.InvalidResponse, "account");
        if (account.ValueKind == JsonValueKind.Null) return new(null, null, "signedOut");
        string? type = GetString(account, "type");
        if (account.ValueKind != JsonValueKind.Object || string.IsNullOrEmpty(type) || type.Length > 64 ||
            !type.All(c => char.IsLetterOrDigit(c) || c is '_' or '-'))
            throw new QuotaException(QuotaErrorKind.InvalidResponse, "account");
        return new(type == "chatgpt" ? MaskEmail(GetString(account, "email")) : null,
                   type == "chatgpt" ? PlanName(GetString(account, "planType")) : null, type);
    }

    public static QuotaReading ParseQuota(JsonElement result, AccountSummary account, DateTimeOffset? receivedAt = null)
    {
        if (result.ValueKind != JsonValueKind.Object) throw new QuotaException(QuotaErrorKind.InvalidResponse);
        bool hasMulti = result.TryGetProperty("rateLimitsByLimitId", out var multi);
        bool hasSingle = result.TryGetProperty("rateLimits", out var single);
        var buckets = new List<(string Id, JsonElement Value)>();
        if (hasMulti && multi.ValueKind == JsonValueKind.Object)
        {
            foreach (var bucket in multi.EnumerateObject())
                if (bucket.Value.ValueKind == JsonValueKind.Object) buckets.Add((bucket.Name, bucket.Value));
        }
        else if (hasSingle && single.ValueKind == JsonValueKind.Object)
            buckets.Add((Nonempty(GetString(single, "limitId")) ?? "codex", single));
        else if ((!hasMulti && !hasSingle) || (hasMulti && multi.ValueKind != JsonValueKind.Null) ||
                 (hasSingle && single.ValueKind != JsonValueKind.Null))
            throw new QuotaException(QuotaErrorKind.InvalidResponse);

        var windows = new List<WeeklyQuota>();
        foreach (var bucket in buckets.OrderBy(b => b.Id == "codex" ? 0 : 1).ThenBy(b => b.Id, StringComparer.Ordinal))
        {
            string label = Nonempty(GetString(bucket.Value, "limitName")) ?? (bucket.Id == "codex" ? "Codex" : bucket.Id);
            foreach (string windowName in new[] { "primary", "secondary" })
            {
                if (!bucket.Value.TryGetProperty(windowName, out var window) || window.ValueKind != JsonValueKind.Object ||
                    Number(window, "windowDurationMins") != 10_080 || Number(window, "usedPercent") is not double used) continue;
                DateTimeOffset? resetsAt = null;
                if (Number(window, "resetsAt") is double seconds && seconds > 0 && seconds < 253_402_300_800)
                {
                    try { resetsAt = DateTimeOffset.UnixEpoch.AddSeconds(seconds); }
                    catch (ArgumentOutOfRangeException) { }
                }
                windows.Add(new($"{bucket.Id}.{windowName}", label, used, resetsAt));
            }
        }
        return new(windows.AsReadOnly(), receivedAt ?? DateTimeOffset.UtcNow, account);
    }

    private static JsonElement GetResult(JsonElement message, string stage)
    {
        if (message.TryGetProperty("error", out var error) && error.ValueKind != JsonValueKind.Null)
            throw QuotaException.FromRpcError(error, stage);
        if (!message.TryGetProperty("result", out var result) || result.ValueKind != JsonValueKind.Object)
            throw new QuotaException(QuotaErrorKind.InvalidResponse, stage);
        return result;
    }

    // Unknown email cannot identify an account across independent reads. Keep the
    // full-query confirmation digest internal, but do not use it to preserve old quota.
    private static string? StorageIdentityKey(AccountSummary account, byte[] fingerprint) =>
        account.AuthType == "chatgpt" && account.MaskedEmail is not null ? Convert.ToHexString(fingerprint) : null;

    private static byte[] Fingerprint(JsonElement result)
    {
        result.TryGetProperty("account", out var account);
        // The in-memory digest distinguishes accounts that produce the same mask.
        // Only that digest reaches QuotaReading; JsonIgnore prevents persistence/export.
        byte[] serialized = JsonSerializer.SerializeToUtf8Bytes(new
        {
            type = GetString(account, "type") ?? "signedOut",
            email = GetString(account, "email"),
            planType = GetString(account, "planType")
        });
        try { return SHA256.HashData(serialized); }
        finally { CryptographicOperations.ZeroMemory(serialized); }
    }

    private static string? GetString(JsonElement value, string key) =>
        value.ValueKind == JsonValueKind.Object && value.TryGetProperty(key, out var item) && item.ValueKind == JsonValueKind.String
            ? item.GetString() : null;

    private static double? Number(JsonElement value, string key) =>
        value.TryGetProperty(key, out var item) && item.ValueKind == JsonValueKind.Number && item.TryGetDouble(out double number) && double.IsFinite(number)
            ? number : null;

    private static string? Nonempty(string? text) => string.IsNullOrWhiteSpace(text) ? null : text;

    private static string? MaskEmail(string? raw)
    {
        if (raw is null) return null;
        string[] pieces = raw.Trim().Split('@');
        if (pieces.Length != 2) return null;
        string local = pieces[0], domain = pieces[1];
        const string localCharacters = "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789.!#$%&'*+-/=?^_`{|}~";
        const string domainCharacters = "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-.";
        string[] labels = domain.Split('.');
        if (local.Length is 0 or > 64 || domain.Length > 253 || local.StartsWith('.') || local.EndsWith('.') || local.Contains("..") ||
            !local.All(localCharacters.Contains) || !domain.All(domainCharacters.Contains) || labels.Length < 2 ||
            labels.Any(label => label.Length is 0 or > 63 || label.StartsWith('-') || label.EndsWith('-'))) return null;
        string masked = local.Length >= 4 ? local[..2] + "***" + local[^1] : local[..1] + "***";
        return masked + "@" + domain;
    }

    private static string? PlanName(string? raw)
    {
        string? plan = raw?.Trim();
        if (string.IsNullOrEmpty(plan) || plan.Length > 80 || plan.Any(char.IsControl)) return null;
        return plan.ToLowerInvariant() switch
        {
            "plus" => "Plus", "pro" => "Pro", "prolite" or "pro_lite" or "pro-lite" or "pro lite" => "Pro Lite",
            "team" => "Team", "business" => "Business", "enterprise" => "Enterprise", "free" => "Free", _ => plan
        };
    }

    private static string FindExecutable(string? supplied)
    {
        string? requested = supplied ?? Environment.GetEnvironmentVariable("CODEX_MONITOR_CLI");
        if (!string.IsNullOrWhiteSpace(requested))
        {
            string path;
            try { path = Path.GetFullPath(requested.Trim().Trim('"')); }
            catch (Exception error) when (error is ArgumentException or NotSupportedException or PathTooLongException)
            { throw new QuotaException(QuotaErrorKind.CliUnavailable); }
            if (!File.Exists(path)) throw new QuotaException(QuotaErrorKind.CliUnavailable);
            return ResolveNpmNativeExecutable(path) ?? path;
        }

        var directories = (Environment.GetEnvironmentVariable("PATH") ?? "").Split(Path.PathSeparator)
            .Select(value => value.Trim().Trim('"')).Where(value => value.Length > 0).ToArray();
        foreach (string name in OperatingSystem.IsWindows() ? new[] { "codex.exe", "codex.cmd" } : new[] { "codex" })
            foreach (string directory in directories)
            {
                try
                {
                    string path = Path.GetFullPath(Path.Combine(directory, name));
                    if (File.Exists(path)) return ResolveNpmNativeExecutable(path) ?? path;
                }
                catch (Exception error) when (error is ArgumentException or NotSupportedException or PathTooLongException) { }
            }
        // Windows Store desktop installation paths are version-dependent. Do not guess or
        // require access to WindowsApps; the UI can select the installed CLI explicitly.
        throw new QuotaException(QuotaErrorKind.CliUnavailable);
    }

    private static string? ResolveNpmNativeExecutable(string path)
    {
        if (!OperatingSystem.IsWindows() || !Path.GetExtension(path).Equals(".cmd", StringComparison.OrdinalIgnoreCase)) return null;
        string folder = Path.GetDirectoryName(path)!;
        string suffix = Path.Combine("vendor", "x86_64-pc-windows-msvc", "codex", "codex.exe");
        string[] roots =
        [
            Path.Combine(folder, "node_modules", "@openai", "codex"),
            Path.Combine(folder, "node_modules", "@openai", "codex-win32-x64"),
            Path.Combine(folder, "node_modules", "@openai", "codex", "node_modules", "@openai", "codex-win32-x64")
        ];
        return roots.Select(root => Path.Combine(root, suffix)).FirstOrDefault(File.Exists);
    }

    private static ProcessStartInfo CreateStartInfo(string executable)
    {
        var info = new ProcessStartInfo
        {
            UseShellExecute = false, CreateNoWindow = true,
            RedirectStandardInput = true, RedirectStandardOutput = true, RedirectStandardError = true,
            StandardInputEncoding = Utf8, StandardOutputEncoding = Utf8, StandardErrorEncoding = Encoding.UTF8
        };
        string home = Environment.GetFolderPath(Environment.SpecialFolder.UserProfile);
        if (Directory.Exists(home)) info.WorkingDirectory = home;
        if (OperatingSystem.IsWindows() && Path.GetExtension(executable).Equals(".cmd", StringComparison.OrdinalIgnoreCase))
        {
            // No data from the account or user input becomes shell syntax. Reject path
            // characters which cmd.exe can expand even inside quotes; use the native exe
            // discovered above when npm lives in a path containing those characters.
            if (executable.IndexOfAny(['%', '!', '"', '\r', '\n', '&', '|', '<', '>', '^', '(', ')']) >= 0)
                throw new QuotaException(QuotaErrorKind.CliUnavailable);
            info.FileName = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.System), "cmd.exe");
            info.Arguments = $"/d /v:off /s /c \"\"{executable}\" app-server --listen stdio://\"";
        }
        else
        {
            if (OperatingSystem.IsWindows() && !Path.GetExtension(executable).Equals(".exe", StringComparison.OrdinalIgnoreCase))
                throw new QuotaException(QuotaErrorKind.CliUnavailable);
            info.FileName = executable;
            info.ArgumentList.Add("app-server");
            info.ArgumentList.Add("--listen");
            info.ArgumentList.Add("stdio://");
        }
        return info;
    }

    private static async Task DrainWithoutRetainingAsync(StreamReader reader)
    {
        var buffer = new char[4096];
        try { while (await reader.ReadAsync(buffer.AsMemory()).ConfigureAwait(false) != 0) { } }
        catch (Exception error) when (error is IOException or ObjectDisposedException or InvalidOperationException) { }
        finally { Array.Clear(buffer); }
    }

    private static bool HasExited(Process process)
    {
        try { return process.HasExited; }
        catch (InvalidOperationException) { return true; }
    }

    private static void KillTree(Process process)
    {
        try { if (!process.HasExited) process.Kill(entireProcessTree: true); }
        catch (Exception error) when (error is InvalidOperationException or Win32Exception or NotSupportedException)
        {
            try { if (!process.HasExited) process.Kill(); }
            catch (Exception fallback) when (fallback is InvalidOperationException or Win32Exception or NotSupportedException) { }
        }
    }
}
