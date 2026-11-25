using System.Text.RegularExpressions;
using AliasAgent.Desktop;
using Xunit;
using Xunit.Abstractions;

namespace AliasAgent.Desktop.Tests;

/// <summary>
/// 任务 6.1e：崩溃后点「重启核心」失败时，壳**不许退出**。
///
/// 缺陷现场：`RestartCoreAsync` 直接重走 `StartupCoreAsync`，而后者所有失败分支都走
/// `FailStartupAsync`：泄停核心 + 释放托盘图标 + 释放壳单实例锁 + `MessageBox` +
/// `Environment.ExitCode = 1` + `ExitThread()`。于是「端口仍被占 / 核心仍起不来」这种
/// 本可重试的重启失败，会把整个壳带走；状态也不会回到 `CoreCrashed`，托盘菜单里的
/// 「重启核心」随壳一起消失。spec「核心崩溃可归因且可显式重启」正文要求
/// 「重启失败 SHALL 继续给可归因提示，MUST NOT 变成静默无响应」；Scenario「显式重启恢复」
/// 要求「失败则给出可归因提示并保持『重启核心』可用」。
///
/// 本文件覆盖哪几件事（每件坏了都会红）：
///   (a) 行为：真实 `RestartCoreAsync` → 真实 `StartupCoreAsync` 的预检失败分支
///       （临时 `--repo-root` 没有 `web/dist`）⇒ 壳不退出、单实例锁仍持有、没有弹首次
///       启动失败对话框、状态回 `CoreCrashed`、托盘菜单仍含「重启核心」、气泡记录原因与
///       日志路径、窗口走到错误页、日志有 `StartingCore --RestartFailed--> CoreCrashed`；
///   (b) 回归：同一条预检失败作为**首次启动**时仍只弹一次启动失败对话框、释放单实例锁、
///       以非零码退出（`Environment.ExitCode` 捕获后复位），证明没有为了修重启而改坏
///       首次启动的 spec 语义；
///   (c) 接线守卫：`StartupCoreAsync` 的每个失败分支都带 `mode`；`RestartCoreAsync`
///       走 `RestartAfterCrash` 且有异常兜底；`FailRestartAsync` 不含 `ExitThread` /
///       `MessageBox.Show`，且包含回崩溃态、刷新菜单、错误页、气泡四件事。
///
/// 覆盖边界（诚实登记）：单测不弹真实 `MessageBox`、不建真实托盘/可见窗口、不起真实核心；
/// 行为用例只覆盖「预检失败」这一条真实失败分支，其余失败分支由接线守卫盯调用形状。
/// 真实托盘气泡 / 窗口错误页 / 端口仍被占时的重试体验，权威是 6.2(f) 的运行时复验
/// （需用户当场许可开窗，由主循环执行）；单测不假装覆盖它们。
/// </summary>
[Collection("WinFormsMessageLoop")]
public class RestartFailureHandlingTests
{
    private readonly ITestOutputHelper _output;

    public RestartFailureHandlingTests(ITestOutputHelper output)
    {
        _output = output;
    }

    // ---------------------------------------------------------------------
    // 公共夹具
    // ---------------------------------------------------------------------

    /// <summary>只允许本文件的探针线程使用；记录调用不产生任何桌面副作用。</summary>
    private sealed class NoopActivator : IWindowActivator
    {
        public bool AllowSetForegroundWindow(int pid) => true;
    }

    private static string UniqueName(string suffix) =>
        $@"Local\AliasAgent.Desktop.Test.RestartFailure.{suffix}.{Guid.NewGuid():N}";

    /// <summary>
    /// 一个**没有** `web/dist/index.html` 的临时仓库根：预检必然失败，且失败发生在
    /// 起核心之前 —— 不需要真核心、真 dart 或真端口就能走到真实的启动失败分支。
    /// </summary>
    private static string CreateRepoRootWithoutWebDist() =>
        Directory.CreateTempSubdirectory("aliasagent-6.1e-repo-").FullName;

    private static DesktopOptions OptionsFor(string repoRoot) =>
        DesktopOptions.Parse(new[]
        {
            "--repo-root", repoRoot,
            "--config", Path.Combine(repoRoot, "config.json"),
        });

    private static string ReadShellApplicationSource()
    {
        var repoRoot = new RepoRootLocator().Locate();
        var sourcePath = Path.Combine(
            repoRoot, "shell", "AliasAgent.Desktop", "ShellApplication.cs");
        Assert.True(File.Exists(sourcePath), $"找不到 ShellApplication.cs：{sourcePath}");
        return File.ReadAllText(sourcePath);
    }

    /// <summary>取出一个方法体（按花括号配对；签名必须唯一）。</summary>
    private static string ExtractMethodBody(string source, string signature)
    {
        var start = source.IndexOf(signature, StringComparison.Ordinal);
        Assert.True(start >= 0, $"生产源里找不到方法：{signature}");
        var brace = source.IndexOf('{', start);
        Assert.True(brace >= 0, $"方法没有方法体：{signature}");
        var depth = 0;
        for (var i = brace; i < source.Length; i++)
        {
            if (source[i] == '{')
            {
                depth++;
            }
            else if (source[i] == '}')
            {
                depth--;
                if (depth == 0) return source[(brace + 1)..i];
            }
        }

        Assert.Fail($"方法体花括号不配对：{signature}");
        return string.Empty;
    }

    // ---------------------------------------------------------------------
    // (a) 6.1e 行为：重启失败 ⇒ 壳不退出、回崩溃态、菜单仍有「重启核心」、有可归因提示
    // ---------------------------------------------------------------------

    [Fact]
    public void RestartFailureKeepsTheShellAliveInCrashedStateWithAttributablePrompt()
    {
        var repoRoot = CreateRepoRootWithoutWebDist();
        var logPath = Path.Combine(
            Path.GetTempPath(), $"aliasagent-shell-6.1e-restart-{Guid.NewGuid():N}.log");
        var dialogs = new List<string>();
        var formLogs = new List<string>();
        var stateAfter = ShellState.Resolving;
        var menuTexts = Array.Empty<string>();
        (string Title, string Text, System.Windows.Forms.ToolTipIcon Icon)? balloon = null;
        var singleInstanceStillHeld = false;
        var errorPageShown = false;
        var restartReturned = false;
        var environmentExitCode = -1;
        var startupRan = false;
        Exception? failure = null;

        var thread = new Thread(() =>
        {
            try
            {
                // 与 Program.Main 同形：Application.Run 之前主线程没有 WinForms 同步上下文。
                SynchronizationContext.SetSynchronizationContext(null);
                Environment.ExitCode = 0;
                using var logger = new ShellLogger(logPath);
                using var singleInstance = new SingleInstance(
                    logger.Write,
                    new NoopActivator(),
                    UniqueName("mutex"),
                    UniqueName("event"),
                    UniqueName("state"));
                ShellApplication? app = null;
                app = new ShellApplication(
                    OptionsFor(repoRoot),
                    singleInstance,
                    logger,
                    startupOverride: async () =>
                    {
                        startupRan = true;
                        try
                        {
                            // 崩溃现场：状态 CoreCrashed、旧窗口停在错误页、菜单有「重启核心」。
                            app!.StateMachineForTests.ForceStateForTests(ShellState.CoreCrashed);
                            var form = new MainForm("http://127.0.0.1:1/", line =>
                            {
                                formLogs.Add(line);
                                if (line.Contains("窗口已切到错误页", StringComparison.Ordinal))
                                {
                                    errorPageShown = true;
                                }
                            });
                            app.SetFormForTests(form);

                            // 生产里由托盘「重启核心」触发；这里走同一个真实入口（不模拟失败）。
                            await app.RestartCoreForTestsAsync().ConfigureAwait(true);
                            restartReturned = true;
                        }
                        catch (Exception e)
                        {
                            failure = e;
                        }
                        finally
                        {
                            stateAfter = app!.StateMachineForTests.State;
                            menuTexts = app.LastTrayMenuForTests
                                .Select(item => item.Text).ToArray();
                            balloon = app.LastBalloonForTests;
                            environmentExitCode = Environment.ExitCode;
                            // 复位进程级退出码，避免影响 dotnet test 宿主。
                            Environment.ExitCode = 0;
                            try
                            {
                                // 仍能等待「打开窗口」事件 ⇒ 单实例锁没被释放、壳还在。
                                singleInstanceStillHeld = !singleInstance.WaitForOpenRequest(TimeSpan.Zero);
                            }
                            catch (ObjectDisposedException)
                            {
                                singleInstanceStillHeld = false;
                            }

                            Application.ExitThread();
                        }
                    },
                    startupFailureDialog: (title, text) =>
                    {
                        lock (dialogs) dialogs.Add($"{title}：{text}");
                    });

                using var watchdog = new System.Windows.Forms.Timer { Interval = 15000 };
                watchdog.Tick += (_, _) =>
                {
                    watchdog.Stop();
                    Application.ExitThread();
                };
                watchdog.Start();
                Application.Run(app);
            }
            catch (Exception e)
            {
                failure ??= e;
            }
        });
        thread.SetApartmentState(ApartmentState.STA);
        thread.IsBackground = true;
        thread.Start();
        var finished = thread.Join(TimeSpan.FromSeconds(30));

        var logText = File.Exists(logPath) ? File.ReadAllText(logPath) : "(无日志文件)";
        string[] dialogLines;
        lock (dialogs) dialogLines = dialogs.ToArray();
        string[] formLines;
        lock (formLogs) formLines = formLogs.ToArray();

        _output.WriteLine($"[6.1e] 消息循环线程结束={finished} 启动委托执行={startupRan} " +
                          $"重启入口返回={restartReturned} 场景异常={failure}");
        _output.WriteLine($"[6.1e] 重启失败后：状态={stateAfter} 进程退出码={environmentExitCode} " +
                          $"单实例锁仍持有={singleInstanceStillHeld}");
        _output.WriteLine($"[6.1e] 实际托盘菜单项=[{string.Join(" / ", menuTexts)}]");
        _output.WriteLine($"[6.1e] 气泡记录={balloon}");
        _output.WriteLine($"[6.1e] 首次启动失败对话框实际弹出次数={dialogLines.Length}" +
                          $"{(dialogLines.Length == 0 ? string.Empty : "：" + string.Join(" | ", dialogLines))}");
        _output.WriteLine($"[6.1e] 错误页路径被调用={errorPageShown}；窗口日志=" +
                          $"[{string.Join(" | ", formLines)}]");
        _output.WriteLine($"[6.1e] 壳日志：{logText}");

        try
        {
            File.Delete(logPath);
        }
        catch
        {
            // 临时日志删不掉不影响断言。
        }

        try
        {
            Directory.Delete(repoRoot, recursive: true);
        }
        catch
        {
            // 临时目录删不掉不影响断言。
        }

        Assert.True(finished, "消息循环线程没有在 30 秒内结束（重启失败把消息循环带走了 / 没退出）");
        Assert.Null(failure);
        Assert.True(startupRan, "StartOnce 没有执行启动委托（消息循环没跑起来）");
        Assert.True(restartReturned, "重启入口没有正常返回（重启失败路径抛异常或卡住）");
        Assert.Equal(0, environmentExitCode);
        Assert.True(singleInstanceStillHeld,
            "重启失败后壳的单实例锁被释放了：壳走了首次启动的回收/退出路径（6.1e 的缺陷现场）");
        Assert.Empty(dialogLines);
        Assert.Equal(ShellState.CoreCrashed, stateAfter);
        Assert.Equal(
            new[] { TrayMenuText.OpenWindow, TrayMenuText.RestartCore, TrayMenuText.Exit },
            menuTexts);
        Assert.True(errorPageShown, "重启失败没有给出窗口错误页（可归因提示缺失）");
        Assert.NotNull(balloon);
        Assert.Contains("重启核心失败", balloon.Value.Title, StringComparison.Ordinal);
        Assert.Contains(logPath, balloon.Value.Text, StringComparison.Ordinal);
        Assert.Contains("壳保持运行", logText, StringComparison.Ordinal);
        Assert.Contains("状态迁移：StartingCore --RestartFailed--> CoreCrashed", logText,
            StringComparison.Ordinal);
        Assert.Contains("托盘菜单已刷新：CoreCrashed", logText, StringComparison.Ordinal);
        Assert.Contains(formLines,
            line => line.Contains("窗口已切到错误页：重启核心失败", StringComparison.Ordinal));
    }

    // ---------------------------------------------------------------------
    // (b) 6.1e 回归：首次启动失败仍回收 + 非零退出（不许被重启分流改坏）
    // ---------------------------------------------------------------------

    [Fact]
    public void FirstLaunchFailureStillRecyclesAndExitsNonZero()
    {
        var repoRoot = CreateRepoRootWithoutWebDist();
        var logPath = Path.Combine(
            Path.GetTempPath(), $"aliasagent-shell-6.1e-first-{Guid.NewGuid():N}.log");
        var dialogs = new List<string>();
        var runReturned = false;
        var exitCode = -1;
        var singleInstanceReleased = false;
        Exception? failure = null;

        var thread = new Thread(() =>
        {
            try
            {
                SynchronizationContext.SetSynchronizationContext(null);
                Environment.ExitCode = 0;
                using var logger = new ShellLogger(logPath);
                using var singleInstance = new SingleInstance(
                    logger.Write,
                    new NoopActivator(),
                    UniqueName("mutex"),
                    UniqueName("event"),
                    UniqueName("state"));
                var app = new ShellApplication(
                    OptionsFor(repoRoot),
                    singleInstance,
                    logger,
                    startupOverride: null,
                    startupFailureDialog: (title, text) =>
                    {
                        lock (dialogs) dialogs.Add($"{title}：{text}");
                    });

                Application.Run(app);
                runReturned = true;
                exitCode = Environment.ExitCode;
                Environment.ExitCode = 0;
                try
                {
                    singleInstance.WaitForOpenRequest(TimeSpan.Zero);
                    singleInstanceReleased = false;
                }
                catch (ObjectDisposedException)
                {
                    singleInstanceReleased = true;
                }
            }
            catch (Exception e)
            {
                failure = e;
            }
        });
        thread.SetApartmentState(ApartmentState.STA);
        thread.IsBackground = true;
        thread.Start();
        var finished = thread.Join(TimeSpan.FromSeconds(30));

        var logText = File.Exists(logPath) ? File.ReadAllText(logPath) : "(无日志文件)";
        string[] dialogLines;
        lock (dialogs) dialogLines = dialogs.ToArray();

        _output.WriteLine(
            $"[6.1e] 首次启动失败：消息循环线程结束={finished} Application.Run 返回={runReturned} " +
            $"退出码={exitCode} 单实例锁已释放={singleInstanceReleased} 场景异常={failure}");
        _output.WriteLine($"[6.1e] 首次启动失败对话框=[{string.Join(" | ", dialogLines)}]");
        _output.WriteLine($"[6.1e] 壳日志：{logText}");

        try
        {
            File.Delete(logPath);
        }
        catch
        {
            // 临时日志删不掉不影响断言。
        }

        try
        {
            Directory.Delete(repoRoot, recursive: true);
        }
        catch
        {
            // 临时目录删不掉不影响断言。
        }

        Assert.True(finished, "首次启动失败后消息循环没有退出：既没回收也没非零退出");
        Assert.Null(failure);
        Assert.True(runReturned, "首次启动失败没有结束 Application.Run（ExitThread 没被调用）");
        Assert.Equal(1, exitCode);
        Assert.True(singleInstanceReleased, "首次启动失败必须释放单实例锁（否则下次启动报已有实例）");
        Assert.Single(dialogLines);
        Assert.Contains("AliasAgent 启动失败：环境不满足", dialogLines[0], StringComparison.Ordinal);
        Assert.Contains("启动失败（启动失败：环境不满足）", logText, StringComparison.Ordinal);
        Assert.DoesNotContain("重启核心失败", logText, StringComparison.Ordinal);
    }

    // ---------------------------------------------------------------------
    // (c) 6.1e 接线守卫：每个启动失败分支都带上下文；重启失败不碰首次启动退出路径
    // ---------------------------------------------------------------------

    [Fact]
    public void RestartFailuresNeverRouteThroughTheFirstLaunchExitPath()
    {
        var source = ReadShellApplicationSource();
        var startup = ExtractMethodBody(source, "private async Task StartupCoreAsync(StartupMode mode)");
        var restart = ExtractMethodBody(source, "private async Task RestartCoreAsync()");
        var failStartup = ExtractMethodBody(source, "private async Task FailStartupAsync(");
        var failRestart = ExtractMethodBody(source, "private async Task FailRestartAsync(");
        var showWindow = ExtractMethodBody(
            source, "private async Task<bool> ShowWindowAfterReadyAsync(");

        var allStartupFailureCalls = Regex.Matches(startup, @"FailStartupAsync\(").Count;
        var modeAwareFailureCalls = Regex.Matches(startup, @"FailStartupAsync\(\s*mode,").Count;
        var restartModeCalls = Regex.Matches(
            restart, @"StartupCoreAsync\(StartupMode\.RestartAfterCrash\)").Count;

        _output.WriteLine(
            $"[6.1e] StartupCoreAsync 失败分支={allStartupFailureCalls} 其中带 mode={modeAwareFailureCalls}");
        _output.WriteLine(
            $"[6.1e] RestartCoreAsync 走 RestartAfterCrash={restartModeCalls} " +
            $"含异常兜底={restart.Contains("catch", StringComparison.Ordinal)} " +
            $"含 FailRestartAsync={restart.Contains("FailRestartAsync(", StringComparison.Ordinal)}");
        _output.WriteLine($"[6.1e] FailRestartAsync 方法体长度={failRestart.Length}");

        Assert.True(allStartupFailureCalls > 0, "StartupCoreAsync 里找不到任何失败分支");
        Assert.Equal(allStartupFailureCalls, modeAwareFailureCalls);
        Assert.True(restartModeCalls >= 1,
            "RestartCoreAsync 没有用 RestartAfterCrash 上下文重走启动序列（6.1e 的根因）");
        Assert.Contains("catch", restart, StringComparison.Ordinal);
        Assert.Contains("FailRestartAsync(", restart, StringComparison.Ordinal);
        Assert.DoesNotContain("FailStartupAsync(", restart, StringComparison.Ordinal);

        Assert.Contains("if (mode == StartupMode.RestartAfterCrash)", failStartup,
            StringComparison.Ordinal);
        Assert.Contains("FailRestartAsync(", failStartup, StringComparison.Ordinal);
        Assert.Contains("ExitThread();", failStartup, StringComparison.Ordinal);

        Assert.DoesNotContain("ExitThread", failRestart, StringComparison.Ordinal);
        Assert.DoesNotContain("MessageBox.Show", failRestart, StringComparison.Ordinal);
        Assert.Contains("ShellEvent.RestartFailed", failRestart, StringComparison.Ordinal);
        Assert.Contains("RefreshTrayMenu();", failRestart, StringComparison.Ordinal);
        Assert.Contains("ShowErrorPage", failRestart, StringComparison.Ordinal);
        Assert.Contains("ShowBalloon", failRestart, StringComparison.Ordinal);

        Assert.Contains("if (mode == StartupMode.RestartAfterCrash)", showWindow,
            StringComparison.Ordinal);
        Assert.Contains("FailRestartAsync(", showWindow, StringComparison.Ordinal);
    }
}
