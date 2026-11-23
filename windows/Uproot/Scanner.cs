using System.IO;
using System.Text.RegularExpressions;
using Microsoft.Win32;

namespace Uproot;

public static partial class Scanner
{
    private const string Uninstall = @"Microsoft\Windows\CurrentVersion\Uninstall";

    private static readonly RegLocation[] UninstallRoots =
    [
        new(RegistryHive.LocalMachine, @"SOFTWARE\" + Uninstall),
        new(RegistryHive.LocalMachine, @"SOFTWARE\WOW6432Node\" + Uninstall),
        new(RegistryHive.CurrentUser, @"Software\" + Uninstall),
    ];

    private static readonly RegLocation[] SoftwareRoots =
    [
        new(RegistryHive.CurrentUser, "Software"),
        new(RegistryHive.CurrentUser, @"Software\WOW6432Node"),
        new(RegistryHive.LocalMachine, "SOFTWARE"),
        new(RegistryHive.LocalMachine, @"SOFTWARE\WOW6432Node"),
    ];

    private static readonly RegLocation[] RunRoots =
    [
        new(RegistryHive.CurrentUser, @"Software\Microsoft\Windows\CurrentVersion\Run"),
        new(RegistryHive.CurrentUser, @"Software\Microsoft\Windows\CurrentVersion\RunOnce"),
        new(RegistryHive.LocalMachine, @"SOFTWARE\Microsoft\Windows\CurrentVersion\Run"),
        new(RegistryHive.LocalMachine, @"SOFTWARE\Microsoft\Windows\CurrentVersion\RunOnce"),
        new(RegistryHive.LocalMachine, @"SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Run"),
    ];

    // =====================================================================
    // Установленные программы
    // =====================================================================

    public static List<InstalledApp> InstalledApps()
    {
        var list = new List<InstalledApp>();
        var seen = new HashSet<string>(StringComparer.OrdinalIgnoreCase);

        foreach (var root in UninstallRoots)
        {
            using var key = root.Open();
            if (key is null) continue;
            foreach (var sub in key.GetSubKeyNames())
            {
                using var k = key.OpenSubKey(sub);
                if (k is null) continue;
                var name = (k.GetValue("DisplayName") as string)?.Trim();
                if (string.IsNullOrWhiteSpace(name)) continue;
                if (k.GetValue("SystemComponent") is int sc && sc == 1) continue;
                if (k.GetValue("ParentKeyName") is not null) continue;               // обновления и компоненты
                if (k.GetValue("ReleaseType") is string rt && rt.Contains("Update", StringComparison.OrdinalIgnoreCase)) continue;
                var version = k.GetValue("DisplayVersion") as string;
                if (!seen.Add(name + "|" + version)) continue;

                var app = new InstalledApp
                {
                    Name = name,
                    Publisher = (k.GetValue("Publisher") as string)?.Trim(),
                    Version = version,
                    InstallLocation = (k.GetValue("InstallLocation") as string)?.Trim().Trim('"'),
                    UninstallString = k.GetValue("UninstallString") as string,
                    DisplayIcon = k.GetValue("DisplayIcon") as string,
                    IsMsi = k.GetValue("WindowsInstaller") is int wi && wi == 1,
                    SizeBytes = k.GetValue("EstimatedSize") is int es ? es * 1024L : 0,
                    UninstallKey = root.Child(sub),
                };
                app.Icon = Native.IconOf(IconPath(app));
                list.Add(app);
            }
        }
        return list.OrderBy(a => a.Name, StringComparer.CurrentCultureIgnoreCase).ToList();
    }

    private static string? IconPath(InstalledApp a)
    {
        var p = ExePath(a.DisplayIcon);
        if (p is not null && File.Exists(p)) return p;
        var dir = InstallDir(a);
        if (dir is null) return null;
        try { return Directory.EnumerateFiles(dir, "*.exe").FirstOrDefault(); } catch { return null; }
    }

    /// <summary>Вытаскивает путь к exe/ico из строк вида "C:\x\a.exe",0 или C:\x\a.exe /uninstall.</summary>
    public static string? ExePath(string? s)
    {
        if (string.IsNullOrWhiteSpace(s)) return null;
        s = s.Trim();
        if (s.StartsWith('"'))
        {
            int end = s.IndexOf('"', 1);
            return end > 1 ? s[1..end] : null;
        }
        var m = ExeRegex().Match(s);
        if (m.Success) return m.Value;
        int comma = s.LastIndexOf(',');
        return comma > 0 ? s[..comma] : s;
    }

    [GeneratedRegex(@"^.+?\.(exe|ico|dll)", RegexOptions.IgnoreCase)]
    private static partial Regex ExeRegex();

    /// <summary>Папка установки: из InstallLocation или по пути к деинсталлятору/иконке.</summary>
    public static string? InstallDir(InstalledApp a)
    {
        if (!string.IsNullOrWhiteSpace(a.InstallLocation) && Directory.Exists(a.InstallLocation) && !Guard.IsProtectedPath(a.InstallLocation))
            return a.InstallLocation.TrimEnd('\\');

        foreach (var src in new[] { a.DisplayIcon, a.UninstallString })
        {
            var exe = ExePath(src);
            if (exe is null || exe.Contains("msiexec", StringComparison.OrdinalIgnoreCase)) continue;
            var dir = Path.GetDirectoryName(exe);
            if (dir is null || !Directory.Exists(dir) || Guard.IsProtectedPath(dir)) continue;
            if (dir.Contains(@"\Package Cache\", StringComparison.OrdinalIgnoreCase) ||
                dir.Contains(@"\Installer", StringComparison.OrdinalIgnoreCase) ||
                dir.Contains(@"\Temp", StringComparison.OrdinalIgnoreCase)) continue;
            // Деинсталлятор часто лежит в подпапке uninst/uninstall — поднимемся на уровень выше
            var leaf = Path.GetFileName(dir).ToLowerInvariant();
            if (leaf.StartsWith("uninst") && Path.GetDirectoryName(dir) is { } parent && !Guard.IsProtectedPath(parent)) dir = parent;
            return dir;
        }
        return null;
    }

    // =====================================================================
    // Следы конкретной программы
    // =====================================================================

    private static readonly HashSet<string> GenericNames = new(StringComparer.OrdinalIgnoreCase)
    {
        "microsoft", "windows", "update", "updater", "common files", "programs", "program files", "data", "cache",
        "temp", "tools", "packages", "system", "app", "application", "setup", "installer", "bin", "launcher", "runtime",
        "service", "helper", "client", "driver", "drivers", "plugins", "google", "apple", "adobe", "intel", "nvidia",
    };

    private static readonly string[] CompanySuffixes =
        [", Inc.", " Inc.", " Inc", ", LLC", " LLC", " Ltd.", " Ltd", " Limited", " Corporation", " Corp.", " Corp",
         " GmbH", " s.r.o.", " AG", " SA", " S.A.", " Co.", " B.V.", " Software", " Technologies", " Games"];

    public sealed record Tokens(string[] Names, string[] InnerNames, string[] Publishers, string? InstallDir);

    public static Tokens TokensFor(InstalledApp a)
    {
        var names = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
        void Add(HashSet<string> set, string? s)
        {
            s = s?.Trim();
            if (!string.IsNullOrEmpty(s) && s.Length >= 3 && !GenericNames.Contains(s)) set.Add(s);
        }

        var clean = CleanName(a.Name);
        Add(names, a.Name);
        Add(names, clean);
        var dir = InstallDir(a);
        if (dir is not null) Add(names, Path.GetFileName(dir));

        var publishers = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
        var pub = CleanPublisher(a.Publisher);
        if (pub is not null && pub.Length >= 3) publishers.Add(pub);
        if (pub is not null && pub.Contains(' ')) publishers.Add(pub.Split(' ')[0]);

        // Внутри папки издателя продукт часто называется без имени издателя: «JetBrains Rider» → «Rider»
        var inner = new HashSet<string>(names, StringComparer.OrdinalIgnoreCase);
        foreach (var p in publishers)
            if (clean.StartsWith(p + " ", StringComparison.OrdinalIgnoreCase))
                Add(inner, clean[(p.Length + 1)..]);

        return new Tokens([.. names], [.. inner], [.. publishers.Where(p => p.Length >= 3)], dir);
    }

    [GeneratedRegex(@"\s*\((x64|x86|64-bit|32-bit|64 bit|32 bit|amd64|arm64|[a-z]{2}-[a-z]{2}|user|machine)\)", RegexOptions.IgnoreCase)]
    private static partial Regex ArchRegex();

    [GeneratedRegex(@"\s+v?\d+(\.\d+)+.*$")]
    private static partial Regex VersionRegex();

    [GeneratedRegex(@"\s+(x64|x86|64-bit|32-bit)$|\s+-\s+[a-z]{2}-[a-z]{2}$", RegexOptions.IgnoreCase)]
    private static partial Regex TailRegex();

    public static string CleanName(string name)
    {
        var s = ArchRegex().Replace(name, "");
        s = VersionRegex().Replace(s, "");
        s = TailRegex().Replace(s, "");
        return s.Trim();
    }

    public static string? CleanPublisher(string? publisher)
    {
        if (string.IsNullOrWhiteSpace(publisher)) return null;
        var s = publisher.Trim();
        bool changed = true;
        while (changed)
        {
            changed = false;
            foreach (var suf in CompanySuffixes)
                if (s.EndsWith(suf, StringComparison.OrdinalIgnoreCase)) { s = s[..^suf.Length].TrimEnd(' ', ','); changed = true; }
        }
        return s.Length >= 3 ? s : null;
    }

    public static bool Matches(string name, IEnumerable<string> tokens)
    {
        // У ярлыков сравниваем имя без расширения; у папок точка — часть имени (com.vendor.app)
        bool isShortcut = name.EndsWith(".lnk", StringComparison.OrdinalIgnoreCase) || name.EndsWith(".url", StringComparison.OrdinalIgnoreCase);
        var n = isShortcut ? Path.GetFileNameWithoutExtension(name) : name;
        var compactN = n.Replace(" ", "");
        foreach (var t in tokens)
        {
            if (n.Equals(t, StringComparison.OrdinalIgnoreCase)) return true;
            if (compactN.Equals(t.Replace(" ", ""), StringComparison.OrdinalIgnoreCase)) return true;
            if (t.Length >= 5)
                foreach (var sep in new[] { " ", "-", "_", "." })
                    if (n.StartsWith(t + sep, StringComparison.OrdinalIgnoreCase)) return true;
        }
        return false;
    }

    public static List<Leftover> LeftoversFor(InstalledApp app, CancellationToken ct)
    {
        var t = TokensFor(app);
        var found = new List<Leftover>();
        var seen = new HashSet<string>(StringComparer.OrdinalIgnoreCase);

        void AddPath(string path, Category cat, bool selected = true)
        {
            if (!seen.Add(path)) return;
            bool isDir = Directory.Exists(path);
            found.Add(new Leftover { Kind = isDir ? ItemKind.Folder : ItemKind.File, Category = cat, Path = path, Selected = selected });
        }

        // 1. Папка установки
        if (t.InstallDir is not null) AddPath(t.InstallDir, Category.Program);

        // 2. Папки в Program Files, AppData, ProgramData — по имени или внутри папки издателя
        foreach (var (root, cat) in Places.FolderRoots())
        {
            ct.ThrowIfCancellationRequested();
            foreach (var dir in SafeDirs(root))
            {
                var name = Path.GetFileName(dir);
                if (Matches(name, t.Names)) { AddPath(dir, cat); continue; }
                if (Matches(name, t.Publishers))
                    foreach (var inner in SafeDirs(dir))
                        if (Matches(Path.GetFileName(inner), t.InnerNames)) AddPath(inner, cat);
            }
        }

        // 3. Ярлыки в меню «Пуск» и на рабочем столе
        foreach (var root in Places.ShortcutRoots)
        {
            foreach (var dir in SafeDirs(root))
                if (Matches(Path.GetFileName(dir), t.Names) || Matches(Path.GetFileName(dir), t.Publishers) && ContainsOnlyMatching(dir, t.InnerNames))
                    AddPath(dir, Category.Shortcuts);
            foreach (var file in SafeFiles(root))
                if ((file.EndsWith(".lnk", StringComparison.OrdinalIgnoreCase) || file.EndsWith(".url", StringComparison.OrdinalIgnoreCase))
                    && (Matches(Path.GetFileName(file), t.Names) || PointsInto(file, t.InstallDir)))
                    AddPath(file, Category.Shortcuts);
        }

        // 4. Реестр: HKCU\Software и HKLM\SOFTWARE
        foreach (var root in SoftwareRoots)
        {
            ct.ThrowIfCancellationRequested();
            using var key = root.Open();
            if (key is null) continue;
            foreach (var sub in key.GetSubKeyNames())
            {
                if (Matches(sub, t.Names)) { AddKey(found, seen, root.Child(sub)); continue; }
                if (!Matches(sub, t.Publishers)) continue;
                using var pubKey = key.OpenSubKey(sub);
                if (pubKey is null) continue;
                foreach (var inner in pubKey.GetSubKeyNames())
                    if (Matches(inner, t.InnerNames)) AddKey(found, seen, root.Child(sub).Child(inner));
            }
        }

        // 5. Запись в «Установленных приложениях» (если штатный деинсталлятор её не убрал)
        using (var uk = app.UninstallKey.Open())
            if (uk is not null)
                found.Add(new Leftover
                {
                    Kind = ItemKind.RegistryKey, Category = Category.Registry, Reg = app.UninstallKey,
                    CustomTitle = "Запись «" + app.Name + "» в списке программ",
                    Selected = t.InstallDir is null || !Directory.Exists(t.InstallDir),
                });

        // 6. Автозапуск
        foreach (var root in RunRoots)
        {
            using var key = root.Open();
            if (key is null) continue;
            foreach (var v in key.GetValueNames())
            {
                var data = key.GetValue(v) as string ?? "";
                if (Matches(v, t.Names) || (t.InstallDir is not null && data.Contains(t.InstallDir, StringComparison.OrdinalIgnoreCase)))
                    found.Add(new Leftover { Kind = ItemKind.RegistryValue, Category = Category.Autorun, Reg = root, ValueName = v, Note = data, Selected = true });
            }
        }

        // 7. Службы, чей исполняемый файл лежит в папке программы
        using (var services = new RegLocation(RegistryHive.LocalMachine, @"SYSTEM\CurrentControlSet\Services").Open())
            if (services is not null)
                foreach (var s in services.GetSubKeyNames())
                {
                    using var sk = services.OpenSubKey(s);
                    var image = sk?.GetValue("ImagePath") as string ?? "";
                    var display = sk?.GetValue("DisplayName") as string ?? "";
                    bool inDir = t.InstallDir is not null && image.Contains(t.InstallDir, StringComparison.OrdinalIgnoreCase);
                    bool byName = Matches(s, t.Names) || (!display.StartsWith('@') && Matches(display, t.Names));
                    if ((inDir || byName) && !image.Contains(@"\Windows\", StringComparison.OrdinalIgnoreCase))
                        found.Add(new Leftover { Kind = ItemKind.Service, Category = Category.Services, Path = s,
                                                 Note = string.IsNullOrEmpty(display) || display.StartsWith('@') ? image : display + " — " + image, Selected = true });
                }

        // 8. Задания планировщика
        foreach (var file in SafeFiles(Places.Tasks, depth: 2))
        {
            var rel = file[Places.Tasks.Length..];
            var parts = rel.Split('\\', StringSplitOptions.RemoveEmptyEntries);
            if (parts.Any(p => Matches(p, t.Names) || Matches(p, t.Publishers) && Matches(parts[^1], t.InnerNames)))
                found.Add(new Leftover { Kind = ItemKind.Task, Category = Category.Tasks, Path = rel, Selected = true });
        }

        return found.OrderBy(l => l.Category).ThenBy(l => l.Title, StringComparer.CurrentCultureIgnoreCase).ToList();
    }

    private static void AddKey(List<Leftover> list, HashSet<string> seen, RegLocation reg)
    {
        if (!seen.Add(reg.Display)) return;
        list.Add(new Leftover { Kind = ItemKind.RegistryKey, Category = Category.Registry, Reg = reg, Selected = true });
    }

    private static bool ContainsOnlyMatching(string dir, string[] tokens)
    {
        var entries = SafeEntries(dir).ToList();
        return entries.Count > 0 && entries.All(e => Matches(Path.GetFileName(e), tokens));
    }

    private static bool PointsInto(string lnk, string? dir)
    {
        if (dir is null || !lnk.EndsWith(".lnk", StringComparison.OrdinalIgnoreCase)) return false;
        var target = Native.ShortcutTarget(lnk);
        return target is not null && target.StartsWith(dir + "\\", StringComparison.OrdinalIgnoreCase);
    }

    // =====================================================================
    // Мёртвые записи: следы уже удалённых программ
    // =====================================================================

    public static List<Leftover> Orphans(CancellationToken ct)
    {
        var found = new List<Leftover>();

        // 1. Записи в списке программ, у которых нет ни деинсталлятора, ни папки
        foreach (var root in UninstallRoots)
        {
            using var key = root.Open();
            if (key is null) continue;
            foreach (var sub in key.GetSubKeyNames())
            {
                using var k = key.OpenSubKey(sub);
                if (k is null) continue;
                var name = k.GetValue("DisplayName") as string;
                if (string.IsNullOrWhiteSpace(name) || k.GetValue("WindowsInstaller") is int wi && wi == 1) continue;
                if (k.GetValue("SystemComponent") is int sc && sc == 1) continue;
                var exe = ExePath(k.GetValue("UninstallString") as string);
                if (exe is null || exe.Contains("msiexec", StringComparison.OrdinalIgnoreCase) || exe.Contains("rundll32", StringComparison.OrdinalIgnoreCase)) continue;
                var loc = (k.GetValue("InstallLocation") as string)?.Trim('"');
                if (File.Exists(Environment.ExpandEnvironmentVariables(exe))) continue;
                if (!string.IsNullOrWhiteSpace(loc) && Directory.Exists(loc)) continue;
                found.Add(new Leftover { Kind = ItemKind.RegistryKey, Category = Category.Registry, Reg = root.Child(sub),
                                         CustomTitle = name + " — деинсталлятор пропал" });
            }
        }

        // 2. Ярлыки, ведущие в никуда
        foreach (var root in Places.ShortcutRoots)
            foreach (var lnk in SafeFiles(root, depth: 3).Where(f => f.EndsWith(".lnk", StringComparison.OrdinalIgnoreCase)))
            {
                ct.ThrowIfCancellationRequested();
                var target = Native.ShortcutTarget(lnk);
                if (string.IsNullOrWhiteSpace(target) || target.Length < 3 || target[1] != ':') continue;   // только локальные пути
                if (!DriveExists(target)) continue;
                if (!File.Exists(target) && !Directory.Exists(target))
                    found.Add(new Leftover { Kind = ItemKind.File, Category = Category.Shortcuts, Path = lnk });
            }

        // 3. Пустые папки верхнего уровня
        foreach (var (root, _) in Places.FolderRoots())
            foreach (var dir in SafeDirs(root))
            {
                ct.ThrowIfCancellationRequested();
                if (IsEmptyTree(dir) && !Guard.IsProtectedPath(dir))
                    found.Add(new Leftover { Kind = ItemKind.Folder, Category = Category.Other, Path = dir, Size = 0 });
            }

        return found;
    }

    private static bool DriveExists(string path)
    {
        try { return new DriveInfo(path[..1]).IsReady; } catch { return false; }
    }

    private static bool IsEmptyTree(string dir)
    {
        try
        {
            var attr = File.GetAttributes(dir);
            if (attr.HasFlag(FileAttributes.ReparsePoint) || attr.HasFlag(FileAttributes.System)) return false;
            return !Directory.EnumerateFiles(dir, "*", SearchOption.AllDirectories).Any();
        }
        catch { return false; }   // нет доступа — не трогаем
    }

    // =====================================================================
    // Поиск по имени
    // =====================================================================

    public enum Scope { Profile, Programs, AllDrives }

    public static void Search(string query, Scope scope, bool registry, Action<List<Leftover>> onBatch, CancellationToken ct, int limit = 3000)
    {
        var batch = new List<Leftover>();
        int total = 0;
        var last = DateTime.UtcNow;

        void Flush(bool force = false)
        {
            if (batch.Count == 0 || (!force && (DateTime.UtcNow - last).TotalMilliseconds < 150)) return;
            onBatch(batch);
            batch = [];
            last = DateTime.UtcNow;
        }

        string[] roots = scope switch
        {
            Scope.Profile => [Places.UserProfile],
            Scope.Programs => [Places.ProgramFiles, Places.ProgramFilesX86, Places.ProgramData, Places.AppData, Places.LocalAppData, Places.LocalLow,
                               Places.StartMenu, Places.CommonStartMenu],
            _ => DriveInfo.GetDrives().Where(d => d.DriveType == DriveType.Fixed && d.IsReady).Select(d => d.RootDirectory.FullName).ToArray(),
        };

        var skip = new HashSet<string>(StringComparer.OrdinalIgnoreCase) { Places.Windows };
        var visited = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
        var stack = new Stack<string>(roots.Distinct(StringComparer.OrdinalIgnoreCase).Reverse());

        while (stack.Count > 0 && total < limit)
        {
            ct.ThrowIfCancellationRequested();
            var dir = stack.Pop();
            if (!visited.Add(dir)) continue;
            foreach (var entry in SafeEntries(dir))
            {
                var name = Path.GetFileName(entry);
                bool isDir = Directory.Exists(entry);
                if (name.Contains(query, StringComparison.OrdinalIgnoreCase))
                {
                    batch.Add(new Leftover { Kind = isDir ? ItemKind.Folder : ItemKind.File, Category = Places.Classify(entry), Path = entry });
                    total++;
                    continue;   // совпавшая папка — одним результатом
                }
                if (!isDir || skip.Contains(entry) || name.StartsWith('$') || name == "System Volume Information") continue;
                try { if (File.GetAttributes(entry).HasFlag(FileAttributes.ReparsePoint)) continue; } catch { continue; }
                stack.Push(entry);
            }
            Flush();
        }

        if (registry)
            foreach (var root in new[] { new RegLocation(RegistryHive.CurrentUser, "Software"), new RegLocation(RegistryHive.LocalMachine, "SOFTWARE") })
                SearchRegistry(root, query, 0, batch, ref total, limit, ct);

        Flush(force: true);
    }

    private static void SearchRegistry(RegLocation loc, string query, int depth, List<Leftover> batch, ref int total, int limit, CancellationToken ct)
    {
        if (depth > 4 || total >= limit) return;
        ct.ThrowIfCancellationRequested();
        string[] subs;
        try
        {
            using var key = loc.Open();
            if (key is null) return;
            subs = key.GetSubKeyNames();
        }
        catch { return; }

        foreach (var sub in subs)
        {
            var child = loc.Child(sub);
            if (sub.Contains(query, StringComparison.OrdinalIgnoreCase))
            {
                batch.Add(new Leftover { Kind = ItemKind.RegistryKey, Category = Category.Registry, Reg = child });
                if (++total >= limit) return;
                continue;
            }
            if (sub.Equals("Classes", StringComparison.OrdinalIgnoreCase)) continue;   // огромная и системная
            SearchRegistry(child, query, depth + 1, batch, ref total, limit, ct);
        }
    }

    // =====================================================================
    // Безопасный обход папок
    // =====================================================================

    private static readonly EnumerationOptions Shallow = new() { IgnoreInaccessible = true, AttributesToSkip = 0 };

    private static IEnumerable<string> SafeEntries(string dir)
    {
        try { return Directory.Exists(dir) ? Directory.EnumerateFileSystemEntries(dir, "*", Shallow).ToList() : []; }
        catch { return []; }
    }

    private static IEnumerable<string> SafeDirs(string dir)
    {
        try { return Directory.Exists(dir) ? Directory.EnumerateDirectories(dir, "*", Shallow).ToList() : []; }
        catch { return []; }
    }

    private static IEnumerable<string> SafeFiles(string dir, int depth = 1)
    {
        var result = new List<string>();
        try
        {
            if (!Directory.Exists(dir)) return result;
            result.AddRange(Directory.EnumerateFiles(dir, "*", Shallow));
            if (depth > 1)
                foreach (var sub in Directory.EnumerateDirectories(dir, "*", Shallow))
                    result.AddRange(SafeFiles(sub, depth - 1));
        }
        catch { }
        return result;
    }
}
