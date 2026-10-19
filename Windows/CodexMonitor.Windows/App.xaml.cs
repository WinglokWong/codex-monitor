using System.IO;
using System.Text.Json;
using System.Windows;
using System.Windows.Media;
using System.Windows.Media.Imaging;
using System.Windows.Threading;
using CodexMonitor.Core;
using WpfApplication = System.Windows.Application;

namespace CodexMonitor.Windows;

public partial class App : WpfApplication
{
    private Mutex? instanceMutex;
    private EventWaitHandle? showEvent;
    private RegisteredWaitHandle? showRegistration;

    protected override async void OnStartup(StartupEventArgs args)
    {
        base.OnStartup(args);
        if (args.Args.Length == 2 && args.Args[0] == "--render-smoke")
        {
            try { await RenderSmokeAsync(args.Args[1]); Shutdown(0); }
            catch (Exception error)
            {
                File.WriteAllText(args.Args[1] + ".error.txt", error.ToString());
                Shutdown(1);
            }
            return;
        }
        if (args.Args.Length == 2 && args.Args[0] == "--system-smoke")
        {
            try { File.WriteAllText(args.Args[1], SystemMetricsSelfTests.RunNativeSmoke()); Shutdown(0); }
            catch (Exception error) { File.WriteAllText(args.Args[1], error.Message); Shutdown(1); }
            return;
        }
        instanceMutex = new Mutex(true, @"Local\CodexMonitor.Windows.Instance", out var created);
        showEvent = new EventWaitHandle(false, EventResetMode.AutoReset, @"Local\CodexMonitor.Windows.Show");
        if (!created) { showEvent.Set(); Shutdown(); return; }
        var window = new MainWindow();
        MainWindow = window;
        showRegistration = ThreadPool.RegisterWaitForSingleObject(showEvent, (_, _) => Dispatcher.BeginInvoke(window.ShowPanel), null, Timeout.Infinite, false);
        window.Show();
    }

    protected override void OnExit(ExitEventArgs args)
    {
        showRegistration?.Unregister(null);
        showEvent?.Dispose();
        instanceMutex?.Dispose();
        base.OnExit(args);
    }

    private async Task RenderSmokeAsync(string outputPath)
    {
        // Synthetic data only. This path never starts Codex, touches credentials,
        // creates a tray icon, or loads/saves the user's window preferences.
        var vm = new MonitorViewModel(new PreviewQuotaClient());
        await vm.State.RefreshAsync();
        vm.SetSystem(new SystemSnapshot(DateTimeOffset.UtcNow, 18, 6UL * 1073741824, 16UL * 1073741824,
            1.25 * 1048576, 128 * 1024, ["示例 Wi-Fi"], null));
        var window = new MainWindow(vm, preview: true) { ShowInTaskbar = false, Topmost = false };
        window.Show();
        await Dispatcher.InvokeAsync(() => { }, DispatcherPriority.ApplicationIdle);
        window.UpdateLayout();
        if (window.ActualWidth < 300 || window.ActualHeight < 400 || !window.IsVisible)
            throw new InvalidOperationException("Window layout failed smoke checks.");
        window.Hide();
        window.Show();
        if (!window.IsVisible) throw new InvalidOperationException("Window did not restore after hiding.");
        window.Topmost = true;
        window.Topmost = false;
        var visual = (FrameworkElement)window.Content;
        visual.UpdateLayout();
        var bitmap = new RenderTargetBitmap((int)Math.Ceiling(visual.ActualWidth * 2), (int)Math.Ceiling(visual.ActualHeight * 2), 192, 192, PixelFormats.Pbgra32);
        bitmap.Render(visual);
        var encoder = new PngBitmapEncoder();
        encoder.Frames.Add(BitmapFrame.Create(bitmap));
        Directory.CreateDirectory(Path.GetDirectoryName(Path.GetFullPath(outputPath))!);
        using (var file = File.Create(outputPath)) encoder.Save(file);
        bool intervalDialogPassed = false;
        Exception? intervalDialogError = null;
        var dialog = new QueryIntervalDialog(2, 7) { Owner = window };
        dialog.ContentRendered += (_, _) => dialog.Dispatcher.BeginInvoke(new Action(() =>
        {
            try
            {
                var content = (FrameworkElement)dialog.Content;
                content.UpdateLayout();
                var picture = new RenderTargetBitmap((int)Math.Ceiling(content.ActualWidth * 2), (int)Math.Ceiling(content.ActualHeight * 2), 192, 192, PixelFormats.Pbgra32);
                picture.Render(content);
                var png = new PngBitmapEncoder();
                png.Frames.Add(BitmapFrame.Create(picture));
                using (var image = File.Create(Path.Combine(Path.GetDirectoryName(Path.GetFullPath(outputPath))!, "ui-intervals.png"))) png.Save(image);
                intervalDialogPassed = dialog.ExerciseValidationForSmoke();
                if (!intervalDialogPassed) dialog.Close();
            }
            catch (Exception error) { intervalDialogError = error; dialog.Close(); }
        }));
        if (dialog.ShowDialog() != true || !intervalDialogPassed || intervalDialogError is not null)
            throw new InvalidOperationException("Query interval dialog failed validation/save checks.", intervalDialogError);
        var persisted = UserSettings.FromJson(JsonSerializer.Serialize(new UserSettings { AccountQueryIntervalMinutes = 2, QuotaQueryIntervalMinutes = 7 }));
        if (persisted.AccountQueryIntervalMinutes != 2 || persisted.QuotaQueryIntervalMinutes != 7)
            throw new InvalidOperationException("Query interval preference round-trip failed.");
        var migrated = UserSettings.FromJson("{\"Pinned\":false,\"AccountQueryIntervalMinutes\":0,\"QuotaQueryIntervalMinutes\":10081}");
        if (migrated.Pinned || migrated.AccountQueryIntervalMinutes != 1 || migrated.QuotaQueryIntervalMinutes != 1)
            throw new InvalidOperationException("Invalid query interval preference fallback failed.");
        File.WriteAllText(outputPath + ".json", JsonSerializer.Serialize(new { width = window.ActualWidth, height = window.ActualHeight, shown = true, restored = true, syntheticData = true, intervalDialog = intervalDialogPassed, intervalPreferences = true }));
        vm.State.Stop();
        window.Close();
    }

    private sealed class PreviewQuotaClient : IQuotaClient
    {
        public async Task<QuotaReading> ReadAccountAsync(CancellationToken cancellationToken)
        {
            var reading = await ReadAsync(cancellationToken);
            return reading with { Windows = Array.Empty<WeeklyQuota>() };
        }
        public Task<QuotaReading> ReadAsync(CancellationToken cancellationToken)
        {
            var now = DateTimeOffset.UtcNow;
            return Task.FromResult(new QuotaReading([new WeeklyQuota("codex.primary", "Codex", 24, now.AddDays(5))], now,
                new AccountSummary("de***o@example.test", "Plus", "chatgpt")));
        }
    }
}
