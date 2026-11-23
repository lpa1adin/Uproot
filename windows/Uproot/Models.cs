using System.ComponentModel;
using System.IO;
using System.Runtime.CompilerServices;
using System.Windows.Media;
using Microsoft.Win32;

namespace Uproot;

public abstract class Observable : INotifyPropertyChanged
{
    public event PropertyChangedEventHandler? PropertyChanged;

    protected void Set<T>(ref T field, T value, [CallerMemberName] string? name = null)
    {
        if (EqualityComparer<T>.Default.Equals(field, value)) return;
        field = value;
        Raise(name!);
    }

    protected void Raise(string name) => PropertyChanged?.Invoke(this, new PropertyChangedEventArgs(name));
}

/// <summary>Программа из списка «Установленные приложения» (ветки Uninstall реестра).</summary>
public sealed class InstalledApp
{
    public required string Name { get; init; }
    public string? Publisher { get; init; }
    public string? Version { get; init; }
    public string? InstallLocation { get; init; }
    public string? UninstallString { get; init; }
    public string? DisplayIcon { get; init; }
    public bool IsMsi { get; init; }
    public long SizeBytes { get; init; }
    public required RegLocation UninstallKey { get; init; }
    public ImageSource? Icon { get; set; }

    public string Subtitle => string.Join(" · ", new[] { Publisher, Version }.Where(s => !string.IsNullOrWhiteSpace(s)));
    public string SizeText => SizeBytes > 0 ? Format.Size(SizeBytes) : "";
}

/// <summary>Ключ реестра. Всегда в 64-битном представлении: ветка WOW6432Node указывается явно в пути.</summary>
public sealed record RegLocation(RegistryHive Hive, string SubPath)
{
    public string HiveShort => Hive == RegistryHive.LocalMachine ? "HKLM" : Hive == RegistryHive.CurrentUser ? "HKCU" : Hive.ToString();
    public string HiveLong => Hive == RegistryHive.LocalMachine ? "HKEY_LOCAL_MACHINE" : "HKEY_CURRENT_USER";
    public string Display => HiveShort + "\\" + SubPath;

    public RegistryKey? Open(bool writable = false)
    {
        var root = RegistryKey.OpenBaseKey(Hive, RegistryView.Registry64);
        return root.OpenSubKey(SubPath, writable);
    }

    public RegLocation Child(string name) => new(Hive, SubPath + "\\" + name);
}

public enum Category { Program, AppData, Shortcuts, Registry, Autorun, Services, Tasks, Other }

public enum ItemKind { Folder, File, RegistryKey, RegistryValue, Service, Task }

/// <summary>Найденный след: папка, файл, ключ или значение реестра, служба, задание.</summary>
public sealed class Leftover : Observable
{
    public required ItemKind Kind { get; init; }
    public required Category Category { get; init; }
    /// <summary>Путь к файлу или папке, имя службы, путь задания (\Vendor\Task).</summary>
    public string Path { get; init; } = "";
    public RegLocation? Reg { get; init; }
    public string? ValueName { get; init; }
    public string? CustomTitle { get; init; }
    public string? Note { get; init; }

    public bool IsProtected => Kind switch
    {
        ItemKind.Folder or ItemKind.File => Guard.IsProtectedPath(Path),
        ItemKind.RegistryKey => Reg is null || Guard.IsProtectedKey(Reg),
        _ => false,
    };
    public bool CanSelect => !IsProtected;

    private bool _selected;
    public bool Selected { get => _selected; set => Set(ref _selected, value && !IsProtected); }

    private long _size = -1;
    public long Size
    {
        get => _size;
        set { Set(ref _size, value); Raise(nameof(SizeText)); }
    }

    public string SizeText => Kind is ItemKind.Folder or ItemKind.File ? (Size < 0 ? "…" : Format.Size(Size)) : "";

    public string Title => CustomTitle ?? Kind switch
    {
        ItemKind.RegistryValue => ValueName ?? "(по умолчанию)",
        ItemKind.RegistryKey => Reg!.SubPath.Split('\\').Last(),
        ItemKind.Service or ItemKind.Task => Path.Split('\\').Last(),
        _ => System.IO.Path.GetFileName(Path.TrimEnd('\\')),
    };

    public string Location => Kind switch
    {
        ItemKind.RegistryKey => Reg!.Display,
        ItemKind.RegistryValue => Reg!.Display,
        ItemKind.Service => Note ?? "Служба Windows",
        ItemKind.Task => "Планировщик заданий: " + Path,
        _ => System.IO.Path.GetDirectoryName(Path.TrimEnd('\\')) ?? Path,
    };

    public string Glyph => Kind switch
    {
        ItemKind.Folder => "",
        ItemKind.File when Path.EndsWith(".lnk", StringComparison.OrdinalIgnoreCase) => "",
        ItemKind.File => "",
        ItemKind.RegistryKey => "",
        ItemKind.RegistryValue => "",
        ItemKind.Service => "",
        ItemKind.Task => "",
        _ => "",
    };

    public string Badge => IsProtected ? "" : "";

    public int CategoryOrder => (int)Category;

    public string CategoryTitle => Category switch
    {
        Category.Program => "Папка программы",
        Category.AppData => "Данные и кэш (AppData, ProgramData)",
        Category.Shortcuts => "Ярлыки",
        Category.Registry => "Реестр",
        Category.Autorun => "Автозапуск",
        Category.Services => "Службы",
        Category.Tasks => "Задания планировщика",
        _ => "Другое",
    };
}

public static class Format
{
    public static string Size(long bytes)
    {
        string[] units = ["Б", "КБ", "МБ", "ГБ", "ТБ"];
        double v = bytes;
        int i = 0;
        while (v >= 1024 && i < units.Length - 1) { v /= 1024; i++; }
        return i == 0 ? $"{bytes} Б" : $"{v:0.#} {units[i]}";
    }

    public static string Plural(int n, string one, string few, string many)
    {
        int m10 = n % 10, m100 = n % 100;
        if (m10 == 1 && m100 != 11) return one;
        if (m10 is >= 2 and <= 4 && m100 is < 12 or > 14) return few;
        return many;
    }
}

public static class Sizes
{
    private static readonly EnumerationOptions Deep = new()
    {
        RecurseSubdirectories = true,
        IgnoreInaccessible = true,
        AttributesToSkip = FileAttributes.ReparsePoint,
    };

    public static long Of(string path)
    {
        try
        {
            if (File.Exists(path)) return new FileInfo(path).Length;
            if (!Directory.Exists(path)) return 0;
            long total = 0;
            foreach (var f in new DirectoryInfo(path).EnumerateFiles("*", Deep))
            {
                try { total += f.Length; } catch { }
            }
            return total;
        }
        catch { return 0; }
    }
}
