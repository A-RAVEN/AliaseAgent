namespace AliasAgent.Desktop;

/// <summary>关窗决策（change `windows-desktop-shell` D4）。</summary>
public enum WindowCloseDecision
{
    /// <summary>取消关闭 + `Hide()`：核心继续常驻，托盘图标还在。</summary>
    CancelAndHide,

    /// <summary>放行关闭（已经要求退出了，正常收尾路径）。</summary>
    Allow,
}

/// <summary>
/// 关窗策略：点关闭按钮只隐藏（关窗 ≠ 退出）。
///
/// 唯一例外是「已经要求退出」（托盘「退出」把 `exitRequested` 置上）：那时放行关闭，
/// 否则进程退不干净。
/// </summary>
public static class WindowClosePolicy
{
    public static WindowCloseDecision Decide(bool exitRequested) =>
        exitRequested ? WindowCloseDecision.Allow : WindowCloseDecision.CancelAndHide;
}

/// <summary>壳的阶段（design D3 的进程状态机 + D4 的窗口/托盘状态机共用一张表）。</summary>
public enum ShellState
{
    Resolving,
    StartingCore,
    WaitingReady,
    WindowShown,
    HiddenToTray,
    CoreCrashed,
    Stopping,
    FatalDialog,
}

/// <summary>托盘菜单项（文本 + 是否可点）。</summary>
public sealed record TrayMenuItem(string Text, bool Enabled = true);

/// <summary>托盘菜单文案（用户文档与守卫都读它）。</summary>
public static class TrayMenuText
{
    public const string OpenWindow = "打开窗口";
    public const string RestartCore = "重启核心";
    public const string Exit = "退出";
}

/// <summary>
/// 托盘菜单模型（design D4）：
///   - 启动期（`StartingCore` / `WaitingReady`）只有「退出」——不提供点了什么都不发生的项；
///   - 正常态（`WindowShown` / `HiddenToTray`）「打开窗口」+「退出」；
///   - 崩溃态（`CoreCrashed`）追加「重启核心」（显式重启，不自动重启）。
/// </summary>
public static class TrayMenuModel
{
    public static IReadOnlyList<TrayMenuItem> Build(ShellState state) => state switch
    {
        ShellState.StartingCore or ShellState.WaitingReady or ShellState.Resolving
            or ShellState.Stopping or ShellState.FatalDialog =>
            new[] { new TrayMenuItem(TrayMenuText.Exit) },
        ShellState.CoreCrashed =>
            new[]
            {
                new TrayMenuItem(TrayMenuText.OpenWindow),
                new TrayMenuItem(TrayMenuText.RestartCore),
                new TrayMenuItem(TrayMenuText.Exit),
            },
        _ => new[]
        {
            new TrayMenuItem(TrayMenuText.OpenWindow),
            new TrayMenuItem(TrayMenuText.Exit),
        },
    };
}

/// <summary>状态机事件（design D3 / D4 表的行号就是这一组）。</summary>
public enum ShellEvent
{
    StartCoreRequested,
    CoreProcessStarted,
    CoreReady,
    UserClosedWindow,
    TrayOpenRequested,
    SecondInstanceOpenRequested,
    ExitRequested,
    CoreUnexpectedExit,
    RestartCoreRequested,

    /// <summary>
    /// 显式重启失败（任务 6.1e）：本次尝试起的核心没成功（仓库根/预检失败、核心起不来、
    /// 就绪前退出、预算耗尽、WebView2 初始化失败）⇒ 回 <see cref="ShellState.CoreCrashed"/>，
    /// 保持托盘「重启核心」可用（spec「显式重启恢复」：失败不许变成静默无响应）。
    /// </summary>
    RestartFailed,

    ResolveFailed,
    StartFailed,
}

/// <summary>
/// 壳的状态机（design D4 表逐行迁移）。
///
/// `PendingOpen` 是「窗口还没就绪时第二实例请求打开」的记忆位：就绪开窗时直接显示，
/// **不许丢**。它是显式状态而不是靠事件重放，所以能在测试里被断言。
///
/// 显式重启是从 `CoreCrashed` 出发的：`RestartCoreRequested` 迁到 `StartingCore`，
/// 失败时由 `RestartFailed` 迁回 `CoreCrashed`（任务 6.1e）——壳留在崩溃态、菜单仍有
/// 「重启核心」，而不是退回成一个看起来正常的窗口或静默卡在启动态。
/// </summary>
public sealed class ShellStateMachine
{
    private readonly Action<string> _log;

    public ShellStateMachine(Action<string>? log = null)
    {
        _log = log ?? (_ => { });
    }

    public ShellState State { get; private set; } = ShellState.Resolving;

    /// <summary>第二实例的打开请求是否还欠着（就绪后消费一次）。</summary>
    public bool PendingOpen { get; private set; }

    /// <summary>仅测试用：把状态机摆到某个态（验证该态出发的迁移）。</summary>
    public void ForceStateForTests(ShellState state)
    {
        State = state;
    }

    /// <summary>消费 pendingOpen：返回是否真的欠着一次「打开窗口」。</summary>
    public bool ConsumePendingOpen()
    {
        if (!PendingOpen) return false;
        PendingOpen = false;
        return true;
    }

    public ShellState Transition(ShellEvent @event)
    {
        var next = Compute(State, @event);
        _log($"[shell] 状态迁移：{State} --{@event}--> {next}" +
             (PendingOpen ? "（pendingOpen 仍欠着）" : string.Empty));
        State = next;
        return next;
    }

    private ShellState Compute(ShellState current, ShellEvent @event)
    {
        // 第二实例的打开请求：窗口未就绪时只记 pendingOpen，不改状态（D4 那一行）。
        if (@event == ShellEvent.SecondInstanceOpenRequested)
        {
            if (current is ShellState.Resolving or ShellState.StartingCore or ShellState.WaitingReady)
            {
                PendingOpen = true;
                return current;
            }

            // 窗口已就绪：隐藏就显示出来，可见就只激活。
            return current == ShellState.HiddenToTray ? ShellState.WindowShown : current;
        }

        switch (@event)
        {
            case ShellEvent.ResolveFailed:
                return ShellState.FatalDialog;

            case ShellEvent.StartCoreRequested:
                return ShellState.StartingCore;

            case ShellEvent.CoreProcessStarted:
                return ShellState.WaitingReady;

            case ShellEvent.CoreReady:
                return ShellState.WindowShown;

            case ShellEvent.UserClosedWindow:
                return current == ShellState.WindowShown ? ShellState.HiddenToTray : current;

            case ShellEvent.TrayOpenRequested:
                return current == ShellState.HiddenToTray ? ShellState.WindowShown : current;

            case ShellEvent.ExitRequested:
                return ShellState.Stopping;

            case ShellEvent.CoreUnexpectedExit:
                return current is ShellState.WindowShown or ShellState.HiddenToTray
                    ? ShellState.CoreCrashed
                    : current;

            case ShellEvent.RestartCoreRequested:
                return current == ShellState.CoreCrashed ? ShellState.StartingCore : current;

            case ShellEvent.RestartFailed:
                // 重启失败可能发生在启动序列的任一阶段（StartingCore / WaitingReady），
                // 也可能在 WebView2 初始化失败时已经到了 WindowShown。三种都回崩溃态，
                // 让托盘菜单重新出现「重启核心」（不留在只有「退出」的启动态）。
                return current is ShellState.StartingCore or ShellState.WaitingReady
                    or ShellState.WindowShown
                    ? ShellState.CoreCrashed
                    : current;

            case ShellEvent.StartFailed:
                return ShellState.FatalDialog;

            default:
                return current;
        }
    }
}

/// <summary>
/// 一次「启动失败要怎么办」的决策（不是一句错误串）。
///
/// 启动路径上任一步失败（含 WebView2 初始化）都要**先回收**：停核心 + 放单实例锁，
/// 再给可归因提示并非零退出 —— 否则会留下占着固定端口的孤儿核心，下次启动变成
/// 「已有核心在运行」，把环境问题伪装成壳坏了。
/// </summary>
public sealed class ShellAbortDecision
{
    public ShellAbortDecision(bool stopCore, bool releaseSingleInstanceLock, int exitCode, string message)
    {
        StopCore = stopCore;
        ReleaseSingleInstanceLock = releaseSingleInstanceLock;
        ExitCode = exitCode;
        Message = message;
    }

    public bool StopCore { get; }

    public bool ReleaseSingleInstanceLock { get; }

    public int ExitCode { get; }

    public string Message { get; }

    public string Describe() =>
        $"StopCore={StopCore} ReleaseLock={ReleaseSingleInstanceLock} ExitCode={ExitCode} Message={Message}";
}

/// <summary>WebView2 环境创建结果：成功给环境，失败给**决策**。</summary>
public sealed class WebView2CreateOutcome
{
    public WebView2CreateOutcome(object? environment, ShellAbortDecision? abort)
    {
        Environment = environment;
        Abort = abort;
    }

    public bool Ok => Abort == null;

    public object? Environment { get; }

    public ShellAbortDecision? Abort { get; }
}

/// <summary>
/// WebView2 初始化失败的资源回收策略（design D4 / 任务 3.10）。
///
/// 环境工厂注入（生产 = `CoreWebView2Environment.CreateAsync(null, userDataFolder, null)`；
/// 测试 = 抛错的假工厂）：失败时**不许只返回错误串**，必须给出「停核心 + 放锁 +
/// 非零退出」的决策，并把可操作文案（缺运行时 / 目录不可写）带出来。
/// </summary>
public sealed class WebView2FailurePolicy
{
    /// <summary>启动期失败统一用非零退出码 1（与「参数错误 = 2 / 停机告警 = 3」区分）。</summary>
    public const int StartupFailureExitCode = 1;

    private readonly Func<object> _environmentFactory;

    public WebView2FailurePolicy(Func<object> environmentFactory)
    {
        _environmentFactory = environmentFactory ?? throw new ArgumentNullException(nameof(environmentFactory));
    }

    public WebView2CreateOutcome CreateEnvironment(string userDataFolder)
    {
        try
        {
            return new WebView2CreateOutcome(_environmentFactory(), null);
        }
        catch (Exception e)
        {
            return Failure(e, userDataFolder);
        }
    }

    /// <summary>
    /// 异步初始化（生产路径：`CoreWebView2Environment.CreateAsync` 会真的 await）失败时
    /// 的决策。语义与 <see cref="CreateEnvironment"/> 完全一致 —— 同一个失败策略，只是
    /// 入口不同（同步假工厂 vs 真异步初始化）。
    /// </summary>
    public WebView2CreateOutcome Failure(Exception error, string userDataFolder) =>
        new(null,
            new ShellAbortDecision(
                stopCore: true,
                releaseSingleInstanceLock: true,
                exitCode: StartupFailureExitCode,
                message: BuildMessage(error, userDataFolder)));

    private static string BuildMessage(Exception error, string userDataFolder)
    {
        var text = error.Message ?? string.Empty;
        var looksLikeMissingRuntime =
            text.Contains("WebView2", StringComparison.OrdinalIgnoreCase) ||
            text.Contains("Evergreen", StringComparison.OrdinalIgnoreCase) ||
            text.Contains("0x8007", StringComparison.OrdinalIgnoreCase);
        var looksLikeFolderProblem =
            error is IOException ||
            error is UnauthorizedAccessException ||
            text.Contains("不可写", StringComparison.Ordinal) ||
            text.Contains("denied", StringComparison.OrdinalIgnoreCase);

        if (looksLikeFolderProblem)
        {
            return $"初始化 WebView2 失败：用户数据目录不可用（{userDataFolder}）：{text}。" +
                   "换一个有写权限的目录，或用 --config 指定别的用户目录后重试。";
        }

        if (looksLikeMissingRuntime)
        {
            return "初始化 WebView2 失败：缺 WebView2 运行时" +
                   "（Windows 11 自带，缺失需安装 Evergreen 版）：" + text;
        }

        return $"初始化 WebView2 失败（用户数据目录 {userDataFolder}）：{text}";
    }
}
