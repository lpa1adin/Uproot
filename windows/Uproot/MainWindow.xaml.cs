using System.ComponentModel;
using System.Diagnostics;
using System.IO;
using System.Security.Principal;
using System.Text.Json;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Data;

namespace Uproot;

public partial class MainWindow : Window
{
    private List<InstalledApp> _apps = [];
    private ICollectionView? _appsView;
    private InstalledApp? _current;
    private CancellationTokenSource? _scanCts, _searchCts;
    private bool _orphansScanned;

    public MainWindow()
    {
        InitializeComponent();

        AppPanel.SetEmpty("Следов не осталось", "", "");
        OrphansPanel.SetEmpty("Остатков нет", "", "");
        SearchPanel.SetEmpty("Поиск по имени", "", "");

        AppPanel.Finished += _ => _ = ReloadAppsAsync(keepSelection: true);

        var settings = Settings.Load();
        ThemeBox.SelectedIndex = settings.Theme switch { "Light" => 1, "Dark" => 2, _ => 0 };
        BackupPathText.Text = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.MyDocuments), "Uproot", "Резервные копии");
        bool admin = new WindowsPrincipal(WindowsIdentity.GetCurrent()).IsInRole(WindowsBuiltInRole.Administrator);
        AdminText.Text = admin
            ? "Есть"
            : "Нет — запустите Uproot от имени администратора";
    }

    // ================= Загрузка =================

    private async void Window_Loaded(object sender, RoutedEventArgs e) => await ReloadAppsAsync(keepSelection: false);

    private async Task ReloadAppsAsync(bool keepSelection)
    {
        AppCount.Text = "Загрузка…";
        var key = _current?.UninstallKey;
        _apps = await Task.Run(Scanner.InstalledApps);
        _appsView = CollectionViewSource.GetDefaultView(_apps);
        _appsView.Filter = o => o is InstalledApp a && Filter(a);
        ApplySort();
        AppList.ItemsSource = _appsView;
        AppCount.Text = $"{_apps.Count} {Format.Plural(_apps.Count, "программа", "программы", "программ")}";
        if (keepSelection && key is not null)
            AppList.SelectedItem = _apps.FirstOrDefault(a => a.UninstallKey == key);
    }

    private bool Filter(InstalledApp a)
    {
        var q = AppFilter.Text.Trim();
        return q.Length == 0
            || a.Name.Contains(q, StringComparison.CurrentCultureIgnoreCase)
            || (a.Publisher?.Contains(q, StringComparison.CurrentCultureIgnoreCase) ?? false);
    }

    private void ApplySort()
    {
        if (_appsView is null) return;
        _appsView.SortDescriptions.Clear();
        _appsView.SortDescriptions.Add(AppSort.SelectedIndex == 1
            ? new SortDescription(nameof(InstalledApp.SizeBytes), ListSortDirection.Descending)
            : new SortDescription(nameof(InstalledApp.Name), ListSortDirection.Ascending));
    }

    private void AppFilter_TextChanged(object sender, TextChangedEventArgs e)
    {
        AppFilterHint.Visibility = AppFilter.Text.Length == 0 ? Visibility.Visible : Visibility.Collapsed;
        _appsView?.Refresh();
    }

    private void AppSort_SelectionChanged(object sender, SelectionChangedEventArgs e) => ApplySort();

    // ================= Навигация =================

    private void Nav_SelectionChanged(object sender, SelectionChangedEventArgs e)
    {
        if (AppsPage is null) return;   // ещё строится
        var tag = (Nav.SelectedItem as ListBoxItem)?.Tag as string ?? "apps";
        AppsPage.Visibility = tag == "apps" ? Visibility.Visible : Visibility.Collapsed;
        OrphansPage.Visibility = tag == "orphans" ? Visibility.Visible : Visibility.Collapsed;
        SearchPage.Visibility = tag == "search" ? Visibility.Visible : Visibility.Collapsed;
        SettingsPage.Visibility = tag == "settings" ? Visibility.Visible : Visibility.Collapsed;
        if (tag == "orphans" && !_orphansScanned) _ = ScanOrphansAsync();
        if (tag == "search") SearchBox.Focus();
    }

    // ================= Программа =================

    private void AppList_SelectionChanged(object sender, SelectionChangedEventArgs e)
    {
        if (AppList.SelectedItem is not InstalledApp app) return;
        _current = app;
        NoSelection.Visibility = Visibility.Collapsed;
        Detail.Visibility = Visibility.Visible;
        DetailIcon.Source = app.Icon;
        DetailName.Text = app.Name;
        DetailSub.Text = string.Join(" · ", new[] { app.Publisher, app.Version is null ? null : "версия " + app.Version, app.SizeText }
                                              .Where(s => !string.IsNullOrWhiteSpace(s)));
        DetailPath.Text = Scanner.InstallDir(app) ?? app.UninstallKey.Display;
        UninstallButton.IsEnabled = !string.IsNullOrWhiteSpace(app.UninstallString);
        StepTitle.Text = "Шаг 1 — штатное удаление";
        StepText.Text = UninstallButton.IsEnabled
            ? "Затем Uproot найдёт оставшиеся файлы."
            : "У программы нет деинсталлятора.";
        _ = ScanAppAsync(app);
    }

    private async Task ScanAppAsync(InstalledApp app)
    {
        _scanCts?.Cancel();
        var cts = _scanCts = new CancellationTokenSource();
        AppPanel.Clear();
        AppPanel.SetBusy(true);
        try
        {
            var found = await Task.Run(() => Scanner.LeftoversFor(app, cts.Token), cts.Token);
            if (cts.IsCancellationRequested || _current != app) return;
            AppPanel.Load(found);
        }
        catch (OperationCanceledException) { }
        finally
        {
            if (_scanCts == cts) AppPanel.SetBusy(false);
        }
    }

    private async void Uninstall_Click(object sender, RoutedEventArgs e)
    {
        if (_current is not { } app) return;
        UninstallButton.IsEnabled = false;
        StepTitle.Text = "Работает деинсталлятор…";
        StepText.Text = "Завершите удаление в его окне.";
        var error = await Remover.RunUninstaller(app);
        if (error is not null)
        {
            MessageBox.Show(this, error, "Uproot", MessageBoxButton.OK, MessageBoxImage.Information);
            StepTitle.Text = "Шаг 1 — штатное удаление";
        }
        else
        {
            StepTitle.Text = "Шаг 2 — остатки";
            StepText.Text = "Что осталось после программы.";
        }
        UninstallButton.IsEnabled = !string.IsNullOrWhiteSpace(app.UninstallString);
        if (_current == app) await ScanAppAsync(app);
    }

    private void Rescan_Click(object sender, RoutedEventArgs e)
    {
        if (_current is { } app) _ = ScanAppAsync(app);
    }

    // ================= Остатки удалённых =================

    private void OrphansScan_Click(object sender, RoutedEventArgs e) => _ = ScanOrphansAsync();

    private async Task ScanOrphansAsync()
    {
        _orphansScanned = true;
        OrphansPanel.Clear();
        OrphansPanel.SetBusy(true);
        try { OrphansPanel.Load(await Task.Run(() => Scanner.Orphans(CancellationToken.None))); }
        finally { OrphansPanel.SetBusy(false); }
    }

    // ================= Поиск =================

    private void SearchBox_TextChanged(object sender, TextChangedEventArgs e) =>
        SearchHint.Visibility = SearchBox.Text.Length == 0 ? Visibility.Visible : Visibility.Collapsed;

    private async void Search_Click(object sender, RoutedEventArgs e)
    {
        if (_searchCts is not null) { _searchCts.Cancel(); return; }   // кнопка работает как «Стоп»

        var q = SearchBox.Text.Trim();
        if (q.Length < 2) return;
        var scope = (Scanner.Scope)SearchScope.SelectedIndex;
        bool registry = SearchRegistry.IsChecked == true;

        var cts = _searchCts = new CancellationTokenSource();
        SearchButton.Content = "Стоп";
        SearchPanel.Clear();
        SearchPanel.SetBusy(true);
        try
        {
            await Task.Run(() => Scanner.Search(q, scope, registry,
                batch => Dispatcher.Invoke(() => SearchPanel.Append(batch)), cts.Token), cts.Token);
        }
        catch (OperationCanceledException) { }
        finally
        {
            _searchCts = null;
            SearchButton.Content = "Искать";
            SearchPanel.SetBusy(false);
            if (SearchPanel.Items.Count == 0)
                SearchPanel.SetEmpty("Ничего не нашлось", "", "");
        }
    }

    // ================= Настройки =================

    private void ThemeBox_SelectionChanged(object sender, SelectionChangedEventArgs e)
    {
        var theme = (ThemeBox.SelectedItem as ComboBoxItem)?.Tag as string ?? "System";
        Settings.ApplyTheme(theme);
        Settings.Save(new Settings.Data(theme));
    }

    private void OpenBackups_Click(object sender, RoutedEventArgs e)
    {
        Directory.CreateDirectory(BackupPathText.Text);
        Process.Start("explorer.exe", $"\"{BackupPathText.Text}\"");
    }
}

/// <summary>Настройки в %AppData%\Uproot\settings.json.</summary>
public static class Settings
{
    public sealed record Data(string Theme);

    private static readonly string FilePath =
        Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.ApplicationData), "Uproot", "settings.json");

    public static Data Load()
    {
        try { return JsonSerializer.Deserialize<Data>(File.ReadAllText(FilePath)) ?? new Data("System"); }
        catch { return new Data("System"); }
    }

    public static void Save(Data data)
    {
        try
        {
            Directory.CreateDirectory(Path.GetDirectoryName(FilePath)!);
            File.WriteAllText(FilePath, JsonSerializer.Serialize(data));
        }
        catch { }
    }

    public static void ApplyTheme(string theme)
    {
        Application.Current.ThemeMode = theme switch
        {
            "Light" => ThemeMode.Light,
            "Dark" => ThemeMode.Dark,
            _ => ThemeMode.System,
        };
    }
}
