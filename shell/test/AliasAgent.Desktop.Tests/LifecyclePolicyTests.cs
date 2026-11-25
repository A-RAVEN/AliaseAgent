using AliasAgent.Desktop;
using Xunit;
using Xunit.Abstractions;

namespace AliasAgent.Desktop.Tests;

/// <summary>
/// 任务 3.10：生命周期策略（都能被 xunit 直接调，不需要窗口）。
///
/// 判据（坏了必须红）：
///   - 关窗直接退出（没走「取消关闭 + 隐藏」）；
///   - 启动期菜单缺项 / 崩溃态不出现「重启核心」；
///   - pendingOpen 被丢；
///   - WebView2 失败时决策不是「先回收（停核心 + 放锁）再退出」。
/// </summary>
public class LifecyclePolicyTests
{
    private readonly ITestOutputHelper _output;

    public LifecyclePolicyTests(ITestOutputHelper output)
    {
        _output = output;
    }

    // ---------------------------------------------------------------------
    // WindowClosePolicy
    // ---------------------------------------------------------------------

    [Fact]
    public void ClosingTheWindowOnlyHidesItWhenExitWasNotRequested()
    {
        var decision = WindowClosePolicy.Decide(exitRequested: false);
        _output.WriteLine($"[CLOSE] exitRequested=false ⇒ {decision}");
        Assert.Equal(WindowCloseDecision.CancelAndHide, decision);
    }

    [Fact]
    public void ClosingTheWindowIsAllowedWhenExitWasRequested()
    {
        var decision = WindowClosePolicy.Decide(exitRequested: true);
        _output.WriteLine($"[CLOSE] exitRequested=true ⇒ {decision}");
        Assert.Equal(WindowCloseDecision.Allow, decision);
    }

    // ---------------------------------------------------------------------
    // TrayMenuModel
    // ---------------------------------------------------------------------

    [Fact]
    public void StartupMenuHasOnlyExit()
    {
        foreach (var state in new[] { ShellState.StartingCore, ShellState.WaitingReady })
        {
            var items = TrayMenuModel.Build(state);
            _output.WriteLine($"[MENU] {state} ⇒ {string.Join(" / ", items.Select(i => $"{i.Text}({i.Enabled})"))}");
            Assert.Equal(new[] { TrayMenuText.Exit }, items.Select(i => i.Text));
            Assert.All(items, item => Assert.True(item.Enabled));
        }
    }

    [Fact]
    public void NormalMenuHasOpenWindowAndExit()
    {
        foreach (var state in new[] { ShellState.WindowShown, ShellState.HiddenToTray })
        {
            var items = TrayMenuModel.Build(state);
            _output.WriteLine($"[MENU] {state} ⇒ {string.Join(" / ", items.Select(i => $"{i.Text}({i.Enabled})"))}");
            Assert.Equal(new[] { TrayMenuText.OpenWindow, TrayMenuText.Exit }, items.Select(i => i.Text));
        }
    }

    [Fact]
    public void CrashMenuAddsRestartCore()
    {
        var items = TrayMenuModel.Build(ShellState.CoreCrashed);
        _output.WriteLine($"[MENU] CoreCrashed ⇒ {string.Join(" / ", items.Select(i => $"{i.Text}({i.Enabled})"))}");
        Assert.Contains(items, item => item.Text == TrayMenuText.RestartCore && item.Enabled);
        Assert.Contains(items, item => item.Text == TrayMenuText.OpenWindow);
        Assert.Contains(items, item => item.Text == TrayMenuText.Exit);
    }

    [Fact]
    public void NonCrashStatesNeverOfferRestartCore()
    {
        foreach (var state in new[]
                 {
                     ShellState.Resolving, ShellState.StartingCore, ShellState.WaitingReady,
                     ShellState.WindowShown, ShellState.HiddenToTray, ShellState.Stopping,
                 })
        {
            var items = TrayMenuModel.Build(state);
            _output.WriteLine($"[MENU] {state} ⇒ {string.Join(" / ", items.Select(i => i.Text))}");
            Assert.DoesNotContain(items, item => item.Text == TrayMenuText.RestartCore);
        }
    }

    // ---------------------------------------------------------------------
    // ShellStateMachine（design D4 表逐行迁移）
    // ---------------------------------------------------------------------

    [Fact]
    public void StartupTransitionsFollowTheDesignTable()
    {
        var machine = new ShellStateMachine();
        _output.WriteLine($"[STATE] 初始 = {machine.State}");
        Assert.Equal(ShellState.Resolving, machine.State);

        Assert.Equal(ShellState.StartingCore, machine.Transition(ShellEvent.StartCoreRequested));
        Assert.Equal(ShellState.WaitingReady, machine.Transition(ShellEvent.CoreProcessStarted));
        Assert.Equal(ShellState.WindowShown, machine.Transition(ShellEvent.CoreReady));
        _output.WriteLine($"[STATE] 启动三行走完 = {machine.State}");
    }

    [Fact]
    public void CloseAndReopenFromTray()
    {
        var machine = new ShellStateMachine();
        machine.Transition(ShellEvent.StartCoreRequested);
        machine.Transition(ShellEvent.CoreProcessStarted);
        machine.Transition(ShellEvent.CoreReady);

        Assert.Equal(ShellState.HiddenToTray, machine.Transition(ShellEvent.UserClosedWindow));
        Assert.Equal(ShellState.WindowShown, machine.Transition(ShellEvent.TrayOpenRequested));
        _output.WriteLine($"[STATE] 关窗再打开 = {machine.State}");
    }

    [Fact]
    public void SecondInstanceRequestWhileNotReadyIsRememberedNotDropped()
    {
        var machine = new ShellStateMachine();
        machine.Transition(ShellEvent.StartCoreRequested);
        var state = machine.Transition(ShellEvent.SecondInstanceOpenRequested);
        _output.WriteLine($"[STATE] 未就绪时的打开请求 ⇒ state={state} pendingOpen={machine.PendingOpen}");
        Assert.True(state == ShellState.StartingCore,
            $"未就绪时不该因为外部请求就跳状态（实际 {state}）");
        Assert.True(machine.PendingOpen, "第二实例的打开请求必须记成 pendingOpen（不许丢）");

        machine.Transition(ShellEvent.CoreProcessStarted);
        machine.Transition(ShellEvent.CoreReady);
        Assert.True(machine.PendingOpen, "就绪前不能被清掉（要等到窗口真的显示时再消费）");
        Assert.True(machine.ConsumePendingOpen(), "就绪后消费一次：窗口直接被显示");
        Assert.False(machine.PendingOpen);
        Assert.False(machine.ConsumePendingOpen(), "消费一次就清空（不该重复消费）");
    }

    [Fact]
    public void ExitGoesThroughStoppingFromShownAndHidden()
    {
        foreach (var start in new[] { ShellState.WindowShown, ShellState.HiddenToTray })
        {
            var machine = new ShellStateMachine();
            machine.ForceStateForTests(start);
            var state = machine.Transition(ShellEvent.ExitRequested);
            _output.WriteLine($"[STATE] {start} + 退出 ⇒ {state}");
            Assert.Equal(ShellState.Stopping, state);
        }
    }

    [Fact]
    public void UnexpectedCoreExitFromShownOrHiddenIsCrashed()
    {
        foreach (var start in new[] { ShellState.WindowShown, ShellState.HiddenToTray })
        {
            var machine = new ShellStateMachine();
            machine.ForceStateForTests(start);
            var state = machine.Transition(ShellEvent.CoreUnexpectedExit);
            _output.WriteLine($"[STATE] {start} + 核心非预期退出 ⇒ {state}");
            Assert.Equal(ShellState.CoreCrashed, state);
        }
    }

    [Fact]
    public void RestartFromCrashGoesBackToStartingCore()
    {
        var machine = new ShellStateMachine();
        machine.ForceStateForTests(ShellState.HiddenToTray);
        machine.Transition(ShellEvent.CoreUnexpectedExit);
        Assert.Equal(ShellState.CoreCrashed, machine.State);
        var state = machine.Transition(ShellEvent.RestartCoreRequested);
        _output.WriteLine($"[STATE] 崩溃 + 重启核心 ⇒ {state}");
        Assert.Equal(ShellState.StartingCore, state);
    }

    [Fact]
    public void RestartFailureFromAnyStartupStageReturnsToCrashAndKeepsRestartAvailable()
    {
        // 任务 6.1e：显式重启失败可能发生在启动序列的任一阶段，必须回 CoreCrashed，
        // 而不是停在只有「退出」的启动态（那等于把「重启核心」入口弄丢了）。
        foreach (var failedAt in new[]
                 {
                     ShellState.StartingCore,
                     ShellState.WaitingReady,
                     ShellState.WindowShown,
                 })
        {
            var machine = new ShellStateMachine();
            machine.ForceStateForTests(ShellState.CoreCrashed);
            Assert.Equal(ShellState.StartingCore, machine.Transition(ShellEvent.RestartCoreRequested));
            machine.ForceStateForTests(failedAt);
            var state = machine.Transition(ShellEvent.RestartFailed);
            var menu = TrayMenuModel.Build(machine.State);
            _output.WriteLine(
                $"[STATE] {failedAt} + 重启失败 ⇒ {state}，菜单=" +
                $"[{string.Join(" / ", menu.Select(item => item.Text))}]");
            Assert.Equal(ShellState.CoreCrashed, state);
            Assert.Contains(menu, item => item.Text == TrayMenuText.RestartCore && item.Enabled);
        }
    }

    [Fact]
    public void StartupFailuresEndInFatalDialogNotInAWindow()
    {
        // Resolving 失败 ⇒ FatalDialog。
        var resolveFailed = new ShellStateMachine();
        _output.WriteLine($"[STATE] Resolving + 解析失败 ⇒ {resolveFailed.Transition(ShellEvent.ResolveFailed)}");
        Assert.Equal(ShellState.FatalDialog, resolveFailed.Transition(ShellEvent.ResolveFailed));

        // 就绪前子进程退出 / 预算耗尽 ⇒ FatalDialog（收尾要停核心，那条在 4.x 接线验）。
        var startFailed = new ShellStateMachine();
        startFailed.Transition(ShellEvent.StartCoreRequested);
        startFailed.Transition(ShellEvent.CoreProcessStarted);
        _output.WriteLine($"[STATE] StartingCore + 启动失败 ⇒ {startFailed.Transition(ShellEvent.StartFailed)}");
        Assert.Equal(ShellState.FatalDialog, startFailed.Transition(ShellEvent.StartFailed));
    }

    // ---------------------------------------------------------------------
    // WebView2FailurePolicy
    // ---------------------------------------------------------------------

    [Fact]
    public void WebView2FactoryFailureStopsCoreReleasesLockAndExitsNonZero()
    {
        var policy = new WebView2FailurePolicy(() =>
            throw new InvalidOperationException("缺 WebView2 运行时（Evergreen）"));
        var outcome = policy.CreateEnvironment(@"C:\Users\me\AppData\Local\AliasAgent\WebView2");
        _output.WriteLine($"[WEBVIEW2] Ok={outcome.Ok} Abort={outcome.Abort?.Describe()}");
        Assert.False(outcome.Ok);
        Assert.NotNull(outcome.Abort);
        Assert.True(outcome.Abort!.StopCore, "失败必须先停核心（不许留占着端口的孤儿核心）");
        Assert.True(outcome.Abort.ReleaseSingleInstanceLock, "失败必须释放单实例锁");
        Assert.NotEqual(0, outcome.Abort.ExitCode);
        Assert.Contains("WebView2", outcome.Abort.Message);
    }

    [Fact]
    public void WebView2FailureForUnwritableUserDataFolderNamesTheFolder()
    {
        var folder = @"C:\read-only\WebView2";
        var policy = new WebView2FailurePolicy(() =>
            throw new IOException($"用户数据目录不可写：{folder}"));
        var outcome = policy.CreateEnvironment(folder);
        _output.WriteLine($"[WEBVIEW2] 目录不可写 ⇒ {outcome.Abort?.Describe()}");
        Assert.False(outcome.Ok);
        Assert.Contains(folder, outcome.Abort!.Message);
        Assert.True(outcome.Abort.StopCore);
    }

    [Fact]
    public void WebView2SuccessPathReturnsEnvironment()
    {
        var environment = new object();
        var policy = new WebView2FailurePolicy(() => environment);
        var outcome = policy.CreateEnvironment(@"C:\tmp\WebView2");
        _output.WriteLine($"[WEBVIEW2] Ok={outcome.Ok} 环境={outcome.Environment?.GetType().Name}");
        Assert.True(outcome.Ok);
        Assert.Same(environment, outcome.Environment);
        Assert.Null(outcome.Abort);
    }
}
