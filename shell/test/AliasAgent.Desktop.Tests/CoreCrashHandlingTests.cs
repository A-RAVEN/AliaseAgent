using AliasAgent.Desktop;
using Xunit;
using Xunit.Abstractions;

namespace AliasAgent.Desktop.Tests;

/// <summary>
/// 任务 6.1b：壳进入运行态后，核心被手工杀掉必须迁移到崩溃态，且崩溃处理执行在 UI 线程。
///
/// 缺陷现场（6.2(f)）：`ShellApplication.HandleCoreCrashed` 只有定义、全仓库没有任何订阅者。
/// 启动期只为「就绪前退出」判定临时订阅 `CoreLauncher.UnexpectedExit`，就绪后立刻解绑；
/// 运行期核心退出时 `UnexpectedExit` 照常触发，但没人接收 —— 日志只有「核心进程已退出」，
/// 没有崩溃态迁移、没有气泡、窗口停在旧聊天页。
///
/// 本文件覆盖哪几件事（每件坏了都会红）：
///   (a) 接线守卫：生产启动序列（`StartupCoreAsync`）在运行态调用了永久崩溃订阅入口。
///       行为用例能证明「订阅 + 编组 + 崩溃态」这条接缝工作，但单测跑不起真实启动序列
///       （真核心 + WebView2 窗口），所以生产调用点单独盯一条静态守卫。
///   (b) 行为：运行态订阅后真实子进程被杀（`Process.Exited` → `UnexpectedExit`，不是测试
///       自己调事件），经 `UiThreadMarshaller.Post` 到 UI 线程，状态机迁移到 `CoreCrashed`、
///       错误页路径被调用，且错误页处理的线程 id == UI 线程 id。
///
/// 覆盖边界（诚实登记）：真实窗口/气泡/托盘菜单外观归 6.2(f) 运行时复验（需用户当场许可
/// 开窗，由主循环执行）；单测只覆盖编组与状态/错误页路径这条接缝。
/// </summary>
[Collection("WinFormsMessageLoop")]
public class CoreCrashHandlingTests
{
    private readonly ITestOutputHelper _output;

    public CoreCrashHandlingTests(ITestOutputHelper output)
    {
        _output = output;
    }

    // ---------------------------------------------------------------------
    // (a) 接线守卫：生产启动序列必须把运行态崩溃订阅接上
    // ---------------------------------------------------------------------

    [Fact]
    public void StartupMustWireThePermanentCrashSubscription()
    {
        var repoRoot = new RepoRootLocator().Locate();
        var sourcePath = Path.Combine(
            repoRoot, "shell", "AliasAgent.Desktop", "ShellApplication.cs");
        _output.WriteLine($"[6.1b] 读取生产源文件：{sourcePath}");
        Assert.True(File.Exists(sourcePath), $"找不到 ShellApplication.cs：{sourcePath}");
        var source = File.ReadAllText(sourcePath);

        // 订阅方法本身（生产代码里的定义）与它在启动序列里的**调用点**都必须存在。
        // 只有定义没有调用 = 6.2(f) 的缺陷现场（HandleCoreCrashed 又变回死代码）。
        var hasDefinition = source.Contains(
            "void AttachCoreCrashHandler(CoreLauncher launcher)", StringComparison.Ordinal);
        var hasCallSite = source.Contains(
            "AttachCoreCrashHandler(launcher);", StringComparison.Ordinal);
        _output.WriteLine($"[6.1b] 订阅方法定义存在={hasDefinition} 启动序列调用点存在={hasCallSite}");

        Assert.True(hasDefinition,
            "运行态的永久崩溃订阅方法不存在：运行期核心退出仍然没人处理（6.1b 的缺陷）");
        Assert.True(hasCallSite,
            "StartupCoreAsync 没有在运行态调用 AttachCoreCrashHandler(launcher)：" +
            "即使方法存在，核心崩溃也接不到（6.1b 的缺陷）");
    }

    // ---------------------------------------------------------------------
    // (b) 行为：运行态订阅 + 真实子进程退出 ⇒ 编组到 UI 线程 ⇒ 崩溃态 + 错误页路径
    // ---------------------------------------------------------------------

    /// <summary>本文件的用例只观测，不影响用户桌面（不真的激活任何窗口）。</summary>
    private sealed class NoopActivator : IWindowActivator
    {
        public bool AllowSetForegroundWindow(int pid) => true;
    }

    private static string UniqueName(string suffix) =>
        $@"Local\AliasAgent.Desktop.Test.Crash.{suffix}.{Guid.NewGuid():N}";

    [Fact]
    public void CrashAfterStartupMovesToCrashedAndHandlesOnTheUiThread()
    {
        var logPath = Path.Combine(
            Path.GetTempPath(), $"aliasagent-shell-6.1b-{Guid.NewGuid():N}.log");
        Exception? failure = null;
        ShellApplication? appRef = null;
        var launcherLogs = new List<string>();
        var uiThreadId = -1;
        var errorPageThreadId = -1;
        var startupRan = false;
        var launcherStarted = false;
        var reachedCrashed = false;

        var thread = new Thread(() =>
        {
            CoreLauncher? launcher = null;
            MainForm? form = null;
            try
            {
                // 与 Program.Main 同形：Application.Run 之前主线程没有 WinForms 同步上下文。
                SynchronizationContext.SetSynchronizationContext(null);
                using var logger = new ShellLogger(logPath);
                using var singleInstance = new SingleInstance(
                    logger.Write,
                    new NoopActivator(),
                    UniqueName("mutex"),
                    UniqueName("event"),
                    UniqueName("state"));
                var options = DesktopOptions.Parse(Array.Empty<string>());
                var app = new ShellApplication(
                    options,
                    singleInstance,
                    logger,
                    startupOverride: () =>
                    {
                        try
                        {
                            startupRan = true;
                            uiThreadId = Environment.CurrentManagedThreadId;

                            // 生产里 CoreReady 的迁移结果是 WindowShown；这里模拟「启动完成」的前置态。
                            appRef!.StateMachineForTests.ForceStateForTests(ShellState.WindowShown);

                            // 真 MainForm 但**不 Show、不初始化 WebView2**：只为让错误页路径可
                            // 观察（`CoreWebView2` 未初始化时为 null），不会在屏幕上创建窗口。
                            form = new MainForm("http://127.0.0.1:1/", line =>
                            {
                                if (line.Contains("窗口已切到错误页", StringComparison.Ordinal))
                                {
                                    errorPageThreadId = Environment.CurrentManagedThreadId;
                                }
                            });
                            appRef.SetFormForTests(form);

                            // 用 ping 当核心替身：验的是 CoreLauncher 真实的
                            // Process.Exited → UnexpectedExit 触发链路，不是测试自己调事件。
                            launcher = new CoreLauncher(
                                new CoreCommand
                                {
                                    FileName = "ping.exe",
                                    ArgumentList = new[] { "-n", "30", "127.0.0.1" },
                                    WorkingDirectory = Path.GetTempPath(),
                                    PreviewText = "ping.exe -n 30 127.0.0.1（6.1b 核心替身）",
                                    Port = 1,
                                },
                                line =>
                                {
                                    lock (launcherLogs) launcherLogs.Add(line);
                                });
                            var process = launcher.Start();
                            launcherStarted = true;

                            // 生产在窗口显示之后调用同一方法（StartupCoreAsync 的运行态接线）。
                            appRef.AttachCoreCrashHandler(launcher);

                            // 从线程池线程杀掉替身核心：触发真实的 Exited → UnexpectedExit。
                            Task.Run(() =>
                            {
                                try
                                {
                                    process.Kill();
                                }
                                catch
                                {
                                    // 进程已自己退出：仍会经 Exited 算一次非预期退出。
                                }
                            });
                        }
                        catch (Exception e)
                        {
                            failure = e;
                        }

                        return Task.CompletedTask;
                    });
                appRef = app;

                // UI 线程轮询崩溃态：到 CoreCrashed 就结束消息循环。
                using var poll = new System.Windows.Forms.Timer { Interval = 50 };
                poll.Tick += (_, _) =>
                {
                    if (app.StateMachineForTests.State == ShellState.CoreCrashed)
                    {
                        reachedCrashed = true;
                        poll.Stop();
                        Application.ExitThread();
                    }
                };
                // 兜底时钟：崩溃处理没到 UI 线程（缺陷态）时也别让消息循环永远不退出。
                using var watchdog = new System.Windows.Forms.Timer { Interval = 15000 };
                watchdog.Tick += (_, _) =>
                {
                    watchdog.Stop();
                    Application.ExitThread();
                };
                poll.Start();
                watchdog.Start();
                Application.Run(app);
            }
            catch (Exception e)
            {
                failure ??= e;
            }
            finally
            {
                try
                {
                    if (launcher?.Process != null && !launcher.Process.HasExited)
                    {
                        launcher.Process.Kill();
                    }

                    launcher?.Process?.WaitForExit(5000);
                }
                catch
                {
                    // 清理失败不影响断言（观察值已经拿到）。
                }

                try
                {
                    form?.Dispose();
                }
                catch
                {
                    // 未创建句柄时 Dispose 不会失败；真失败也不影响断言。
                }
            }
        });
        thread.SetApartmentState(ApartmentState.STA);
        thread.IsBackground = true;
        thread.Start();
        var finished = thread.Join(TimeSpan.FromSeconds(30));

        var logText = File.Exists(logPath) ? File.ReadAllText(logPath) : "(无日志文件)";
        string[] launcherLines;
        lock (launcherLogs) launcherLines = launcherLogs.ToArray();
        _output.WriteLine(
            $"[6.1b] 消息循环线程结束={finished} 启动委托执行={startupRan} 替身核心已启动={launcherStarted}");
        _output.WriteLine(
            $"[6.1b] UI 线程 id={uiThreadId} 崩溃态到达={reachedCrashed} 最终状态={appRef?.StateMachineForTests.State}");
        _output.WriteLine($"[6.1b] 错误页处理线程 id={errorPageThreadId}（必须 == UI 线程 id）");
        _output.WriteLine($"[6.1b] launcher 日志=[{string.Join(" | ", launcherLines)}]");
        _output.WriteLine($"[6.1b] 壳日志：{logText}");

        try
        {
            File.Delete(logPath);
        }
        catch
        {
            // 临时日志删不掉不影响断言。
        }

        Assert.True(finished, "消息循环线程没有在 30 秒内结束（崩溃态没到 / Application.Run 没退出）");
        Assert.Null(failure);
        Assert.True(startupRan, "StartOnce 没有执行启动委托（启动序列没跑起来）");
        Assert.True(launcherStarted, "替身核心进程没有启动（触发链路不成立）");
        Assert.True(reachedCrashed, "运行期核心退出后状态机没有迁移到 CoreCrashed（6.1b 的缺陷现场）");
        Assert.NotNull(appRef);
        Assert.Equal(ShellState.CoreCrashed, appRef!.StateMachineForTests.State);
        Assert.True(errorPageThreadId > 0,
            "崩溃处理没有走到 MainForm.ShowErrorPage（错误页路径没被调用）");
        Assert.Equal(uiThreadId, errorPageThreadId);
        Assert.Contains(launcherLines, line => line.Contains("核心进程已退出", StringComparison.Ordinal));
        Assert.Contains("运行态：核心非预期退出已永久订阅", logText, StringComparison.Ordinal);
        Assert.Contains("状态迁移：WindowShown --CoreUnexpectedExit--> CoreCrashed", logText,
            StringComparison.Ordinal);
        Assert.Contains("核心非预期退出（exit=", logText, StringComparison.Ordinal);
    }
}
