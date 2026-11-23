using System.Windows;
using System.Windows.Threading;

namespace Uproot;

public partial class App : Application
{
    protected override void OnStartup(StartupEventArgs e)
    {
        DispatcherUnhandledException += OnError;
        Settings.ApplyTheme(Settings.Load().Theme);
        base.OnStartup(e);
    }

    private static void OnError(object sender, DispatcherUnhandledExceptionEventArgs e)
    {
        MessageBox.Show(e.Exception.Message, "Uproot — ошибка", MessageBoxButton.OK, MessageBoxImage.Error);
        e.Handled = true;
    }
}
