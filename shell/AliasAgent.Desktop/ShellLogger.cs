namespace AliasAgent.Desktop;

/// <summary>壳用到的固定路径（change `windows-desktop-shell` D7 / D4）。</summary>
public static class ShellPaths
{
    /// <summary>用户主目录（`%USERPROFILE%`）。</summary>
    public static string UserHome =>
        Environment.GetFolderPath(Environment.SpecialFolder.UserProfile);

    /// <summary>产品配置目录（`~/.aliasagent`，与 Flutter / 核心共用同一份）。</summary>
    public static string ConfigDir => Path.Combine(UserHome, ".aliasagent");

    /// <summary>配置文件路径（与 `CorePortResolver.DefaultConfigPath` 同源）。</summary>
    public static string ConfigPath => Path.Combine(ConfigDir, "config.json");

    /// <summary>壳日志路径（与 `sidecar.log` 同目录，产品既有约定）。</summary>
    public static string LogPath => Path.Combine(ConfigDir, "logs", "desktop-shell.log");

    /// <summary>
    /// WebView2 用户数据目录：放**本机应用数据**目录，不放 `~/.aliasagent`
    /// （避免浏览器缓存与配置/数据库混放，也便于整目录删除）。
    /// </summary>
    public static string WebView2UserDataFolder => Path.Combine(
        Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData),
        "AliasAgent",
        "WebView2");
}

/// <summary>
/// 壳的日志落点（可注入：生产 = 文件，自检 = 临时目录，测试 = 内存）。
///
/// 事件按行写（解析到的仓库根/端口/配置、实际命令行、就绪探测结果、停机与退出码、
/// 崩溃原因、Job Object 关联结果）。首版不做日志轮转（已写进已知限制）。
/// </summary>
public sealed class ShellLogger : IDisposable
{
    private readonly object _gate = new();
    private readonly StreamWriter? _writer;
    private readonly bool _echoToConsole;
    private bool _disposed;

    public ShellLogger(string logPath, bool echoToConsole = false)
    {
        LogPath = logPath;
        _echoToConsole = echoToConsole;
        try
        {
            var directory = Path.GetDirectoryName(logPath);
            if (!string.IsNullOrEmpty(directory)) Directory.CreateDirectory(directory);
            _writer = new StreamWriter(new FileStream(
                logPath, FileMode.Append, FileAccess.Write, FileShare.ReadWrite))
            {
                AutoFlush = true,
            };
        }
        catch (Exception e)
        {
            // 日志写不了不该挡住壳启动：退回「只写控制台」并声明这件事。
            Console.Error.WriteLine($"无法打开壳日志 {logPath}：{e.Message}");
            _writer = null;
        }
    }

    public string LogPath { get; }

    public void Write(string line)
    {
        var text = $"{DateTime.Now:yyyy-MM-dd HH:mm:ss.fff} {line}";
        lock (_gate)
        {
            if (_disposed) return;
            try
            {
                _writer?.WriteLine(text);
            }
            catch
            {
                // 写失败不抛：日志不是产品路径的一部分。
            }

            if (_echoToConsole) Console.Out.WriteLine(text);
        }
    }

    public void Dispose()
    {
        lock (_gate)
        {
            if (_disposed) return;
            _disposed = true;
            try
            {
                _writer?.Dispose();
            }
            catch
            {
                // 已关闭。
            }
        }
    }
}
