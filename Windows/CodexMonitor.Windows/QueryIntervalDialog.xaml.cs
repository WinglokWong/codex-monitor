using System.Globalization;
using System.Windows;
using System.Windows.Controls;

namespace CodexMonitor.Windows;

public partial class QueryIntervalDialog : Window
{
    public int AccountMinutes { get; private set; }
    public int QuotaMinutes { get; private set; }

    public QueryIntervalDialog(int accountMinutes, int quotaMinutes)
    {
        InitializeComponent();
        AccountInput.Text = accountMinutes.ToString(CultureInfo.InvariantCulture);
        QuotaInput.Text = quotaMinutes.ToString(CultureInfo.InvariantCulture);
        Loaded += (_, _) => { AccountInput.Focus(); AccountInput.SelectAll(); };
    }

    public static bool TryParseMinutes(string? text, out int minutes) =>
        int.TryParse(text?.Trim(), NumberStyles.Integer, CultureInfo.InvariantCulture, out minutes) && minutes is >= 1 and <= 10080;

    private bool ValuesValid(out int account, out int quota)
    {
        bool accountValid = TryParseMinutes(AccountInput.Text, out account);
        bool quotaValid = TryParseMinutes(QuotaInput.Text, out quota);
        return accountValid && quotaValid;
    }

    private void InputChanged(object sender, TextChangedEventArgs args)
    {
        if (SaveButton is null || ValidationText is null || AccountInput is null || QuotaInput is null) return;
        SaveButton.IsEnabled = ValuesValid(out _, out _);
        ValidationText.Text = SaveButton.IsEnabled ? "可设置 1–10080 分钟，保存后安排下一次定时查询。" : "请输入 1–10080 之间的整数分钟。";
    }
    private void RestoreDefaults(object sender, RoutedEventArgs args) { AccountInput.Text = "1"; QuotaInput.Text = "1"; }
    private void SaveClicked(object sender, RoutedEventArgs args)
    {
        if (!ValuesValid(out int account, out int quota)) return;
        AccountMinutes = account;
        QuotaMinutes = quota;
        DialogResult = true;
    }

    // Exercises the real dialog controls in the Windows UI smoke test using synthetic values.
    internal bool ExerciseValidationForSmoke()
    {
        AccountInput.Text = "0";
        QuotaInput.Text = "7";
        if (SaveButton.IsEnabled) return false;
        AccountInput.Text = "2";
        if (!SaveButton.IsEnabled) return false;
        SaveButton.RaiseEvent(new RoutedEventArgs(System.Windows.Controls.Primitives.ButtonBase.ClickEvent));
        return AccountMinutes == 2 && QuotaMinutes == 7;
    }
}
