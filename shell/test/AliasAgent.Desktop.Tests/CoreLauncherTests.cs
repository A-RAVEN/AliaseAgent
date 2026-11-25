using System.Diagnostics;
using System.Text;
using AliasAgent.Desktop;
using Xunit;
using Xunit.Abstractions;

namespace AliasAgent.Desktop.Tests;

/// <summary>
/// 任务 3.7：核心启动器。
///
/// 覆盖哪几件事（每条坏了都会红）：
///   1. 三种路径形态的**命令行**：直启无空格 / 直启含空格 / `cmd.exe /C` 双层引号；
///   2. 路径里含双引号 ⇒ 可归因报错（宁可不启动，也不拼一条没验证过的命令行）；
///   3. 输出按 UTF-8 解码（中文不乱码）、GBK 字节走 `allowMalformed` 且**该行标注
///      替换**（不许静默丢行）；
///   4. 工作目录 = 仓库根（真进程验证）；
///   5. `Stop()` 先礼停，礼停超时后杀进程树，且停止后子进程确实没了。
///
/// 命令 / 超时 / 日志落点全部注入。
/// </summary>
public class CoreLauncherTests
{
    private readonly ITestOutputHelper _output;
    private CoreLauncher? launcherRef;

    public CoreLauncherTests(ITestOutputHelper output)
    {
        _output = output;
    }

    // ---------------------------------------------------------------------
    // 1. 命令行构造
    // ---------------------------------------------------------------------

    [Fact]
    public void DirectExeCommandHasNoManualQuoting()
    {
        var dart = new DartExecutable(@"C:\flutter\bin\dart.exe", false);
        var command = CoreCommandBuilder.Build(
            dart, @"C:\repo", 9100, @"C:\repo\cfg.json");
        _output.WriteLine($"[CMD] FileName={command.FileName}");
        _output.WriteLine($"[CMD] ArgumentList=[{string.Join(" | ", command.ArgumentList ?? Array.Empty<string>())}]");
        _output.WriteLine($"[CMD] WorkingDirectory={command.WorkingDirectory}");
        _output.WriteLine($"[CMD] Preview={command.PreviewText}");

        Assert.Equal(@"C:\flutter\bin\dart.exe", command.FileName);
        Assert.Null(command.Arguments);
        Assert.Equal(@"C:\repo", command.WorkingDirectory);
        Assert.Equal(
            new[] { "run", "bin/alias_agent_core.dart", "--port", "9100", "--config", @"C:\repo\cfg.json" },
            command.ArgumentList);
    }

    [Fact]
    public void DirectExeWithSpacesKeepsOneArgumentPerToken()
    {
        var dart = new DartExecutable(@"C:\flutter\bin\dart.exe", false);
        var command = CoreCommandBuilder.Build(
            dart, @"C:\my repo", 9100, @"C:\my repo\cfg.json");
        _output.WriteLine($"[CMD] ArgumentList=[{string.Join(" | ", command.ArgumentList ?? Array.Empty<string>())}]");
        _output.WriteLine($"[CMD] Preview={command.PreviewText}");
        Assert.Equal(@"C:\my repo", command.WorkingDirectory);
        // 直启分支由运行时负责引号：每个路径是**一个** ArgumentList 元素，不带手写引号。
        Assert.Equal(@"C:\my repo\cfg.json", command.ArgumentList![5]);
        // 预览里含空格的路径要看得见引号（便于事后核对）。
        Assert.Contains("\"C:\\my repo\\cfg.json\"", command.PreviewText);
    }

    [Fact]
    public void BatchCommandGoesThroughCmdWithDoubleLayerQuotes()
    {
        var dart = new DartExecutable(@"C:\Program Files\Flutter\bin\dart.bat", true);
        var command = CoreCommandBuilder.Build(
            dart, @"C:\my repo", 9100, @"C:\my repo\cfg.json");
        _output.WriteLine($"[CMD] FileName={command.FileName}");
        _output.WriteLine($"[CMD] Arguments={command.Arguments}");
        _output.WriteLine($"[CMD] Preview={command.PreviewText}");

        Assert.Equal("cmd.exe", command.FileName, ignoreCase: true);
        Assert.Null(command.ArgumentList);
        // `/C` 的特例规则：整段命令外面再多一层引号。
        Assert.StartsWith("/C \"", command.Arguments);
        Assert.EndsWith("\"", command.Arguments);
        Assert.Contains("\"C:\\Program Files\\Flutter\\bin\\dart.bat\"", command.Arguments);
        Assert.Contains("run bin/alias_agent_core.dart", command.Arguments);
        Assert.Contains("--port 9100", command.Arguments);
        Assert.Contains("\"C:\\my repo\\cfg.json\"", command.Arguments);
        Assert.Equal(@"C:\my repo", command.WorkingDirectory);
    }

    [Fact]
    public void DoubleQuoteInPathsIsRejectedBeforeComposing()
    {
        var dart = new DartExecutable(@"C:\flutter\bin\dart.bat", true);
        var error = Assert.Throws<CoreCommandException>(() =>
            CoreCommandBuilder.Build(dart, @"C:\repo", 9100, "C:\\weird\"cfg.json"));
        _output.WriteLine($"[CMD] 路径含双引号 ⇒ {error.Message}");
        Assert.Contains("双引号", error.Message);
        Assert.Contains("cfg.json", error.Message);

        var rootError = Assert.Throws<CoreCommandException>(() =>
            CoreCommandBuilder.Build(dart, "C:\\re\"po", 9100, @"C:\repo\cfg.json"));
        _output.WriteLine($"[CMD] 仓库根含双引号 ⇒ {rootError.Message}");
        Assert.Contains("双引号", rootError.Message);
    }

    // ---------------------------------------------------------------------
    // 2. 输出解码（UTF-8 / GBK 兜底）
    // ---------------------------------------------------------------------

    [Fact]
    public void Utf8ChineseSurvivesChunkBoundaries()
    {
        var decoder = new CoreOutputDecoder();
        var bytes = Encoding.UTF8.GetBytes("核心启动完成：端口 9100\r\n第二行\n");
        var lines = new List<string>();
        // 故意从多字节字符中间切开。
        for (var i = 0; i < bytes.Length; i += 3)
        {
            var count = Math.Min(3, bytes.Length - i);
            lines.AddRange(decoder.Push(bytes, i, count));
        }
        lines.AddRange(decoder.Flush());
        _output.WriteLine($"[DECODE] 行=[{string.Join(" / ", lines)}]");
        Assert.Equal(new[] { "核心启动完成：端口 9100", "第二行" }, lines);
        Assert.DoesNotContain(CoreOutputDecoder.ReplacementMarker, string.Join("\n", lines));
    }

    [Fact]
    public void GbkBytesAreReplacedAndTheLineIsMarkedNotDropped()
    {
        var decoder = new CoreOutputDecoder();
        // GBK 的「错误」（0xB4 0xED 0xCE 0xF3）不是合法 UTF-8。
        var bytes = new byte[] { 0xB4, 0xED, 0xCE, 0xF3, (byte)'\n' };
        var lines = decoder.Push(bytes, 0, bytes.Length).ToList();
        lines.AddRange(decoder.Flush());
        _output.WriteLine($"[DECODE] GBK 行=[{string.Join(" / ", lines)}]");
        Assert.Single(lines);
        Assert.Contains(CoreOutputDecoder.ReplacementMarker, lines[0]);
        Assert.Contains('\uFFFD', lines[0]);
    }

    // ---------------------------------------------------------------------
    // 3. 真进程：工作目录与停止
    // ---------------------------------------------------------------------

    private static CoreCommand PingCommand(string workingDirectory, int seconds = 30)
    {
        return new CoreCommand
        {
            FileName = "ping.exe",
            ArgumentList = new[] { "-n", seconds.ToString(), "127.0.0.1" },
            WorkingDirectory = workingDirectory,
            PreviewText = $"ping.exe -n {seconds} 127.0.0.1",
            Port = 1,
        };
    }

    [Fact]
    public async Task WorkingDirectoryIsTheRepoRoot()
    {
        var dir = Directory.CreateTempSubdirectory("aliasagent_launcher_cwd_").FullName;
        var logs = new List<string>();
        var command = new CoreCommand
        {
            FileName = "cmd.exe",
            Arguments = "/C cd",
            WorkingDirectory = dir,
            PreviewText = "cmd.exe /C cd",
            Port = 1,
        };
        var launcher = new CoreLauncher(command, line =>
        {
            logs.Add(line);
        }, gracefulStop: (_, _, _) => Task.FromResult(true));
        try
        {
            var process = launcher.Start();
            await process.WaitForExitAsync().WaitAsync(TimeSpan.FromSeconds(30));
            await Task.Delay(300);
            _output.WriteLine($"[LAUNCHER] 子进程工作目录输出=[{string.Join(" / ", logs)}]");
            var coreLines = logs.Where(line => line.StartsWith("[core", StringComparison.Ordinal)).ToList();
            _output.WriteLine($"[LAUNCHER] core 输出行=[{string.Join(" / ", coreLines)}]");
            Assert.NotEmpty(coreLines);
            Assert.Contains(coreLines, line => line.Contains(dir, StringComparison.OrdinalIgnoreCase));
        }
        finally
        {
            await launcher.StopAsync().WaitAsync(TimeSpan.FromSeconds(30));
        }
    }

    [Fact]
    public async Task StopRequestsGracefulShutdownAndWaits()
    {
        var dir = Directory.CreateTempSubdirectory("aliasagent_launcher_grace_").FullName;
        var logs = new List<string>();
        var gracefulCalls = new List<int>();
        var launcher = new CoreLauncher(PingCommand(dir, 30), logs.Add,
            gracefulStop: (port, timeout, ct) =>
            {
                gracefulCalls.Add(port);
                // 模拟「核心自己走完停机并退出」：这里由被测进程自己结束。
                launcherRef!.Process!.Kill();
                return Task.FromResult(true);
            },
            gracefulStopTimeout: TimeSpan.FromMilliseconds(500),
            killTimeout: TimeSpan.FromSeconds(15));
        launcherRef = launcher;

        var process = launcher.Start();
        var pid = process.Id;
        var report = await launcher.StopAsync().WaitAsync(TimeSpan.FromSeconds(30));
        _output.WriteLine($"[LAUNCHER] 礼停报告：{report.Describe()}");
        _output.WriteLine($"[LAUNCHER] 礼停调用端口={string.Join(",", gracefulCalls)}");

        Assert.Equal(new[] { 1 }, gracefulCalls);
        Assert.True(report.GracefulRequested);
        Assert.True(report.Exited);
        Assert.False(report.KilledTree, "核心自己退了就不该再杀树");
        AssertEx.ProcessGone(pid);
    }

    [Fact]
    public async Task StopKillsProcessTreeWhenGracefulTimesOut()
    {
        var dir = Directory.CreateTempSubdirectory("aliasagent_launcher_kill_").FullName;
        var logs = new List<string>();
        var launcher = new CoreLauncher(PingCommand(dir, 30), logs.Add,
            // 假 WS：礼停永远等不到回应（超时被 launcher 控制）。
            gracefulStop: async (port, timeout, ct) =>
            {
                await Task.Delay(timeout, ct);
                return false;
            },
            gracefulStopTimeout: TimeSpan.FromMilliseconds(300),
            killTimeout: TimeSpan.FromSeconds(20));

        var process = launcher.Start();
        var pid = process.Id;
        var stopwatch = Stopwatch.StartNew();
        var report = await launcher.StopAsync().WaitAsync(TimeSpan.FromSeconds(40));
        stopwatch.Stop();
        _output.WriteLine($"[LAUNCHER] 杀树报告：{report.Describe()} 用时={stopwatch.ElapsedMilliseconds}ms");
        _output.WriteLine($"[LAUNCHER] 日志尾=[{string.Join(" / ", logs.TakeLast(5))}]");

        Assert.True(report.GracefulRequested);
        Assert.True(report.KilledTree, "礼停超时后必须 Kill(entireProcessTree: true)");
        Assert.True(report.Exited);
        AssertEx.ProcessGone(pid);
    }
}

/// <summary>测试内部的断言辅助。</summary>
public static class AssertEx
{
    /// <summary>断言进程确实没了：`GetProcessById` 抛 ArgumentException 即「不在」。 </summary>
    public static void ProcessGone(int pid)
    {
        Process? process = null;
        try
        {
            process = Process.GetProcessById(pid);
        }
        catch (ArgumentException)
        {
            return; // 期望路径：进程已经不在了。
        }

        try
        {
            Assert.True(process.HasExited, $"进程 {pid} 仍然存活（停止后不该有残留）");
        }
        finally
        {
            process.Dispose();
        }
    }
}
