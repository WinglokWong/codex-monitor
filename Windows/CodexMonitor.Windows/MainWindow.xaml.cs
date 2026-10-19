using System.ComponentModel;
using System.IO;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Input;
using System.Windows.Threading;
using CodexMonitor.Core;
using Forms = System.Windows.Forms;
using WpfApplication = System.Windows.Application;

namespace CodexMonitor.Windows;

public partial class MainWindow : Window
{
    public MonitorViewModel ViewModel { get; }
    private readonly bool preview;
    private readonly UserSettings settings;
    private readonly SystemSampler sampler = new();
    private readonly DispatcherTimer timer = new() { Interval = TimeSpan.FromSeconds(1) };
    private Forms.NotifyIcon? tray;
    private System.Drawing.Icon? trayIcon;
    private bool exiting;

    public MainWindow(MonitorViewModel? model = null, bool preview = false)
    {
        this.preview = preview;
        settings = preview ? new UserSettings() : UserSettings.Load();
        ViewModel = model ?? new MonitorViewModel(new QuotaClient(settings.CliPath), settings.AccountQueryIntervalMinutes, settings.QuotaQueryIntervalMinutes);
        InitializeComponent();
        DataContext = ViewModel;
        Topmost = settings.Pinned;
        Loaded += LoadedWindow;
        Closing += ClosingWindow;
        Closed += (_, _) => { timer.Stop(); ViewModel.State.Stop(); tray?.Dispose(); trayIcon?.Dispose(); };
        PreviewKeyDown += (_, args) =>
        {
            if (args.Key == Key.R && Keyboard.Modifiers.HasFlag(ModifierKeys.Control)) { _ = ViewModel.State.RefreshAsync(); args.Handled = true; }
        };
        timer.Tick += async (_, _) =>
        {
            ViewModel.SetSystem(sampler.Sample());
            await ViewModel.State.TickAsync(DateTimeOffset.UtcNow);
        };
    }

    private async void LoadedWindow(object sender, RoutedEventArgs args)
    {
        if (preview) return;
        WindowPlacement.Restore(this, settings);
        BuildTray();
        ViewModel.SetSystem(sampler.Sample());
        timer.Start();
        await ViewModel.State.RefreshAsync();
    }

    private void BuildTray()
    {
        using var iconStream = WpfApplication.GetResourceStream(new Uri("pack://application:,,,/Assets/AppIcon.ico"))!.Stream;
        trayIcon = new System.Drawing.Icon(iconStream);
        tray = new Forms.NotifyIcon { Icon = trayIcon, Text = "Codex Monitor", Visible = true };
        tray.DoubleClick += (_, _) => Dispatcher.Invoke(ShowPanel);
        var menu = new Forms.ContextMenuStrip();
        menu.Items.Add("显示面板", null, (_, _) => Dispatcher.Invoke(ShowPanel));
        menu.Items.Add("刷新账号与额度", null, (_, _) => Dispatcher.Invoke(() => { _ = ViewModel.State.RefreshAsync(); }));
        menu.Items.Add("保持置顶", null, (_, _) => Dispatcher.Invoke(TogglePinned));
        menu.Items.Add(new Forms.ToolStripSeparator());
        menu.Items.Add("选择 Codex CLI…", null, (_, _) => Dispatcher.Invoke(ChooseCli));
        menu.Items.Add("查询间隔…", null, (_, _) => Dispatcher.Invoke(ConfigureQueryIntervals));
        menu.Items.Add("上次查询错误", null, (_, _) => Dispatcher.Invoke(ShowError));
        menu.Items.Add(new Forms.ToolStripSeparator());
        menu.Items.Add("退出监控", null, (_, _) => Dispatcher.Invoke(Quit));
        menu.Opening += (_, _) => { if (menu.Items[2] is Forms.ToolStripMenuItem item) item.Checked = Topmost; };
        tray.ContextMenuStrip = menu;
    }

    public void ShowPanel()
    {
        ShowInTaskbar = true;
        Show();
        WindowState = WindowState.Normal;
        WindowPlacement.Restore(this, settings);
        Activate();
    }

    private void HidePanel()
    {
        if (!preview) WindowPlacement.Save(this, settings);
        Hide();
        ShowInTaskbar = false;
    }
    private void ClosingWindow(object? sender, CancelEventArgs args)
    {
        if (preview || exiting) return;
        args.Cancel = true;
        HidePanel();
    }
    public void Quit()
    {
        exiting = true;
        if (!preview) WindowPlacement.Save(this, settings);
        timer.Stop();
        ViewModel.State.Stop();
        tray?.Dispose();
        Close();
        WpfApplication.Current.Shutdown();
    }
    private void DragHeader(object sender, MouseButtonEventArgs args)
    {
        if (args.OriginalSource is DependencyObject source)
        {
            for (var current = source; current is not null; current = System.Windows.Media.VisualTreeHelper.GetParent(current))
                if (current is System.Windows.Controls.Button) return;
        }
        if (args.ChangedButton == MouseButton.Left) { DragMove(); if (!preview) WindowPlacement.Save(this, settings); }
    }
    private async void RefreshClicked(object sender, RoutedEventArgs args) => await ViewModel.State.RefreshAsync();
    private void ErrorClicked(object sender, RoutedEventArgs args) => ShowError();
    private void ShowError() => System.Windows.MessageBox.Show(this, ViewModel.ErrorDetails, "查询错误详情", MessageBoxButton.OK, MessageBoxImage.Information);
    private void TogglePinned() { Topmost = !Topmost; settings.Pinned = Topmost; if (!preview) settings.Save(); }

    private void MenuClicked(object sender, RoutedEventArgs args)
    {
        var menu = new System.Windows.Controls.ContextMenu();
        Add("查询间隔…", ConfigureQueryIntervals);
        menu.Items.Add(new Separator());
        Add("显示/隐藏置顶", TogglePinned, true, Topmost);
        Add("隐藏面板", HidePanel);
        Add("选择 Codex CLI…", ChooseCli);
        Add("恢复自动查找 CLI", () => SetCli(null));
        Add("上次查询错误", ShowError);
        menu.Items.Add(new Separator());
        Add("退出监控", Quit);
        menu.PlacementTarget = (UIElement)sender;
        menu.IsOpen = true;
        void Add(string label, Action action, bool checkable = false, bool check = false)
        {
            var item = new System.Windows.Controls.MenuItem { Header = label, IsCheckable = checkable, IsChecked = check };
            item.Click += (_, _) => action();
            menu.Items.Add(item);
        }
    }
    private void ChooseCli()
    {
        var dialog = new Microsoft.Win32.OpenFileDialog { Title = "选择已安装的 Codex CLI", Filter = "Codex CLI|*.exe;*.cmd|所有文件|*.*", CheckFileExists = true };
        if (dialog.ShowDialog(this) == true) SetCli(dialog.FileName);
    }
    private void ConfigureQueryIntervals()
    {
        var dialog = new QueryIntervalDialog(ViewModel.State.AccountIntervalMinutes, ViewModel.State.QuotaIntervalMinutes)
        { Owner = this, Topmost = Topmost };
        if (dialog.ShowDialog() != true || !ViewModel.State.SetQueryIntervals(dialog.AccountMinutes, dialog.QuotaMinutes)) return;
        settings.AccountQueryIntervalMinutes = dialog.AccountMinutes;
        settings.QuotaQueryIntervalMinutes = dialog.QuotaMinutes;
        if (!preview) settings.Save();
    }
    private void SetCli(string? path)
    {
        settings.CliPath = path;
        if (!preview) settings.Save();
        ViewModel.ReplaceClient(new QuotaClient(path));
        _ = ViewModel.State.RefreshAsync();
    }
}
