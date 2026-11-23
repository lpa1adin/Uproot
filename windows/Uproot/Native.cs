using System.Diagnostics;
using System.IO;
using System.Runtime.InteropServices;
using System.Windows;
using System.Windows.Interop;
using System.Windows.Media;
using System.Windows.Media.Imaging;
using Microsoft.Win32;

namespace Uproot;

internal static class Native
{
    // ---------- Корзина ----------

    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    private struct SHFILEOPSTRUCT
    {
        public IntPtr hwnd;
        public uint wFunc;
        public string pFrom;
        public string? pTo;
        public ushort fFlags;
        [MarshalAs(UnmanagedType.Bool)] public bool fAnyOperationsAborted;
        public IntPtr hNameMappings;
        public string? lpszProgressTitle;
    }

    [DllImport("shell32.dll", CharSet = CharSet.Unicode)]
    private static extern int SHFileOperation(ref SHFILEOPSTRUCT op);

    private const uint FO_DELETE = 3;
    private const ushort FOF_SILENT = 0x4, FOF_NOCONFIRMATION = 0x10, FOF_ALLOWUNDO = 0x40, FOF_NOERRORUI = 0x400;

    /// <summary>Переносит файл или папку в Корзину (можно восстановить).</summary>
    public static bool Recycle(string path)
    {
        var op = new SHFILEOPSTRUCT
        {
            wFunc = FO_DELETE,
            pFrom = path + "\0\0",
            fFlags = FOF_ALLOWUNDO | FOF_NOCONFIRMATION | FOF_SILENT | FOF_NOERRORUI,
        };
        int r = SHFileOperation(ref op);
        return r == 0 && !op.fAnyOperationsAborted && !File.Exists(path) && !Directory.Exists(path);
    }

    // ---------- Иконки ----------

    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    private struct SHFILEINFO
    {
        public IntPtr hIcon;
        public int iIcon;
        public uint dwAttributes;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 260)] public string szDisplayName;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 80)] public string szTypeName;
    }

    [DllImport("shell32.dll", CharSet = CharSet.Unicode)]
    private static extern IntPtr SHGetFileInfo(string pszPath, uint dwFileAttributes, ref SHFILEINFO psfi, uint cbFileInfo, uint uFlags);

    [DllImport("user32.dll")]
    private static extern bool DestroyIcon(IntPtr hIcon);

    private const uint SHGFI_ICON = 0x100, SHGFI_LARGEICON = 0x0;

    public static ImageSource? IconOf(string? path)
    {
        if (string.IsNullOrWhiteSpace(path) || !File.Exists(path)) return null;
        var info = new SHFILEINFO();
        var res = SHGetFileInfo(path, 0, ref info, (uint)Marshal.SizeOf<SHFILEINFO>(), SHGFI_ICON | SHGFI_LARGEICON);
        if (res == IntPtr.Zero || info.hIcon == IntPtr.Zero) return null;
        try
        {
            var src = Imaging.CreateBitmapSourceFromHIcon(info.hIcon, Int32Rect.Empty, BitmapSizeOptions.FromEmptyOptions());
            src.Freeze();
            return src;
        }
        catch { return null; }
        finally { DestroyIcon(info.hIcon); }
    }

    // ---------- Ярлыки ----------

    public static string? ShortcutTarget(string lnk)
    {
        try
        {
            var t = Type.GetTypeFromProgID("WScript.Shell");
            if (t is null) return null;
            dynamic shell = Activator.CreateInstance(t)!;
            dynamic sc = shell.CreateShortcut(lnk);
            string target = sc.TargetPath;
            Marshal.FinalReleaseComObject(sc);
            Marshal.FinalReleaseComObject(shell);
            return target;
        }
        catch { return null; }
    }

    // ---------- Процессы ----------

    public static (int Code, string Output) Run(string file, string args)
    {
        try
        {
            var psi = new ProcessStartInfo(file, args)
            {
                UseShellExecute = false,
                CreateNoWindow = true,
                RedirectStandardOutput = true,
                RedirectStandardError = true,
            };
            using var p = Process.Start(psi)!;
            string output = p.StandardOutput.ReadToEnd() + p.StandardError.ReadToEnd();
            p.WaitForExit();
            return (p.ExitCode, output);
        }
        catch (Exception e) { return (-1, e.Message); }
    }

    public static void ShowInExplorer(string path)
    {
        if (File.Exists(path) || Directory.Exists(path))
            Process.Start("explorer.exe", $"/select,\"{path}\"");
        else if (Path.GetDirectoryName(path) is { } dir && Directory.Exists(dir))
            Process.Start("explorer.exe", $"\"{dir}\"");
    }

    /// <summary>Открывает редактор реестра сразу на нужном ключе.</summary>
    public static void ShowInRegedit(RegLocation reg)
    {
        try
        {
            using var k = Registry.CurrentUser.CreateSubKey(@"Software\Microsoft\Windows\CurrentVersion\Applets\Regedit");
            k.SetValue("LastKey", "Компьютер\\" + reg.HiveLong + "\\" + reg.SubPath);
            Process.Start(new ProcessStartInfo("regedit.exe", "/m") { UseShellExecute = true });
        }
        catch { }
    }
}

/// <summary>Стандартные места Windows, где программы оставляют следы.</summary>
public static class Places
{
    private static string F(Environment.SpecialFolder f) => Environment.GetFolderPath(f);

    public static readonly string Windows = F(Environment.SpecialFolder.Windows);
    public static readonly string ProgramFiles = F(Environment.SpecialFolder.ProgramFiles);
    public static readonly string ProgramFilesX86 = F(Environment.SpecialFolder.ProgramFilesX86);
    public static readonly string ProgramData = F(Environment.SpecialFolder.CommonApplicationData);
    public static readonly string AppData = F(Environment.SpecialFolder.ApplicationData);
    public static readonly string LocalAppData = F(Environment.SpecialFolder.LocalApplicationData);
    public static readonly string UserProfile = F(Environment.SpecialFolder.UserProfile);
    public static readonly string LocalLow = Path.Combine(UserProfile, "AppData", "LocalLow");
    public static readonly string UserPrograms = Path.Combine(LocalAppData, "Programs");
    public static readonly string StartMenu = Path.Combine(F(Environment.SpecialFolder.StartMenu), "Programs");
    public static readonly string CommonStartMenu = Path.Combine(F(Environment.SpecialFolder.CommonStartMenu), "Programs");
    public static readonly string Desktop = F(Environment.SpecialFolder.DesktopDirectory);
    public static readonly string CommonDesktop = F(Environment.SpecialFolder.CommonDesktopDirectory);
    public static readonly string Tasks = Path.Combine(Windows, "System32", "Tasks");

    /// <summary>Корни, внутри которых ищутся папки программ, и их категория.</summary>
    public static IEnumerable<(string Dir, Category Cat)> FolderRoots()
    {
        yield return (ProgramFiles, Category.Program);
        if (!string.Equals(ProgramFiles, ProgramFilesX86, StringComparison.OrdinalIgnoreCase))
            yield return (ProgramFilesX86, Category.Program);
        yield return (UserPrograms, Category.Program);
        yield return (ProgramData, Category.AppData);
        yield return (AppData, Category.AppData);
        yield return (LocalAppData, Category.AppData);
        yield return (LocalLow, Category.AppData);
    }

    public static string[] ShortcutRoots => [StartMenu, CommonStartMenu, Desktop, CommonDesktop];

    public static Category Classify(string path)
    {
        bool Under(string root) => path.StartsWith(root + "\\", StringComparison.OrdinalIgnoreCase);
        if (Under(ProgramFiles) || Under(ProgramFilesX86) || Under(UserPrograms)) return Category.Program;
        if (ShortcutRoots.Any(Under)) return Category.Shortcuts;
        if (Under(AppData) || Under(LocalAppData) || Under(ProgramData) || Under(LocalLow)) return Category.AppData;
        return Category.Other;
    }
}

/// <summary>Защита от удаления системных и общих мест.</summary>
public static class Guard
{
    private static readonly HashSet<string> RootPaths = BuildRoots();

    private static HashSet<string> BuildRoots()
    {
        var s = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
        foreach (Environment.SpecialFolder f in Enum.GetValues<Environment.SpecialFolder>())
        {
            var p = Environment.GetFolderPath(f);
            if (!string.IsNullOrEmpty(p)) s.Add(p.TrimEnd('\\'));
        }
        foreach (var p in new[] { Places.LocalLow, Places.UserPrograms, Places.StartMenu, Places.CommonStartMenu, Places.Tasks,
                                  Path.Combine(Places.UserProfile, "Downloads"), Path.GetDirectoryName(Places.UserProfile) ?? "",
                                  Path.Combine(Places.ProgramFiles, "Common Files"), Path.Combine(Places.ProgramFilesX86, "Common Files"),
                                  Path.Combine(Places.ProgramFiles, "WindowsApps"), Path.Combine(Places.LocalAppData, "Temp"),
                                  Path.Combine(Places.LocalAppData, "Microsoft"), Path.Combine(Places.AppData, "Microsoft"),
                                  Path.Combine(Places.ProgramData, "Microsoft"), Path.Combine(Places.LocalAppData, "Packages") })
            if (!string.IsNullOrEmpty(p)) s.Add(p.TrimEnd('\\'));
        foreach (var d in DriveInfo.GetDrives()) s.Add(d.RootDirectory.FullName.TrimEnd('\\'));
        return s;
    }

    public static bool IsProtectedPath(string path)
    {
        if (string.IsNullOrWhiteSpace(path)) return true;
        string p;
        try { p = Path.GetFullPath(path).TrimEnd('\\'); } catch { return true; }
        if (p.Length <= 3 || RootPaths.Contains(p)) return true;
        if (p.StartsWith(Places.Windows + "\\", StringComparison.OrdinalIgnoreCase)) return true;
        return false;
    }

    private static readonly HashSet<string> ProtectedTopKeys = new(StringComparer.OrdinalIgnoreCase)
    {
        "Microsoft", "Classes", "Policies", "Windows", "Clients", "RegisteredApplications", "WOW6432Node",
        "Wow6432Node", "Intel", "ODBC", "Khronos", "Partner", "OEM", "DefaultUserEnvironment", "Setup",
    };

    private const string UninstallPrefix = @"Microsoft\Windows\CurrentVersion\Uninstall\";

    public static bool IsProtectedKey(RegLocation reg)
    {
        var parts = reg.SubPath.Split('\\', StringSplitOptions.RemoveEmptyEntries);
        if (parts.Length < 2) return true;
        if (!parts[0].Equals("SOFTWARE", StringComparison.OrdinalIgnoreCase)) return true;
        int i = 1;
        if (parts[1].Equals("WOW6432Node", StringComparison.OrdinalIgnoreCase)) i = 2;
        if (parts.Length <= i) return true;
        var rest = string.Join("\\", parts.Skip(i));
        // Запись программы в «Установленных приложениях» удалять можно
        if (rest.StartsWith(UninstallPrefix, StringComparison.OrdinalIgnoreCase) && parts.Length == i + 5) return false;
        return ProtectedTopKeys.Contains(parts[i]);
    }
}
