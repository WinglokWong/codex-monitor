using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.Linq;
using System.Runtime.InteropServices;

namespace CodexMonitor.Windows;

public sealed record SystemSnapshot(
    DateTimeOffset SampledAt,
    double? CpuPercent,
    ulong? MemoryUsedBytes,
    ulong MemoryTotalBytes,
    double? DownloadBytesPerSecond,
    double? UploadBytesPerSecond,
    IReadOnlyList<string> Interfaces,
    string? Error,
    string CpuScope = "全系统");

/// <summary>Keep one instance; call serially about once a second.</summary>
public sealed class SystemSampler
{
    private (long Time, CpuCounter Value)? _previousCpu;
    private (long Time, Dictionary<ulong, NetworkCounter> Values)? _previousNetwork;
    private ulong _lastTotalMemory;
    private string _cpuScope = "全系统";

    public SystemSnapshot Sample()
    {
        if (!OperatingSystem.IsWindows() || !Environment.Is64BitProcess)
        {
            _previousCpu = null;
            _previousNetwork = null;
            return new SystemSnapshot(DateTimeOffset.UtcNow, null, null, 0, null, null,
                Array.Empty<string>(), "系统采样需要 64 位 Windows", "不可用");
        }

        var errors = new List<string>();
        double? cpu = null;
        ulong? memoryUsed = null;
        double? download = null;
        double? upload = null;
        IReadOnlyList<string> names = Array.Empty<string>();

        try
        {
            var value = SystemMetricNative.ReadCpu();
            long time = Stopwatch.GetTimestamp();
            _cpuScope = value.Group < 0 ? "全系统" : "当前处理器组";
            if (_previousCpu is { } previous)
            {
                double elapsed = Stopwatch.GetElapsedTime(previous.Time, time).TotalSeconds;
                cpu = SystemMetricMath.CpuPercentage(previous.Value, value, elapsed);
            }
            _previousCpu = (time, value);
        }
        catch (Exception error) when (IsReadError(error))
        {
            _previousCpu = null;
            errors.Add(SafeError(error, "CPU"));
        }

        try
        {
            var memory = SystemMetricNative.ReadMemory();
            _lastTotalMemory = memory.Total;
            memoryUsed = memory.Used;
        }
        catch (Exception error) when (IsReadError(error))
        {
            errors.Add(SafeError(error, "内存"));
        }

        try
        {
            var counters = SystemMetricNative.ReadPhysicalNetwork();
            long time = Stopwatch.GetTimestamp();
            names = counters.Values.Select(counter => counter.Name)
                .Distinct(StringComparer.Ordinal).OrderBy(name => name, StringComparer.Ordinal).ToArray();
            if (_previousNetwork is { } previous)
            {
                double elapsed = Stopwatch.GetElapsedTime(previous.Time, time).TotalSeconds;
                var rates = SystemMetricMath.NetworkRates(previous.Values, counters, elapsed);
                if (rates is { } rate)
                {
                    download = rate.Download;
                    upload = rate.Upload;
                }
            }
            _previousNetwork = (time, counters);
        }
        catch (Exception error) when (IsReadError(error))
        {
            _previousNetwork = null;
            errors.Add(SafeError(error, "网络"));
        }

        return new SystemSnapshot(DateTimeOffset.UtcNow, cpu, memoryUsed, _lastTotalMemory,
            download, upload, names, errors.Count == 0 ? null : string.Join("；", errors), _cpuScope);
    }

    private static bool IsReadError(Exception error) => error is SystemMetricReadException
        or DllNotFoundException or EntryPointNotFoundException or BadImageFormatException;

    private static string SafeError(Exception error, string metric) =>
        error is SystemMetricReadException ? error.Message : $"{metric}系统接口暂不可用";
}

internal readonly record struct CpuCounter(ulong Idle, ulong Kernel, ulong User, int Group = -1);
internal readonly record struct NetworkCounter(uint Index, Guid Guid, string Name, ulong Received, ulong Sent);
internal readonly record struct NetworkRate(double Download, double Upload);

internal static class SystemMetricMath
{
    internal static bool ValidInterval(double seconds) => double.IsFinite(seconds) && seconds > 0 && seconds <= 10;

    internal static double? CpuPercentage(CpuCounter previous, CpuCounter current, double elapsed)
    {
        if (!ValidInterval(elapsed) || previous.Group != current.Group ||
            current.Idle < previous.Idle || current.Kernel < previous.Kernel || current.User < previous.User)
            return null;

        // GetSystemTimes includes idle time inside kernel time. Do not add idle
        // again to the denominator, and do not multiply by the processor count.
        double idle = current.Idle - previous.Idle;
        double total = (double)(current.Kernel - previous.Kernel) + (current.User - previous.User);
        if (total <= 0 || idle > total) return null;
        return Math.Clamp(100 * (total - idle) / total, 0, 100);
    }

    internal static NetworkRate? NetworkRates(IReadOnlyDictionary<ulong, NetworkCounter> previous,
        IReadOnlyDictionary<ulong, NetworkCounter> current, double elapsed)
    {
        if (!ValidInterval(elapsed) || current.Count == 0 || previous.Count != current.Count) return null;
        double received = 0;
        double sent = 0;
        foreach (var pair in current)
        {
            var value = pair.Value;
            if (!previous.TryGetValue(pair.Key, out var old) || value.Index != old.Index || value.Guid != old.Guid ||
                value.Received < old.Received || value.Sent < old.Sent)
                return null;
            // Subtract as UInt64 before converting to double, retaining small
            // deltas even when an adapter has transferred more than 2^53 bytes.
            received += value.Received - old.Received;
            sent += value.Sent - old.Sent;
        }
        return new NetworkRate(received / elapsed, sent / elapsed);
    }

    internal static bool IsPhysicalNetwork(uint type, uint tunnelType, byte flags,
        uint operStatus, uint mediaConnectState, uint accessType)
    {
        const byte hardware = 0x01;
        const byte excluded = 0x02 | 0x08 | 0x10 | 0x20 | 0x40 | 0x80;
        // Ethernet (6) or Wi-Fi (71), real hardware, up and not disconnected.
        // Filter/endpoint devices, tunnels, loopback and inactive links are not
        // counted. ConnectorPresent is informational: some NIC drivers omit it.
        // Names are deliberately not used as heuristics for VPN/virtual devices.
        return (type == 6 || type == 71) && tunnelType == 0 &&
            (flags & hardware) != 0 && (flags & excluded) == 0 &&
            operStatus == 1 && mediaConnectState != 2 && accessType != 1;
    }
}

internal sealed class SystemMetricReadException(string message) : Exception(message) { }

internal static unsafe class SystemMetricNative
{
    private const ushort AllProcessorGroups = 0xffff;
    private static readonly int RowSize = Marshal.SizeOf<MibIfRow2>();
    private static readonly int TableRowOffset = checked((int)Marshal.OffsetOf<MibIfTable2Layout>(nameof(MibIfTable2Layout.FirstRow)));

    internal static CpuCounter ReadCpu()
    {
        uint processors = GetActiveProcessorCount(AllProcessorGroups);
        if (processors == 0) throw LastError("CPU 拓扑读取失败");
        int group = processors > 64 ? ReadPrimaryProcessorGroup() : -1;
        if (!GetSystemTimes(out var idle, out var kernel, out var user))
            throw LastError("CPU 读取失败");
        if (group >= 0 && group != ReadPrimaryProcessorGroup())
            throw new SystemMetricReadException("CPU 处理器组已变化，等待重新采样");
        // On >64 logical CPU systems this API reports the calling thread's
        // primary group, including on Windows 11. The snapshot labels that scope.
        return new CpuCounter(idle.Value, kernel.Value, user.Value, group);
    }

    private static ushort ReadPrimaryProcessorGroup()
    {
        if (!GetThreadGroupAffinity(GetCurrentThread(), out var affinity))
            throw LastError("CPU 处理器组读取失败");
        return affinity.Group;
    }

    internal static (ulong Used, ulong Total) ReadMemory()
    {
        var state = new MemoryStatusEx { Length = (uint)Marshal.SizeOf<MemoryStatusEx>() };
        if (!GlobalMemoryStatusEx(ref state)) throw LastError("内存读取失败");
        if (state.TotalPhysical == 0 || state.AvailablePhysical > state.TotalPhysical)
            throw new SystemMetricReadException("内存统计暂不可用");
        // AvailablePhysical includes standby, free and zero-page lists. Subtract
        // it from OS-usable physical RAM; this is not commit/page-file usage.
        // Compression already occupies physical RAM and must not be added again.
        return (state.TotalPhysical - state.AvailablePhysical, state.TotalPhysical);
    }

    internal static Dictionary<ulong, NetworkCounter> ReadPhysicalNetwork()
    {
        ValidateLayout();
        nint table = 0;
        try
        {
            uint result = GetIfTable2(out table);
            if (result != 0) throw new SystemMetricReadException($"网络读取失败（Win32 {result}）");
            if (table == 0) throw new SystemMetricReadException("网卡统计表暂不可用");
            uint count = *(uint*)table;
            if (count > 65_536) throw new SystemMetricReadException("网卡统计表长度无效");
            var values = new Dictionary<ulong, NetworkCounter>();
            byte* first = (byte*)table + TableRowOffset;
            for (uint index = 0; index < count; index++)
            {
                // The SDK table has alignment padding after its four-byte count;
                // never assume the first row starts at table+4.
                var row = (MibIfRow2*)(first + checked((int)index * RowSize));
                if (!SystemMetricMath.IsPhysicalNetwork(row->Type, row->TunnelType, row->StatusFlags,
                    row->OperStatus, row->MediaConnectState, row->AccessType)) continue;
                string name = ReadString(row->Alias, 257);
                if (string.IsNullOrWhiteSpace(name)) name = ReadString(row->Description, 257);
                if (string.IsNullOrWhiteSpace(name)) name = $"网卡 {row->InterfaceIndex}";
                // LUID deduplicates interfaces independent of IPv4/IPv6 bindings.
                // Index and GUID are checked again when calculating deltas so a
                // disabled/recreated/replaced interface needs a fresh baseline.
                values.TryAdd(row->InterfaceLuid,
                    new NetworkCounter(row->InterfaceIndex, row->InterfaceGuid, name, row->InOctets, row->OutOctets));
            }
            return values;
        }
        finally
        {
            if (table != 0) FreeMibTable(table);
        }
    }

    private static string ReadString(char* characters, int capacity)
    {
        int length = 0;
        while (length < capacity && characters[length] != '\0') length++;
        return new string(characters, 0, length);
    }

    private static SystemMetricReadException LastError(string description) =>
        new($"{description}（Win32 {Marshal.GetLastWin32Error()}）");

    internal static void ValidateLayout()
    {
        // The release targets x64. These assertions protect unsafe table reads
        // against accidental changes to the Windows SDK ABI declarations below.
        if (IntPtr.Size != 8 || RowSize != 1352 || sizeof(MibIfRow2) != RowSize || TableRowOffset != 8 ||
            Marshal.OffsetOf<MibIfRow2>(nameof(MibIfRow2.StatusFlags)).ToInt32() != 1152 ||
            Marshal.OffsetOf<MibIfRow2>(nameof(MibIfRow2.InOctets)).ToInt32() != 1208 ||
            Marshal.OffsetOf<MibIfRow2>(nameof(MibIfRow2.OutOctets)).ToInt32() != 1280 ||
            Marshal.SizeOf<MemoryStatusEx>() != 64 || Marshal.SizeOf<GroupAffinity>() != 16)
            throw new SystemMetricReadException("Windows 64 位系统统计结构不匹配");
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct NativeFileTime
    {
        public uint Low;
        public uint High;
        public readonly ulong Value => ((ulong)High << 32) | Low;
    }

    [StructLayout(LayoutKind.Sequential, Pack = 8)]
    private struct GroupAffinity
    {
        public nuint Mask;
        public ushort Group;
        public ushort Reserved0;
        public ushort Reserved1;
        public ushort Reserved2;
    }

    [StructLayout(LayoutKind.Sequential, Pack = 8)]
    private struct MemoryStatusEx
    {
        public uint Length;
        public uint MemoryLoad;
        public ulong TotalPhysical;
        public ulong AvailablePhysical;
        public ulong TotalPageFile;
        public ulong AvailablePageFile;
        public ulong TotalVirtual;
        public ulong AvailableVirtual;
        public ulong AvailableExtendedVirtual;
    }

    // https://learn.microsoft.com/windows/win32/api/netioapi/ns-netioapi-mib_if_row2
    // Windows WCHAR is always two bytes; C# fixed char buffers match it exactly.
    // Native BOOLEAN bitfields below occupy ONE byte, not a marshaled Win32 BOOL.
    [StructLayout(LayoutKind.Sequential, Pack = 8, CharSet = CharSet.Unicode)]
    private struct MibIfRow2
    {
        public ulong InterfaceLuid;
        public uint InterfaceIndex;
        public Guid InterfaceGuid;
        public fixed char Alias[257];
        public fixed char Description[257];
        public uint PhysicalAddressLength;
        public fixed byte PhysicalAddress[32];
        public fixed byte PermanentPhysicalAddress[32];
        public uint Mtu;
        public uint Type;
        public uint TunnelType;
        public uint MediaType;
        public uint PhysicalMediumType;
        public uint AccessType;
        public uint DirectionType;
        public byte StatusFlags;
        public uint OperStatus;
        public uint AdminStatus;
        public uint MediaConnectState;
        public Guid NetworkGuid;
        public uint ConnectionType;
        public ulong TransmitLinkSpeed;
        public ulong ReceiveLinkSpeed;
        public ulong InOctets;
        public ulong InUcastPkts;
        public ulong InNUcastPkts;
        public ulong InDiscards;
        public ulong InErrors;
        public ulong InUnknownProtos;
        public ulong InUcastOctets;
        public ulong InMulticastOctets;
        public ulong InBroadcastOctets;
        public ulong OutOctets;
        public ulong OutUcastPkts;
        public ulong OutNUcastPkts;
        public ulong OutDiscards;
        public ulong OutErrors;
        public ulong OutUcastOctets;
        public ulong OutMulticastOctets;
        public ulong OutBroadcastOctets;
        public ulong OutQLen;
    }

    [StructLayout(LayoutKind.Sequential, Pack = 8)]
    private struct MibIfTable2Layout
    {
        public uint NumEntries;
        public MibIfRow2 FirstRow;
    }

    [DllImport("kernel32.dll", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool GetSystemTimes(out NativeFileTime idle, out NativeFileTime kernel, out NativeFileTime user);

    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern uint GetActiveProcessorCount(ushort groupNumber);

    [DllImport("kernel32.dll")]
    private static extern nint GetCurrentThread();

    [DllImport("kernel32.dll", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool GetThreadGroupAffinity(nint thread, out GroupAffinity groupAffinity);

    [DllImport("kernel32.dll", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool GlobalMemoryStatusEx(ref MemoryStatusEx status);

    [DllImport("iphlpapi.dll", ExactSpelling = true)]
    private static extern uint GetIfTable2(out nint table);

    [DllImport("iphlpapi.dll", ExactSpelling = true)]
    private static extern void FreeMibTable(nint memory);
}
