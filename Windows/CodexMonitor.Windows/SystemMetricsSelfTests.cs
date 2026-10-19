using System;
using System.Collections.Generic;
using System.Globalization;
using System.Threading;

namespace CodexMonitor.Windows;

public static class SystemMetricsSelfTests
{
    public static void Run()
    {
        SystemMetricNative.ValidateLayout();

        var initialCpu = new CpuCounter(850, 900, 100);
        var nextCpu = new CpuCounter(920, 980, 120);
        Require(SystemMetricMath.CpuPercentage(initialCpu, nextCpu, 1) == 30,
            "CPU must subtract idle already included in kernel, not count it twice.");
        Require(SystemMetricMath.CpuPercentage(initialCpu, initialCpu, 1) is null,
            "Unchanged counters must not fabricate zero CPU.");
        Require(SystemMetricMath.CpuPercentage(initialCpu, new CpuCounter(1, 2, 3), 1) is null,
            "CPU counter reset must establish a new baseline.");
        Require(SystemMetricMath.CpuPercentage(initialCpu, nextCpu, 11) is null,
            "A long suspend gap must not become a current CPU estimate.");
        Require(SystemMetricMath.CpuPercentage(initialCpu with { Group = 0 }, nextCpu with { Group = 1 }, 1) is null,
            "Processor groups cannot share a CPU baseline.");
        Require(SystemMetricMath.CpuPercentage(new CpuCounter(0, 0, 0), new CpuCounter(200, 10, 10), 1) is null,
            "Inconsistent idle totals must not produce negative CPU.");

        var guid = Guid.Parse("10000000-0000-0000-0000-000000000001");
        NetworkCounter Counter(ulong received, ulong sent, uint index = 1) => new(index, guid, "test-adapter", received, sent);
        var previous = new Dictionary<ulong, NetworkCounter>
        {
            [1] = Counter(5_000_000_000, 9_000_000_000),
            [2] = Counter(100, 200, 2)
        };
        var current = new Dictionary<ulong, NetworkCounter>
        {
            [1] = Counter(5_000_001_000, 9_000_002_000),
            [2] = Counter(600, 1200, 2)
        };
        var rates = SystemMetricMath.NetworkRates(previous, current, 2);
        Require(rates is { Download: 750, Upload: 1500 }, "Use full 64-bit counts, both adapters, and actual elapsed time.");
        Require(SystemMetricMath.NetworkRates(previous, new Dictionary<ulong, NetworkCounter> { [1] = current[1] }, 1) is null,
            "Removing an interface must establish a new baseline.");
        Require(SystemMetricMath.NetworkRates(previous,
            new Dictionary<ulong, NetworkCounter> { [1] = current[1], [3] = current[2] }, 1) is null,
            "Replacing a LUID with the same adapter count must reset rates.");

        var oneBefore = new Dictionary<ulong, NetworkCounter> { [1] = Counter(100, 200) };
        Require(SystemMetricMath.NetworkRates(oneBefore,
            new Dictionary<ulong, NetworkCounter> { [1] = Counter(1, 2) }, 1) is null,
            "A byte-counter reset must not create an underflow spike.");
        Require(SystemMetricMath.NetworkRates(oneBefore,
            new Dictionary<ulong, NetworkCounter> { [1] = Counter(200, 300, 2) }, 1) is null,
            "Disable/re-enable with a changed interface index needs a fresh baseline.");
        Require(SystemMetricMath.NetworkRates(oneBefore,
            new Dictionary<ulong, NetworkCounter> { [1] = Counter(200, 300) with { Guid = Guid.Empty } }, 1) is null,
            "A replacement interface with a different GUID needs a fresh baseline.");
        Require(SystemMetricMath.NetworkRates(previous, current, 30) is null &&
            SystemMetricMath.NetworkRates(previous, current, 0) is null &&
            SystemMetricMath.NetworkRates(previous, current, double.NaN) is null,
            "Invalid and long intervals must not produce network rates.");
        Require(SystemMetricMath.NetworkRates(new Dictionary<ulong, NetworkCounter>(), new Dictionary<ulong, NetworkCounter>(), 1) is null,
            "No physical interface must display unavailable, not measured zero.");
        const ulong large = 1UL << 54;
        var precise = SystemMetricMath.NetworkRates(
            new Dictionary<ulong, NetworkCounter> { [1] = Counter(large, large) },
            new Dictionary<ulong, NetworkCounter> { [1] = Counter(large + 1, large + 2) }, 1);
        Require(precise is { Download: 1, Upload: 2 }, "Subtract integer counters before converting to double.");

        Require(SystemMetricMath.IsPhysicalNetwork(6, 0, 0x05, 1, 1, 2), "Connected hardware Ethernet must be included.");
        Require(SystemMetricMath.IsPhysicalNetwork(71, 0, 0x01, 1, 1, 2), "Hardware Wi-Fi need not advertise a physical connector.");
        Require(!SystemMetricMath.IsPhysicalNetwork(6, 0, 0x04, 1, 1, 2), "Virtual Ethernet must not pass without the hardware flag.");
        Require(!SystemMetricMath.IsPhysicalNetwork(6, 0, 0x07, 1, 1, 2), "Filter interfaces must not duplicate hardware traffic.");
        Require(!SystemMetricMath.IsPhysicalNetwork(131, 14, 0x05, 1, 1, 3), "VPN/tunnel interfaces must be excluded.");
        Require(!SystemMetricMath.IsPhysicalNetwork(6, 1, 0x05, 1, 1, 2), "An Ethernet-shaped tunnel must also be excluded.");
        Require(!SystemMetricMath.IsPhysicalNetwork(24, 0, 0x05, 1, 1, 1), "Loopback must not count twice.");
        Require(!SystemMetricMath.IsPhysicalNetwork(71, 0, 0x15, 1, 1, 2), "Disconnected hardware flags must suppress stale interfaces.");
        Require(!SystemMetricMath.IsPhysicalNetwork(6, 0, 0x05, 2, 1, 2) &&
            !SystemMetricMath.IsPhysicalNetwork(6, 0, 0x05, 1, 2, 2), "Down or media-disconnected interfaces must be excluded.");
    }

    /// <summary>Windows-only integration smoke; virtual CI may have no eligible physical NIC.</summary>
    public static string RunNativeSmoke()
    {
        if (!OperatingSystem.IsWindows()) throw new PlatformNotSupportedException("Native metric smoke requires Windows.");
        Run();
        var sampler = new SystemSampler();
        var first = sampler.Sample();
        Require(first.CpuPercent is null && first.DownloadBytesPerSecond is null && first.UploadBytesPerSecond is null,
            "The first sample must only establish CPU/network baselines.");
        Thread.Sleep(1100);
        var sample = sampler.Sample();
        Require(sample.CpuPercent is >= 0 and <= 100, "Native CPU sampling failed: " + (sample.Error ?? "no interval counters"));
        Require(sample.MemoryTotalBytes > 0 && sample.MemoryUsedBytes is { } used && used <= sample.MemoryTotalBytes,
            "Native physical-memory sampling failed: " + (sample.Error ?? "invalid memory totals"));
        // Do not require an adapter or positive traffic: hosted Windows runners
        // can expose only virtual NICs, and idle real connections have zero rates.
        if (sample.DownloadBytesPerSecond is { } down) Require(double.IsFinite(down) && down >= 0, "Invalid native download rate.");
        if (sample.UploadBytesPerSecond is { } up) Require(double.IsFinite(up) && up >= 0, "Invalid native upload rate.");
        return string.Format(CultureInfo.InvariantCulture,
            "Native metrics OK: CPU={0:F1}% ({1}), memory={2}/{3} bytes, physicalAdapters={4}, networkStatus={5}",
            sample.CpuPercent, sample.CpuScope, sample.MemoryUsedBytes, sample.MemoryTotalBytes,
            sample.Interfaces.Count, sample.Error is null ? "OK" : "optional read unavailable");
    }

    private static void Require(bool condition, string message)
    {
        if (!condition) throw new InvalidOperationException("System metrics test: " + message);
    }
}
