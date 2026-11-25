using System.Windows.Forms;

namespace AliasAgent.Desktop;

/// <summary>
/// 壳的入口（change `windows-desktop-shell` 任务 4.2）。
///
/// 顺序（不许调换）：
///   1. 解析选项（参数错误 → 打印用法 + 退出码 2）；
///   2. `--help` → 打印用法、退出 0；
///   3. **`--selftest` 在取互斥体之前分流**（自检不与用户的壳抢单实例，4.4 接入）；
///   4. 取壳的单实例互斥体：第二个实例通知第一个实例后自己退出 0；
///   5. 第一个实例跑消息循环（托盘 + 窗口 + 核心生命周期）。
/// </summary>
internal static class Program
{
    /// <summary>参数错误退出码（与核心一致：1 = 启动失败，2 = 参数错误，3 = 停机告警）。</summary>
    private const int ExitCodeOptionError = 2;

    [STAThread]
    private static int Main(string[] args)
    {
        // 输出编码：WinExe 没有自带控制台时 .NET 的控制台编码可能退化成 ASCII，
        // 中文会变成 '?'（日志不可读）。显式 UTF-8，让 `--help` / `--selftest` 可观察。
        try
        {
            Console.OutputEncoding = new System.Text.UTF8Encoding(encoderShouldEmitUTF8Identifier: false);
        }
        catch
        {
            // 没有控制台句柄时设置会抛：忽略（此时本来也没人读输出）。
        }

        DesktopOptions options;
        try
        {
            options = DesktopOptions.Parse(args);
        }
        catch (DesktopOptionException e)
        {
            Console.Error.WriteLine(e.Message);
            Console.Error.WriteLine();
            Console.Error.Write(DesktopOptions.Usage);
            return ExitCodeOptionError;
        }

        if (options.Help)
        {
            Console.Out.WriteLine(DesktopOptions.Usage);
            return 0;
        }

        // 自检：不取壳互斥体、不建窗口/托盘、不读用户配置（任务 4.4）。
        if (options.SelfTest)
        {
            return SelfTestRunner.Run(options);
        }

        Application.EnableVisualStyles();
        Application.SetCompatibleTextRenderingDefault(false);
        try
        {
            Application.SetHighDpiMode(HighDpiMode.SystemAware);
        }
        catch
        {
            // 某些宿主不允许改 DPI 模式：不影响功能。
        }

        using var logger = new ShellLogger(ShellPaths.LogPath);
        using var singleInstance = new SingleInstance(logger.Write, new Win32WindowActivator());
        if (!singleInstance.IsFirst)
        {
            // 第二实例：允许第一个实例抢前台 → 置「打开窗口」事件 → 自己退出 0。
            singleInstance.NotifyExistingInstance();
            logger.Write("[shell] 本进程是第二个实例：已把「打开窗口」请求转给第一个实例，退出 0");
            return 0;
        }

        var app = new ShellApplication(options, singleInstance, logger);
        Application.Run(app);
        return Environment.ExitCode;
    }
}
