using System.IO;
using System.Text.Json;
using System.Runtime.InteropServices;
using System.Windows.Interop;

namespace CodexMonitor.Windows;

internal sealed class UserSettings
{
    public int? X { get; set; }
    public int? Y { get; set; }
    public bool Pinned { get; set; } = true;
    public string? CliPath { get; set; }
    private static string FilePath => Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "CodexMonitor", "settings.json");
    public static UserSettings Load()
    {
        try { return JsonSerializer.Deserialize<UserSettings>(File.ReadAllText(FilePath)) ?? new(); }
        catch (Exception ex) when (ex is IOException or UnauthorizedAccessException or JsonException) { return new(); }
    }
    public void Save()
    {
        try
        {
            Directory.CreateDirectory(Path.GetDirectoryName(FilePath)!);
            var temporary = FilePath + ".tmp";
            File.WriteAllText(temporary, JsonSerializer.Serialize(this));
            File.Move(temporary, FilePath, true);
        }
        catch (Exception ex) when (ex is IOException or UnauthorizedAccessException) { }
    }
}

// Persist physical-pixel positions through Win32 to avoid mixing WPF DIPs with
// monitor coordinates when restoring a window on monitors with different DPI.
internal static class WindowPlacement
{
    [StructLayout(LayoutKind.Sequential)] private struct RECT { public int Left, Top, Right, Bottom; }
    [StructLayout(LayoutKind.Sequential)] private struct MONITORINFO { public int Size; public RECT Monitor, Work; public uint Flags; }
    [DllImport("user32.dll")] [return: MarshalAs(UnmanagedType.Bool)] private static extern bool GetWindowRect(IntPtr window, out RECT rect);
    [DllImport("user32.dll")] private static extern IntPtr MonitorFromRect(ref RECT rect, uint flags);
    [DllImport("user32.dll", CharSet = CharSet.Auto)] [return: MarshalAs(UnmanagedType.Bool)] private static extern bool GetMonitorInfo(IntPtr monitor, ref MONITORINFO info);
    [DllImport("user32.dll")] [return: MarshalAs(UnmanagedType.Bool)] private static extern bool SetWindowPos(IntPtr window, IntPtr after, int x, int y, int width, int height, uint flags);

    public static void Restore(MainWindow window, UserSettings settings)
    {
        var handle = new WindowInteropHelper(window).Handle;
        if (!GetWindowRect(handle, out var current)) return;
        var width = current.Right - current.Left;
        var height = current.Bottom - current.Top;
        var saved = settings.X is { } x && settings.Y is { } y && Math.Abs((long)x) < 1000000 && Math.Abs((long)y) < 1000000;
        var target = current;
        if (saved) { target.Left = settings.X!.Value; target.Top = settings.Y!.Value; target.Right = target.Left + width; target.Bottom = target.Top + height; }
        var monitor = MonitorFromRect(ref target, 2);
        var info = new MONITORINFO { Size = Marshal.SizeOf<MONITORINFO>() };
        if (!GetMonitorInfo(monitor, ref info)) return;
        var left = saved ? target.Left : info.Work.Right - width - 24;
        var top = saved ? target.Top : info.Work.Bottom - height - 50;
        left = Math.Clamp(left, info.Work.Left, Math.Max(info.Work.Left, info.Work.Right - width));
        top = Math.Clamp(top, info.Work.Top, Math.Max(info.Work.Top, info.Work.Bottom - height));
        _ = SetWindowPos(handle, IntPtr.Zero, left, top, 0, 0, 0x0001 | 0x0004 | 0x0010);
    }
    public static void Save(MainWindow window, UserSettings settings)
    {
        if (GetWindowRect(new WindowInteropHelper(window).Handle, out var rect)) { settings.X = rect.Left; settings.Y = rect.Top; settings.Save(); }
    }
}
