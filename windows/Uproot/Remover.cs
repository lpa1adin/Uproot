using System.Diagnostics;
using System.IO;

namespace Uproot;

public static class Remover
{
    public sealed class Report
    {
        public List<Leftover> Removed { get; } = [];
        public List<(Leftover Item, string Reason)> Failed { get; } = [];
        public string? BackupFolder { get; set; }
    }

    /// <summary>Папка для резервных копий реестра: Документы\Uproot\Резервные копии\дата.</summary>
    private static string NewBackupFolder()
    {
        var dir = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.MyDocuments), "Uproot", "Резервные копии",
                               DateTime.Now.ToString("yyyy-MM-dd HH-mm-ss"));
        Directory.CreateDirectory(dir);
        return dir;
    }

    /// <summary>
    /// Удаляет выбранное. Файлы и папки — в Корзину, ключи реестра — после экспорта в .reg,
    /// службы — через sc.exe, задания — через schtasks.exe.
    /// </summary>
    public static Report Remove(IReadOnlyList<Leftover> items)
    {
        var report = new Report();
        string? backup = null;
        string Backup() => backup ??= NewBackupFolder();
        int n = 0;

        // Порядок важен: сначала останавливаем службы и задания, потом удаляем файлы, которые они держат.
        foreach (var item in items.OrderBy(Order))
        {
            if (item.IsProtected) { report.Failed.Add((item, "системный путь — пропущен")); continue; }
            try
            {
                switch (item.Kind)
                {
                    case ItemKind.Service:
                        Native.Run("sc.exe", $"stop \"{item.Path}\"");
                        var (code, output) = Native.Run("sc.exe", $"delete \"{item.Path}\"");
                        if (code != 0 && code != 1060) throw new Exception(output.Trim());   // 1060 — службы уже нет
                        break;

                    case ItemKind.Task:
                        var (tc, tout) = Native.Run("schtasks.exe", $"/Delete /TN \"{item.Path}\" /F");
                        if (tc != 0) throw new Exception(tout.Trim());
                        break;

                    case ItemKind.RegistryValue:
                        Export(item.Reg!, Path.Combine(Backup(), $"{++n:00} автозапуск.reg"));
                        using (var key = item.Reg!.Open(writable: true))
                            key?.DeleteValue(item.ValueName ?? "", throwOnMissingValue: false);
                        break;

                    case ItemKind.RegistryKey:
                        var file = Path.Combine(Backup(), $"{++n:00} {Safe(item.Title)}.reg");
                        if (!Export(item.Reg!, file)) throw new Exception("не удалось сохранить резервную копию — ключ не тронут");
                        var parent = item.Reg!.SubPath[..item.Reg.SubPath.LastIndexOf('\\')];
                        var leaf = item.Reg.SubPath[(item.Reg.SubPath.LastIndexOf('\\') + 1)..];
                        using (var pk = new RegLocation(item.Reg.Hive, parent).Open(writable: true))
                            pk?.DeleteSubKeyTree(leaf, throwOnMissingSubKey: false);
                        break;

                    case ItemKind.Folder:
                    case ItemKind.File:
                        if (!File.Exists(item.Path) && !Directory.Exists(item.Path)) break;
                        if (!Native.Recycle(item.Path)) throw new Exception("файл занят или нет доступа");
                        break;
                }
                report.Removed.Add(item);
            }
            catch (Exception e)
            {
                report.Failed.Add((item, e.Message));
            }
        }
        report.BackupFolder = backup;
        return report;
    }

    private static int Order(Leftover l) => l.Kind switch
    {
        ItemKind.Service => 0,
        ItemKind.Task => 1,
        ItemKind.RegistryValue => 2,
        ItemKind.Folder or ItemKind.File => 3,
        _ => 4,
    };

    private static bool Export(RegLocation reg, string file)
    {
        var (code, _) = Native.Run("reg.exe", $"export \"{reg.HiveShort}\\{reg.SubPath}\" \"{file}\" /y /reg:64");
        return code == 0 && File.Exists(file);
    }

    private static string Safe(string s)
    {
        foreach (var c in Path.GetInvalidFileNameChars()) s = s.Replace(c, '_');
        return s.Length > 60 ? s[..60] : s;
    }

    /// <summary>Запускает штатный деинсталлятор программы и ждёт его завершения.</summary>
    public static async Task<string?> RunUninstaller(InstalledApp app)
    {
        var cmd = app.UninstallString?.Trim();
        if (string.IsNullOrEmpty(cmd)) return "У программы нет деинсталлятора.";

        // MsiExec /I{GUID} открывает «Изменить», а нам нужно удаление
        if (cmd.StartsWith("MsiExec", StringComparison.OrdinalIgnoreCase))
            cmd = System.Text.RegularExpressions.Regex.Replace(cmd, @"/I\s*\{", "/X{", System.Text.RegularExpressions.RegexOptions.IgnoreCase);

        try
        {
            var psi = new ProcessStartInfo("cmd.exe", "/c \"" + cmd + "\"") { UseShellExecute = false, CreateNoWindow = true };
            using var p = Process.Start(psi);
            if (p is null) return "Не удалось запустить деинсталлятор.";
            await p.WaitForExitAsync();
            // Многие деинсталляторы копируют себя во временную папку и сразу выходят — дадим им немного времени
            await Task.Delay(1500);
            return null;
        }
        catch (Exception e) { return e.Message; }
    }
}
