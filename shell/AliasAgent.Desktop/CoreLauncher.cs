using System.Diagnostics;
using System.Globalization;
using System.Text;

namespace AliasAgent.Desktop;

/// <summary>要启动的核心进程（命令行已拼好、工作目录已定）。</summary>
public sealed class CoreCommand
{
    /// <summary>进程可执行文件：`dart.exe` 直启，或批处理分支的 `cmd.exe`。</summary>
    public required string FileName { get; init; }

    /// <summary>`cmd.exe /C` 分支的整段命令（直启分支为 null）。</summary>
    public string? Arguments { get; init; }

    /// <summary>直启分支的逐参数清单（由运行时负责引号；`cmd` 分支为 null）。</summary>
    public IReadOnlyList<string>? ArgumentList { get; init; }

    /// <summary>工作目录（必须是仓库根：sidecar 以裸名字加载）。</summary>
    public required string WorkingDirectory { get; init; }

    /// <summary>日志里记录的**实际命令行**（只记录、不执行，便于事后核对引号）。</summary>
    public required string PreviewText { get; init; }

    /// <summary>核心将监听的端口（礼停请求用它）。</summary>
    public required int Port { get; init; }

    /// <summary>
    /// 额外的子进程环境变量（自检把 `USERPROFILE` 指向临时目录，保证不碰用户数据）。
    /// </summary>
    public IReadOnlyDictionary<string, string>? Environment { get; init; }
}

/// <summary>
/// 构造核心启动命令（change `windows-desktop-shell` D3 / 任务 3.7）。
///
/// 两条分支（`cmd.exe /C` 会把后整段再解析一次，这是唯一容易静默出错的地方）：
///   - 直启（`dart.exe`）：用 `ArgumentList` 逐个加参，引号交给运行时；
///   - 批处理（`dart.bat` / `dart.cmd`）：`cmd.exe /C ""&lt;dart 路径&gt;" run … "&lt;路径&gt;""`
///     —— **外层再多一层引号**（`/C` 的特例规则），含空格的路径各自加引号。
///
/// 我们传给核心的路径在拼接前先断言**不含双引号**：出现即报错退出，宁可不启动，
/// 也不要拼出一条没被验证过的命令行。
/// </summary>
public static class CoreCommandBuilder
{
    /// <summary>核心入口脚本（相对仓库根）。</summary>
    public const string CoreScriptRelative = "bin/alias_agent_core.dart";

    public static CoreCommand Build(
        DartExecutable dart,
        string repoRoot,
        int port,
        string configPath,
        IReadOnlyDictionary<string, string>? environment = null,
        string? lockPath = null)
    {
        if (dart == null) throw new ArgumentNullException(nameof(dart));
        RejectDoubleQuote("仓库根", repoRoot);
        RejectDoubleQuote("配置文件路径", configPath);
        if (lockPath != null) RejectDoubleQuote("单实例锁路径", lockPath);

        var portText = port.ToString(CultureInfo.InvariantCulture);
        var arguments = new List<string>
        {
            "run",
            CoreScriptRelative,
            "--port",
            portText,
            "--config",
            configPath,
        };
        if (lockPath != null)
        {
            arguments.Add("--lock");
            arguments.Add(lockPath);
        }

        if (!dart.RequiresCmdWrapper)
        {
            var preview = dart.Path + " " +
                          string.Join(" ", arguments.Select(QuoteIfNeeded));
            return new CoreCommand
            {
                FileName = dart.Path,
                ArgumentList = arguments,
                WorkingDirectory = repoRoot,
                PreviewText = preview,
                Port = port,
                Environment = environment,
            };
        }

        // `cmd.exe /C` 分支：整段命令外面再加一层引号。
        var trailing = lockPath == null
            ? Array.Empty<string>()
            : new[] { "--lock", QuoteIfNeeded(lockPath) };
        var inner = QuoteIfNeeded(dart.Path) + " " +
                    string.Join(" ", new[]
                    {
                        "run",
                        CoreScriptRelative,
                        "--port",
                        portText,
                        "--config",
                        QuoteIfNeeded(configPath),
                    }.Concat(trailing));
        var commandLine = "/C \"" + inner + "\"";
        return new CoreCommand
        {
            FileName = "cmd.exe",
            Arguments = commandLine,
            WorkingDirectory = repoRoot,
            PreviewText = "cmd.exe " + commandLine,
            Port = port,
            Environment = environment,
        };
    }

    private static string QuoteIfNeeded(string value) =>
        value.Contains(' ') ? "\"" + value + "\"" : value;

    private static void RejectDoubleQuote(string what, string value)
    {
        if (value.Contains('"'))
        {
            throw new CoreCommandException(
                $"{what}含双引号，拒绝拼命令行（无法验证引号是否正确）：\"{value}\"。" +
                "把它换成一个不含双引号的路径。");
        }
    }
}

/// <summary>命令行无法安全构造（例如路径里含双引号）。</summary>
public sealed class CoreCommandException : Exception
{
    public CoreCommandException(string message) : base(message)
    {
    }
}

/// <summary>
/// 核心输出解码（任务 3.7）：按行切、按 **UTF-8** 解码。
///
/// Windows 控制台默认代码页会把中文打成乱码，所以必须显式 UTF-8；而 `cmd.exe`
/// 自己的本地化错误行是 GBK —— 解码失败走 `allowMalformed` 兜底并**在该行标注
/// 「解码失败已替换」**，不许静默丢行（丢行等于日志不可观察）。
/// </summary>
public sealed class CoreOutputDecoder
{
    /// <summary>非法字节序列的可见标记（测试与用户文档都读它）。</summary>
    public const string ReplacementMarker = "（解码失败已替换）";

    private static readonly UTF8Encoding Strict = new(encoderShouldEmitUTF8Identifier: false, throwOnInvalidBytes: true);
    private static readonly UTF8Encoding Lenient = new(encoderShouldEmitUTF8Identifier: false, throwOnInvalidBytes: false);

    private readonly List<byte> _pending = new();

    /// <summary>吃一段字节，返回已经完整（以 `\n` 结尾）的行。</summary>
    public IReadOnlyList<string> Push(byte[] buffer, int offset, int count)
    {
        var lines = new List<string>();
        for (var i = 0; i < count; i++)
        {
            var value = buffer[offset + i];
            if (value == (byte)'\n')
            {
                lines.Add(DecodeLine());
                _pending.Clear();
            }
            else
            {
                _pending.Add(value);
            }
        }

        return lines;
    }

    /// <summary>收尾：把没有换行符的最后一行也吐出来（非空才吐）。</summary>
    public IReadOnlyList<string> Flush()
    {
        if (_pending.Count == 0) return Array.Empty<string>();
        var line = DecodeLine();
        _pending.Clear();
        return new[] { line };
    }

    private string DecodeLine()
    {
        var bytes = _pending.ToArray();
        var length = bytes.Length;
        if (length > 0 && bytes[length - 1] == (byte)'\r') length--;
        try
        {
            return Strict.GetString(bytes, 0, length);
        }
        catch (DecoderFallbackException)
        {
            return Lenient.GetString(bytes, 0, length) + ReplacementMarker;
        }
    }
}

/// <summary>停止核心的结果（正常路径 / 礼停超时杀树 / 极端兜底都在这里可见）。</summary>
public sealed class CoreStopReport
{
    /// <summary>是否发过礼停请求。</summary>
    public bool GracefulRequested { get; set; }

    /// <summary>进程是否已经退出。</summary>
    public bool Exited { get; set; }

    /// <summary>是否动用了 `Kill(entireProcessTree: true)`。</summary>
    public bool KilledTree { get; set; }

    /// <summary>极端兜底：礼停与杀树都失败，进程仍活着。</summary>
    public bool ExtremeFallback { get; set; }

    /// <summary>极端兜底时的 pid（气泡与日志要点名它）。</summary>
    public int? StillRunningPid { get; set; }

    /// <summary>进程退出码（拿不到时为 null）。</summary>
    public int? ExitCode { get; set; }

    public string Describe() =>
        $"GracefulRequested={GracefulRequested} Exited={Exited} KilledTree={KilledTree} " +
        $"ExtremeFallback={ExtremeFallback} Pid={StillRunningPid} ExitCode={ExitCode}";
}

/// <summary>
/// 核心子进程启动器（change `windows-desktop-shell` D3 / 任务 3.7）。
///
/// 职责：按 <see cref="CoreCommand"/> 起进程（工作目录 = 仓库根）、把 stdout/stderr
/// 按 UTF-8 逐行写日志、`StopAsync()` **先礼停、超时再杀进程树**。
///
/// 接缝：命令、超时、日志落点、礼停发送器全部注入 —— 测试用假 WS + 短超时 + 长命
/// 子进程（`ping -n 30`）验证「停止后进程确实没了」。
/// </summary>
public sealed class CoreLauncher
{
    private readonly Action<string> _log;
    private readonly Func<int, TimeSpan, CancellationToken, Task<bool>>? _gracefulStop;
    private readonly TimeSpan _gracefulStopTimeout;
    private readonly TimeSpan _killTimeout;
    private readonly List<Task> _pumps = new();
    private bool _stopRequested;

    public CoreLauncher(
        CoreCommand command,
        Action<string> log,
        Func<int, TimeSpan, CancellationToken, Task<bool>>? gracefulStop = null,
        TimeSpan? gracefulStopTimeout = null,
        TimeSpan? killTimeout = null)
    {
        Command = command;
        _log = log ?? throw new ArgumentNullException(nameof(log));
        _gracefulStop = gracefulStop;
        _gracefulStopTimeout = gracefulStopTimeout ?? TimeSpan.FromMilliseconds(5000);
        _killTimeout = killTimeout ?? TimeSpan.FromMilliseconds(5000);
    }

    public CoreCommand Command { get; }

    /// <summary>已启动的子进程（未启动为 null）。</summary>
    public Process? Process { get; private set; }

    /// <summary>
    /// 核心输出的最后一行（启动失败对话框要写它：一行，不是阈值）。
    /// 只记录 stdout/stderr 的解码结果，不含 `[core:*]` 前缀。
    /// </summary>
    public string? LastOutputLine { get; private set; }

    /// <summary>非预期退出（不是我们要求停的）：4.2 的崩溃态用它。</summary>
    public event Action<int>? UnexpectedExit;

    /// <summary>启动核心子进程（重定向输出、按 UTF-8 逐行进日志）。</summary>
    public Process Start()
    {
        var startInfo = new ProcessStartInfo
        {
            FileName = Command.FileName,
            WorkingDirectory = Command.WorkingDirectory,
            UseShellExecute = false,
            CreateNoWindow = true,
            RedirectStandardOutput = true,
            RedirectStandardError = true,
        };
        if (Command.ArgumentList != null)
        {
            foreach (var argument in Command.ArgumentList) startInfo.ArgumentList.Add(argument);
        }
        else
        {
            startInfo.Arguments = Command.Arguments ?? string.Empty;
        }

        if (Command.Environment != null)
        {
            foreach (var pair in Command.Environment)
            {
                startInfo.Environment[pair.Key] = pair.Value;
            }
        }

        _log($"[shell] 启动核心：{Command.PreviewText}（工作目录={Command.WorkingDirectory}）");
        var process = new Process { StartInfo = startInfo, EnableRaisingEvents = true };
        process.Exited += (_, _) =>
        {
            var exitCode = TryGetExitCode(process);
            _log($"[shell] 核心进程已退出（pid={SafePid(process)}，exit={exitCode}）");
            if (!_stopRequested) UnexpectedExit?.Invoke(exitCode ?? -1);
        };
        if (!process.Start())
        {
            throw new InvalidOperationException($"核心进程启动失败：{Command.PreviewText}");
        }

        Process = process;
        _log($"[shell] 核心 pid={process.Id}");
        _pumps.Add(PumpAsync(process.StandardOutput.BaseStream, "out"));
        _pumps.Add(PumpAsync(process.StandardError.BaseStream, "err"));
        return process;
    }

    /// <summary>
    /// 停止核心：先礼停（`core.shutdown`），在 <see cref="_gracefulStopTimeout"/> 内没退出
    /// 就 `Kill(entireProcessTree: true)`，再等 <see cref="_killTimeout"/> 确认。
    /// </summary>
    public async Task<CoreStopReport> StopAsync(CancellationToken cancellationToken = default)
    {
        _stopRequested = true;
        var report = new CoreStopReport();
        var process = Process;
        if (process == null)
        {
            report.Exited = true;
            return report;
        }

        if (process.HasExited)
        {
            report.Exited = true;
            report.ExitCode = TryGetExitCode(process);
            return report;
        }

        var stopwatch = Stopwatch.StartNew();
        if (_gracefulStop != null)
        {
            report.GracefulRequested = true;
            try
            {
                using var timeoutCts = CancellationTokenSource.CreateLinkedTokenSource(cancellationToken);
                timeoutCts.CancelAfter(_gracefulStopTimeout);
                var accepted = await _gracefulStop(Command.Port, _gracefulStopTimeout, timeoutCts.Token)
                    .ConfigureAwait(false);
                _log($"[shell] 礼停请求已发出（accepted={accepted}，上限={_gracefulStopTimeout.TotalMilliseconds}ms）");
            }
            catch (Exception e)
            {
                _log($"[shell] 礼停请求失败或超时：{e.Message}");
            }
        }

        var remaining = _gracefulStopTimeout - stopwatch.Elapsed;
        if (remaining < TimeSpan.Zero) remaining = TimeSpan.Zero;
        if (await WaitForExitAsync(process, remaining).ConfigureAwait(false))
        {
            report.Exited = true;
            report.ExitCode = TryGetExitCode(process);
            _log($"[shell] 核心已礼停退出（pid={SafePid(process)}，exit={report.ExitCode}）");
            return report;
        }

        _log($"[shell] 核心在礼停上限 {_gracefulStopTimeout.TotalMilliseconds}ms 内没有退出，" +
             $"终止进程树（pid={SafePid(process)}）");
        try
        {
            process.Kill(entireProcessTree: true);
            report.KilledTree = true;
        }
        catch (Exception e)
        {
            _log($"[shell] 终止进程树失败（pid={SafePid(process)}）：{e.Message}");
        }

        if (await WaitForExitAsync(process, _killTimeout).ConfigureAwait(false))
        {
            report.Exited = true;
            report.ExitCode = TryGetExitCode(process);
            _log($"[shell] 进程树已终止（pid={SafePid(process)}）");
            return report;
        }

        report.ExtremeFallback = true;
        report.StillRunningPid = SafePid(process);
        _log($"[shell] 未能终止核心（pid={SafePid(process)}，礼停上限={_gracefulStopTimeout.TotalMilliseconds}ms，" +
             $"杀树确认上限={_killTimeout.TotalMilliseconds}ms）：按极端兜底退出");
        return report;
    }

    private static async Task<bool> WaitForExitAsync(Process process, TimeSpan timeout)
    {
        if (process.HasExited) return true;
        if (timeout <= TimeSpan.Zero) return process.HasExited;
        using var cts = new CancellationTokenSource(timeout);
        try
        {
            await process.WaitForExitAsync(cts.Token).ConfigureAwait(false);
            return true;
        }
        catch (OperationCanceledException)
        {
            return process.HasExited;
        }
    }

    private async Task PumpAsync(Stream stream, string channel)
    {
        var decoder = new CoreOutputDecoder();
        var buffer = new byte[4096];
        try
        {
            while (true)
            {
                var read = await stream.ReadAsync(buffer, 0, buffer.Length).ConfigureAwait(false);
                if (read == 0) break;
                foreach (var line in decoder.Push(buffer, 0, read))
                {
                    LastOutputLine = line;
                    _log($"[core:{channel}] {line}");
                }
            }

            foreach (var line in decoder.Flush())
            {
                LastOutputLine = line;
                _log($"[core:{channel}] {line}");
            }
        }
        catch (Exception e)
        {
            _log($"[shell] 读取核心 {channel} 输出失败：{e.Message}");
        }
    }

    private static int? TryGetExitCode(Process process)
    {
        try
        {
            return process.HasExited ? process.ExitCode : null;
        }
        catch
        {
            return null;
        }
    }

    private static int SafePid(Process process)
    {
        try
        {
            return process.Id;
        }
        catch
        {
            return -1;
        }
    }
}
