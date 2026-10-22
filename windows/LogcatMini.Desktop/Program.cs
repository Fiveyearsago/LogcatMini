using Avalonia;
using Avalonia.Controls.ApplicationLifetimes;
using Avalonia.Themes.Fluent;
namespace LogcatMini.Desktop;
internal static class Program
{
    [STAThread] public static void Main(string[] args){if(args.FirstOrDefault()=="--record-worker"){Environment.ExitCode=LogcatMini.Core.RecordingWorker.Run(args).GetAwaiter().GetResult();return;}AppBuilder.Configure<App>().UsePlatformDetect().LogToTrace().StartWithClassicDesktopLifetime(args);}
}
public sealed class App : Application
{
    public override void Initialize()=>Styles.Add(new FluentTheme());
    public override void OnFrameworkInitializationCompleted()
    {
        if(ApplicationLifetime is IClassicDesktopStyleApplicationLifetime desktop)desktop.MainWindow=new MainWindow(desktop.Args??[]);
        base.OnFrameworkInitializationCompleted();
    }
}
