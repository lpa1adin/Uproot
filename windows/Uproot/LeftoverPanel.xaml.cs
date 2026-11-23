using System.Collections.ObjectModel;
using System.ComponentModel;
using System.IO;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Data;
using System.Windows.Input;

namespace Uproot;

/// <summary>Список найденных следов по группам с флажками и кнопкой «Удалить выбранное».</summary>
public partial class LeftoverPanel : UserControl
{
    public ObservableCollection<Leftover> Items { get; } = [];

    /// <summary>Вызывается перед удалением. Вернуть текст ошибки, чтобы отменить.</summary>
    public Func<IReadOnlyList<Leftover>, Task<string?>>? Prepare { get; set; }

    public event Action<Remover.Report>? Finished;

    private bool _busy;
    private bool _working;
    private string _emptyTitle = "", _emptyText = "", _emptyGlyph = "";
    private CancellationTokenSource? _sizesCts;

    public LeftoverPanel()
    {
        InitializeComponent();
        var view = (ListCollectionView)CollectionViewSource.GetDefaultView(Items);
        view.GroupDescriptions.Add(new PropertyGroupDescription(nameof(Leftover.CategoryTitle)));
        view.SortDescriptions.Add(new SortDescription(nameof(Leftover.CategoryOrder), ListSortDirection.Ascending));
        List.ItemsSource = view;
        Items.CollectionChanged += (_, e) =>
        {
            if (e.NewItems != null) foreach (Leftover l in e.NewItems) l.PropertyChanged += Item_PropertyChanged;
            if (e.OldItems != null) foreach (Leftover l in e.OldItems) l.PropertyChanged -= Item_PropertyChanged;
            Refresh();
        };
        Refresh();
    }

    public void SetEmpty(string title, string text, string glyph = "")
    {
        _emptyTitle = title; _emptyText = text; _emptyGlyph = glyph;
        Refresh();
    }

    public void SetBusy(bool busy)
    {
        _busy = busy;
        Refresh();
    }

    public void Load(IEnumerable<Leftover> items)
    {
        _sizesCts?.Cancel();
        Items.Clear();
        Append(items);
    }

    public void Append(IEnumerable<Leftover> items)
    {
        foreach (var i in items) Items.Add(i);
        _ = FillSizesAsync();
    }

    public void Clear()
    {
        _sizesCts?.Cancel();
        Items.Clear();
    }

    private async Task FillSizesAsync()
    {
        _sizesCts?.Cancel();
        var cts = _sizesCts = new CancellationTokenSource();
        foreach (var item in Items.Where(i => i.Size < 0 && i.Kind is ItemKind.Folder or ItemKind.File).ToList())
        {
            if (cts.IsCancellationRequested) return;
            var path = item.Path;
            item.Size = await Task.Run(() => Sizes.Of(path));
        }
    }

    private void Item_PropertyChanged(object? sender, PropertyChangedEventArgs e)
    {
        if (e.PropertyName is nameof(Leftover.Selected) or nameof(Leftover.Size)) Refresh();
    }

    private List<Leftover> Chosen => Items.Where(i => i.Selected && !i.IsProtected).ToList();

    private void Refresh()
    {
        var chosen = Chosen;
        long size = chosen.Where(i => i.Size > 0).Sum(i => i.Size);
        Summary.Text = chosen.Count == 0
            ? (Items.Count == 0 ? "" : $"Найдено {Items.Count} · ничего не выбрано")
            : $"Выбрано {chosen.Count} {Format.Plural(chosen.Count, "объект", "объекта", "объектов")}" + (size > 0 ? " · " + Format.Size(size) : "");
        DeleteButton.IsEnabled = chosen.Count > 0 && !_working;
        SelectAllButton.IsEnabled = Items.Count > 0;
        bool allOn = Items.Count > 0 && Items.All(i => i.Selected || i.IsProtected);
        SelectAllButton.Content = allOn ? "Снять все" : "Выбрать все";
        Busy.Visibility = _busy || _working ? Visibility.Visible : Visibility.Collapsed;

        EmptyState.Visibility = Items.Count == 0 ? Visibility.Visible : Visibility.Collapsed;
        EmptyTitle.Text = _busy ? "Ищу…" : _emptyTitle;
        EmptyText.Text = _busy ? "" : _emptyText;
        EmptyGlyph.Text = _busy ? "" : _emptyGlyph;
    }

    private void SelectAll_Click(object sender, RoutedEventArgs e)
    {
        bool allOn = Items.All(i => i.Selected || i.IsProtected);
        foreach (var i in Items) i.Selected = !allOn;
    }

    private void List_KeyDown(object sender, KeyEventArgs e)
    {
        if (e.Key != Key.Space || List.SelectedItems.Count == 0) return;
        var sel = List.SelectedItems.Cast<Leftover>().ToList();
        bool target = !sel.All(i => i.Selected);
        foreach (var i in sel) i.Selected = target;
        e.Handled = true;
    }

    private void List_MouseDoubleClick(object sender, MouseButtonEventArgs e)
    {
        if (List.SelectedItem is Leftover l) Show(l);
    }

    private static void Show(Leftover l)
    {
        if (l.Reg is not null) Native.ShowInRegedit(l.Reg);
        else if (l.Kind is ItemKind.Folder or ItemKind.File) Native.ShowInExplorer(l.Path);
    }

    private static Leftover? FromMenu(object sender) =>
        (sender as MenuItem)?.DataContext as Leftover;

    private void ShowItem_Click(object sender, RoutedEventArgs e)
    {
        if (FromMenu(sender) is { } l) Show(l);
    }

    private void CopyPath_Click(object sender, RoutedEventArgs e)
    {
        if (FromMenu(sender) is not { } l) return;
        var text = l.Reg is not null ? l.Reg.Display + (l.ValueName is null ? "" : " → " + l.ValueName) : l.Path;
        try { Clipboard.SetText(text); } catch { }
    }

    private async void Delete_Click(object sender, RoutedEventArgs e)
    {
        var chosen = Chosen;
        if (chosen.Count == 0) return;

        var answer = MessageBox.Show(Window.GetWindow(this)!,
            $"Удалить {chosen.Count} {Format.Plural(chosen.Count, "объект", "объекта", "объектов")}?",
            "Uproot", MessageBoxButton.OKCancel, MessageBoxImage.Warning, MessageBoxResult.Cancel);
        if (answer != MessageBoxResult.OK) return;

        _working = true;
        Refresh();
        try
        {
            if (Prepare is not null && await Prepare(chosen) is { } error)
            {
                MessageBox.Show(Window.GetWindow(this)!, error, "Uproot", MessageBoxButton.OK, MessageBoxImage.Information);
                return;
            }

            var report = await Task.Run(() => Remover.Remove(chosen));
            foreach (var r in report.Removed) Items.Remove(r);
            ShowReport(report);
            Finished?.Invoke(report);
        }
        finally
        {
            _working = false;
            Refresh();
        }
    }

    private void ShowReport(Remover.Report r)
    {
        var text = r.Failed.Count == 0
            ? "Выбранное успешно удалено."
            : $"Удалено {r.Removed.Count} из {r.Removed.Count + r.Failed.Count}.";
        if (r.Failed.Count > 0)
            text += "\n\nНе удалось:\n" + string.Join("\n", r.Failed.Take(12).Select(f => $"• {f.Item.Title}: {f.Reason}"))
                    + (r.Failed.Count > 12 ? $"\n…и ещё {r.Failed.Count - 12}" : "");

        MessageBox.Show(Window.GetWindow(this)!, text, r.Failed.Count == 0 ? "Готово" : "Удалено не всё",
                        MessageBoxButton.OK, r.Failed.Count == 0 ? MessageBoxImage.Information : MessageBoxImage.Warning);
    }
}
