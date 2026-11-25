using AliasAgent.Desktop;
using Xunit;
using Xunit.Abstractions;

namespace AliasAgent.Desktop.Tests;

/// <summary>
/// 任务 6.1c / 6.1d（返工）：启动完成后托盘菜单必须切到正常态；重启核心必须复用旧窗口。
///
/// 6.1c 缺陷现场：`StartupCoreAsync` 最后一次 `RefreshTrayMenu()` 停在 `CoreProcessStarted`
/// （`WaitingReady` 态，菜单只有「退出」）。`CoreReady` 把状态迁到 `WindowShown` 之后直到把
/// 窗口显示出来都没有再刷新，于是冷启动完成后右键托盘只有「退出」、缺「打开窗口」；要等
/// 第一次关窗（`OnFormClosing`）或从托盘开窗（`OnOpenWindowRequested`）才正确。
///
/// 6.1d 缺陷现场：`RestartCoreAsync` 重走 `StartupCoreAsync`，后者在 `CoreReady` 之后无条件
/// `_form = new MainForm(...)`，旧窗口（崩溃错误页）从未 Close/Dispose；而 `MainForm` 挂着
/// `FormClosing += OnFormClosing`，非退出态下该处理会把 Close 拦成 Hide，所以重启要么复用、
/// 要么先解绑再释放 —— 这里选复用（同一实例 + 重新导航）。
///
/// 本文件覆盖哪几件事（每件坏了都会红）：
///   (a) 接线守卫：生产源里 `ShowWindowAfterReadyAsync` 在窗口显示之后刷新托盘菜单；
///   (b) 接线守卫：生产源里 `new MainForm(` 只有一处、且在 `TryReuseExistingWindow();` 之后；
///   (c) 行为：走真实的「核心已就绪 → 窗口/托盘/崩溃订阅」接线（测试接缝只跳过 `Show()`
///       与 WebView2 初始化），断言状态到 `WindowShown`、托盘菜单模型是「打开窗口 + 退出」，
///       并打印实际菜单项集合；
///   (d) 行为：崩溃态 + 已装旧窗口走同一段接线，断言旧实例未被释放、`MainForm` 还是同一实例
///       （没有新建第二个窗口）、日志含「复用既有窗口」。
///
/// 覆盖边界（诚实登记）：单测不创建真实可见窗口、不覆盖真实 `NotifyIcon` 渲染与托盘右键外观、
/// 也不覆盖真实 WebView2 重新导航后的画面。6.2(d)（启动后菜单含「打开窗口」）与 6.2(f)
/// （点「重启核心」后窗口恢复、屏幕上只有一个窗口）的运行时复验由主循环执行，需要用户当场
/// 许可开窗；单测不假装覆盖它们。
/// </summary>
[Collection("WinFormsMessageLoop")]
public class ShellRestartAndTrayTests
{
    private readonly ITestOutputHelper _output;

    public ShellRestartAndTrayTests(ITestOutputHelper output)
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
        $@"Local\AliasAgent.Desktop.Test.RestartTray.{suffix}.{Guid.NewGuid():N}";

    /// <summary>只用来给 `AttachCoreCrashHandler` 一个订阅目标：本文件的用例不启动它。</summary>
    private static CoreCommand DummyCoreCommand() => new()
    {
        FileName = "cmd.exe",
        Arguments = "/C exit 0",
        WorkingDirectory = Path.GetTempPath(),
        PreviewText = "cmd.exe /C exit 0（6.1c/6.1d 测试替身，不启动）",
        Port = 1,
    };

    private static string ReadShellApplicationSource()
    {
        var repoRoot = new RepoRootLocator().Locate();
        var sourcePath = Path.Combine(
            repoRoot, "shell", "AliasAgent.Desktop", "ShellApplication.cs");
        Assert.True(File.Exists(sourcePath), $"找不到 ShellApplication.cs：{sourcePath}");
        return File.ReadAllText(sourcePath);
    }

    /// <summary>
    /// 取出一个方法的方法体（按花括号配对；生产源里的字符串插值花括号成对出现，不影响配对）。
    ///
    /// 为什么要按方法体取：只对整个文件做 `Contains` 会让别的方法里的同类调用把守卫喂绿
    /// （6.1b 的接线守卫也是盯「生产调用点」，不是盯「文件里出现过」）。
    /// </summary>
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

    private static int CountOccurrences(string text, string needle)
    {
        var count = 0;
        var index = 0;
        while ((index = text.IndexOf(needle, index, StringComparison.Ordinal)) >= 0)
        {
            count++;
            index += needle.Length;
        }

        return count;
    }

    /// <summary>
    /// 在一条真实 WinForms 消息循环里跑一段场景（与 6.1a / 6.1b 的写法同形）：
    /// `Application.Run` 之前主线程没有 WinForms 同步上下文，`StartOnce` 捕获后才进入启动委托。
    /// 场景跑完主动 `ExitThread`；另有 15 秒兜底时钟，避免缺陷态让消息循环永远不退出。
    /// </summary>
    private void RunAppScenario(
        string tag,
        Func<ShellApplication, Task> scenario,
        out string logText)
    {
        var logPath = Path.Combine(
            Path.GetTempPath(), $"aliasagent-shell-{tag}-{Guid.NewGuid():N}.log");
        Exception? failure = null;
        var startupRan = false;
        var thread = new Thread(() =>
        {
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
                ShellApplication? app = null;
                app = new ShellApplication(
                    options,
                    singleInstance,
                    logger,
                    startupOverride: async () =>
                    {
                        startupRan = true;
                        try
                        {
                            await scenario(app!).ConfigureAwait(true);
                        }
                        catch (Exception e)
                        {
                            failure = e;
                        }
                        finally
                        {
                            Application.ExitThread();
                        }
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
        logText = File.Exists(logPath) ? File.ReadAllText(logPath) : "(无日志文件)";
        _output.WriteLine($"[{tag}] 消息循环线程结束={finished} 启动委托执行={startupRan} 场景异常={failure}");
        _output.WriteLine($"[{tag}] 壳日志：{logText}");
        try
        {
            File.Delete(logPath);
        }
        catch
        {
            // 临时日志删不掉不影响断言。
        }

        Assert.True(finished, $"[{tag}] 消息循环线程没有在 30 秒内结束（Application.Run 没退出）");
        Assert.True(startupRan, $"[{tag}] StartOnce 没有执行启动委托（消息循环没跑起来）");
        Assert.Null(failure);
    }

    // ---------------------------------------------------------------------
    // (a) 6.1c 接线守卫：CoreReady/窗口显示之后必须刷新托盘菜单
    // ---------------------------------------------------------------------

    [Fact]
    public void StartupCompletionRefreshesTheTrayMenuAfterTheWindowIsShown()
    {
        var source = ReadShellApplicationSource();
        var body = ExtractMethodBody(source, "private async Task<bool> ShowWindowAfterReadyAsync");
        var coreReady = body.IndexOf("_state.Transition(ShellEvent.CoreReady);", StringComparison.Ordinal);
        var shown = body.IndexOf("ShowAndActivate", StringComparison.Ordinal);
        var refresh = body.IndexOf("RefreshTrayMenu();", StringComparison.Ordinal);

        _output.WriteLine(
            $"[6.1c] ShowWindowAfterReadyAsync：CoreReady 迁移位置={coreReady} " +
            $"窗口显示位置={shown} 托盘刷新位置={refresh}");
        _output.WriteLine(
            $"[6.1c] 方法体长度={body.Length}，含 RefreshTrayMenu 调用={refresh >= 0}");

        Assert.True(coreReady >= 0,
            "ShowWindowAfterReadyAsync 里没有 CoreReady 迁移：启动/重启共用的就绪后接线不存在");
        Assert.True(shown > coreReady,
            "窗口显示（ShowAndActivate）不在 CoreReady 之后：就绪后接线的顺序错了");
        Assert.True(refresh > shown,
            "窗口显示后没有刷新托盘菜单：启动完成时菜单仍停在启动期的「只有退出」（6.1c 的缺陷）");
    }

    // ---------------------------------------------------------------------
    // (b) 6.1d 接线守卫：重启必须复用旧窗口，不许无条件再 new 一个
    // ---------------------------------------------------------------------

    [Fact]
    public void RestartReusesTheExistingWindowInsteadOfCreatingASecondOne()
    {
        var source = ReadShellApplicationSource();
        var body = ExtractMethodBody(source, "private async Task<bool> ShowWindowAfterReadyAsync");
        var reuse = body.IndexOf("TryReuseExistingWindow();", StringComparison.Ordinal);
        var create = body.IndexOf("new MainForm(", StringComparison.Ordinal);
        var newFormSites = CountOccurrences(source, "new MainForm(");

        _output.WriteLine(
            $"[6.1d] ShowWindowAfterReadyAsync：复用判断位置={reuse} 新建窗口位置={create}");
        _output.WriteLine($"[6.1d] 全文件 new MainForm( 出现次数={newFormSites}（只允许新建兜底的一处）");

        Assert.True(reuse >= 0,
            "ShowWindowAfterReadyAsync 没有复用既有窗口：重启会再 new 一个，" +
            "旧崩溃错误页窗口留在屏幕上（6.1d 的缺陷）");
        Assert.True(create > reuse,
            "新建窗口不在复用判断之后：复用必须短路掉新建，否则重启仍会出现两个窗口");
        Assert.Equal(1, newFormSites);
    }

    // ---------------------------------------------------------------------
    // (c) 6.1c 行为：启动完成（CoreReady → WindowShown）后托盘菜单切到正常态
    // ---------------------------------------------------------------------

    [Fact]
    public void StartupCompletionMovesTheTrayMenuToOpenWindowAndExit()
    {
        var enterReturned = false;
        var stateAfter = ShellState.Resolving;
        var menuTexts = Array.Empty<string>();
        var mainFormSame = false;
        var installedFormDisposed = true;
        MainForm? installedForm = null;

        RunAppScenario("6.1c", async app =>
        {
            // 启动期的最后一个态（`CoreProcessStarted` 之后）：此刻托盘菜单只有「退出」。
            app.StateMachineForTests.ForceStateForTests(ShellState.WaitingReady);

            // 预装一个不显示、不初始化 WebView2 的窗口：走复用路径，避免测试里初始化
            // WebView2 或在用户桌面弹窗。托盘刷新/状态迁移/崩溃订阅仍是生产的那段接线。
            installedForm = new MainForm("http://127.0.0.1:1/", _ => { });
            app.SetFormForTests(installedForm);

            // 生产里 `StartupCoreAsync` 在就绪成功之后调用同一个方法；这里只跳过 `Show()`。
            enterReturned = await app.ShowWindowAfterReadyForTestsAsync(
                new CoreLauncher(DummyCoreCommand(), _ => { })).ConfigureAwait(true);
            stateAfter = app.StateMachineForTests.State;
            menuTexts = app.LastTrayMenuForTests.Select(item => item.Text).ToArray();
            mainFormSame = ReferenceEquals(app.MainForm, installedForm);
            // 必须在消息循环退出前读：Application.ExitThread 会让这个未显示的窗体走到已释放状态，
            // 那之后读到的是框架收尾，不是「就绪接线有没有释放窗口」。
            installedFormDisposed = installedForm.IsDisposed;
        }, out var logText);

        var startupMenu = TrayMenuModel.Build(ShellState.WaitingReady)
            .Select(item => item.Text).ToArray();
        _output.WriteLine($"[6.1c] 启动期（WaitingReady）菜单=[{string.Join(" / ", startupMenu)}]");
        _output.WriteLine(
            $"[6.1c] 就绪接缝返回={enterReturned} 状态={stateAfter} " +
            $"主窗口是预装实例={mainFormSame} 窗口已被释放={installedFormDisposed}");
        _output.WriteLine($"[6.1c] 启动完成后实际托盘菜单项=[{string.Join(" / ", menuTexts)}]");

        Assert.True(enterReturned, "就绪后的窗口/托盘接线没有走完（ShowWindowAfterReadyAsync 返回 false）");
        Assert.Equal(ShellState.WindowShown, stateAfter);
        Assert.NotNull(installedForm);
        Assert.False(installedFormDisposed, "首次启动的窗口不该在就绪接线里被释放");
        Assert.True(mainFormSame, "首次启动不该换掉窗口实例");
        Assert.Equal(new[] { TrayMenuText.OpenWindow, TrayMenuText.Exit }, menuTexts);
        Assert.Contains("状态迁移：WaitingReady --CoreReady--> WindowShown", logText,
            StringComparison.Ordinal);
        Assert.Contains("托盘菜单已刷新", logText, StringComparison.Ordinal);
    }

    // ---------------------------------------------------------------------
    // (d) 6.1d 行为：崩溃后重启复用旧窗口（不新建第二个）
    // ---------------------------------------------------------------------

    [Fact]
    public void RestartReusesTheExistingWindowInstanceInsteadOfCreatingASecondOne()
    {
        var enterReturned = false;
        var stateAfter = ShellState.Resolving;
        var menuTexts = Array.Empty<string>();
        var mainFormSame = false;
        var oldFormDisposed = true;
        MainForm? oldForm = null;

        RunAppScenario("6.1d", async app =>
        {
            // 崩溃现场：旧窗口停在错误页、状态是 CoreCrashed、菜单里有「重启核心」。
            app.StateMachineForTests.ForceStateForTests(ShellState.CoreCrashed);
            oldForm = new MainForm("http://127.0.0.1:1/", _ => { });
            app.SetFormForTests(oldForm);

            // 生产里 `RestartCoreAsync` → `StartupCoreAsync` 在核心重新就绪后走同一个方法；
            // 这里靠复用旧窗口跳过 WebView2 初始化与 `Show()`（不在用户桌面弹窗）。
            enterReturned = await app.ShowWindowAfterReadyForTestsAsync(
                new CoreLauncher(DummyCoreCommand(), _ => { })).ConfigureAwait(true);
            stateAfter = app.StateMachineForTests.State;
            menuTexts = app.LastTrayMenuForTests.Select(item => item.Text).ToArray();
            mainFormSame = ReferenceEquals(app.MainForm, oldForm);
            // 在消息循环退出前读（Application.ExitThread 的框架收尾会释放未显示的窗体）。
            oldFormDisposed = oldForm.IsDisposed;
        }, out var logText);

        _output.WriteLine(
            $"[6.1d] 就绪接缝返回={enterReturned} 状态={stateAfter} 旧窗口已被释放={oldFormDisposed}");
        _output.WriteLine(
            $"[6.1d] 主窗口仍是旧实例={mainFormSame} 实际托盘菜单项=[{string.Join(" / ", menuTexts)}]");

        Assert.True(enterReturned, "重启后的窗口接线没有走完（ShowWindowAfterReadyAsync 返回 false）");
        Assert.Equal(ShellState.WindowShown, stateAfter);
        Assert.NotNull(oldForm);
        Assert.False(oldFormDisposed,
            "旧窗口被 Dispose 了：本实现选择复用旧窗口，重启后应该还是同一实例");
        Assert.True(mainFormSame,
            "重启新建了第二个窗口：MainForm 不再是旧实例（6.1d 的缺陷现场）");
        Assert.Equal(new[] { TrayMenuText.OpenWindow, TrayMenuText.Exit }, menuTexts);
        Assert.Contains("复用既有窗口", logText, StringComparison.Ordinal);
        Assert.Contains("状态迁移：CoreCrashed --CoreReady--> WindowShown", logText,
            StringComparison.Ordinal);
    }
}
