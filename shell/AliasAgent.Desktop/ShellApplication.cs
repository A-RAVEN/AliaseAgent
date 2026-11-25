using System.Diagnostics;
using System.Drawing;
using System.Windows.Forms;

namespace AliasAgent.Desktop;

/// <summary>
/// 壳的生命周期接线（change `windows-desktop-shell` D3 / D4 / D5 / 任务 4.2）。
///
/// 启动序列（design 的顺序，不许调换）：
///   解析仓库根与端口 → 预检 → **先建托盘图标**（冷启动期间也看得见壳在跑）→
///   起核心子进程（工作目录 = 仓库根）+ 加入 Job Object → 轮询 `core.ping` →
///   开窗并导航到固定地址。
///
/// 关窗 = 隐藏（<see cref="WindowClosePolicy"/>）；托盘「退出」才真退：礼停（上限
/// 5000ms）→ 超时杀树 → 极端兜底先发气泡 → 释放托盘图标 → 退出 0。
/// </summary>
internal sealed class ShellApplication : ApplicationContext
{
    /// <summary>`ShowBalloonTip` 的必填超时（API 没有无参重载；Vista 之后实际时长由系统控制）。</summary>
    private const int kBalloonTipTimeoutMs = 5000;

    /// <summary>礼停等待上限（design D3 第 2 步）。</summary>
    private static readonly TimeSpan kGracefulStopTimeout = TimeSpan.FromMilliseconds(5000);

    private readonly DesktopOptions _options;
    private readonly SingleInstance _singleInstance;
    private readonly ShellLogger _logger;
    private readonly ShellStateMachine _state;
    private readonly UiThreadMarshaller _uiMarshaller;
    private readonly Func<Task>? _startupOverride;

    /// <summary>
    /// 启动失败对话框的落点（仅测试注入；生产为 null = 真 `MessageBox.Show`）。
    /// 6.1e 的首次启动回归用例需要在不弹真实窗口的前提下断言「首次启动失败仍退出」。
    /// </summary>
    private readonly Action<string, string>? _startupFailureDialog;

    private readonly CancellationTokenSource _cts = new();

    private NotifyIcon? _tray;
    private MainForm? _form;
    private CoreLauncher? _launcher;

    /// <summary>
    /// 当前挂着**永久崩溃订阅**的 launcher（任务 6.1b）。重启会新建 launcher，换订前先把
    /// 旧实例解绑，保证每个 launcher 只留一个订阅、不叠加也不泄漏。
    /// </summary>
    private CoreLauncher? _crashHandlerLauncher;

    private JobObject? _job;
    private Task? _secondInstanceWatcher;
    private bool _exitRequested;
    private bool _hiddenHintShown;
    private bool _started;
    private int _port;

    public ShellApplication(DesktopOptions options, SingleInstance singleInstance, ShellLogger logger)
        : this(options, singleInstance, logger, startupOverride: null, startupFailureDialog: null)
    {
    }

    /// <summary>
    /// 测试接缝（`InternalsVisibleTo` 给测试工程）：把真实启动序列换成空实现，用来在一条真实
    /// 消息循环里验「捕获点 + Post 送达」这段接线（任务 6.1a），不真的起核心 / 开窗。
    ///
    /// <paramref name="startupFailureDialog"/> 同为本工程测试接缝（任务 6.1e）：只替换
    /// 「首次启动失败对话框」这一个外部副作用，生产不传 = 真 `MessageBox.Show`；
    /// 这样「重启失败不许走首次启动退出路径」可以在无窗口测试里被断言。
    /// </summary>
    internal ShellApplication(
        DesktopOptions options,
        SingleInstance singleInstance,
        ShellLogger logger,
        Func<Task>? startupOverride,
        Action<string, string>? startupFailureDialog = null)
    {
        _options = options;
        _singleInstance = singleInstance;
        _logger = logger;
        _startupOverride = startupOverride;
        _startupFailureDialog = startupFailureDialog;
        _state = new ShellStateMachine(line => _logger.Write(line));
        // 注意：**这里不许捕获 SynchronizationContext**。构造发生在 Program.Main 的
        // Application.Run 之前，此时 Current 是 null（6.2(g) 的根因）；捕获点见 StartOnce。
        _uiMarshaller = new UiThreadMarshaller(log: line => _logger.Write(line));
        // 消息循环起来之后再启动（async 续体会回到 UI 线程）。
        Application.Idle += StartOnce;
    }

    /// <summary>
    /// 本次启动序列的上下文（任务 6.1e）。
    ///
    /// 首次启动失败必须「回收 + 非零退出」；崩溃后的显式重启失败则**不许退出**：
    /// 壳要留在 `CoreCrashed`、给出可归因提示并保持「重启核心」可用
    /// （spec「显式重启恢复」）。两条路共用同一段启动序列，但失败处置必须分流。
    /// </summary>
    private enum StartupMode
    {
        FirstLaunch,
        RestartAfterCrash,
    }

    /// <summary>仅测试用：暴露给 xunit 断言「消息循环起来之后才捕获」的接缝。</summary>
    internal UiThreadMarshaller UiMarshallerForTests => _uiMarshaller;

    /// <summary>
    /// 仅测试用：读状态机 / 把状态摆到某个前置态（任务 6.1b 的行为用例要验「运行态」下的
    /// 崩溃迁移；生产里的状态迁移只由事件驱动）。
    /// </summary>
    internal ShellStateMachine StateMachineForTests => _state;

    /// <summary>
    /// 仅测试用：装一个**不显示、不初始化 WebView2** 的 <see cref="MainForm"/>，让
    /// `HandleCoreCrashed` 的错误页那条路径可被断言（它只读 `_webView.CoreWebView2`，未初始化
    /// 时为 null，不会创建窗口）。生产路径在 `StartupCoreAsync` 里创建真窗口并 `Show()`。
    /// </summary>
    internal void SetFormForTests(MainForm form)
    {
        _form = form ?? throw new ArgumentNullException(nameof(form));
    }

    private void StartOnce(object? sender, EventArgs e)
    {
        Application.Idle -= StartOnce;
        if (_started) return;
        _started = true;

        // 捕获点必须在这里：Application.Run 已经在跑，WindowsFormsSynchronizationContext 已安装。
        // 第二实例的监听线程只有经它 Post，才能把「打开窗口」请求送回 UI 线程（任务 6.1a）。
        if (!_uiMarshaller.Capture())
        {
            // 极端兜底：消息循环已在跑但宿主没装同步上下文时，显式装一个。否则监听线程的
            // Post 会一直丢弃，第二实例请求永远到不了 UI 线程（不静默退化）。
            SynchronizationContext.SetSynchronizationContext(new WindowsFormsSynchronizationContext());
            _uiMarshaller.Capture();
        }

        _ = StartupAsync();
    }

    private void Log(string line)
    {
        _logger.Write(line);
    }

    private async Task StartupAsync()
    {
        if (_startupOverride != null)
        {
            // 测试接缝：只验「消息循环起来 → 捕获 → Post 送达」这段接线。
            await _startupOverride().ConfigureAwait(true);
            return;
        }

        try
        {
            await StartupCoreAsync(StartupMode.FirstLaunch).ConfigureAwait(true);
        }
        catch (Exception e)
        {
            Log($"[shell] 启动序列未预期异常：{e}");
            await FailStartupAsync(StartupMode.FirstLaunch, "启动失败", $"未预期异常：{e.Message}",
                includeCoreDetails: true).ConfigureAwait(true);
        }
    }

    private async Task StartupCoreAsync(StartupMode mode)
    {
        // ① 解析仓库根（显式 --repo-root 优先）。
        string repoRoot;
        try
        {
            repoRoot = _options.RepoRoot ?? new RepoRootLocator().Locate();
        }
        catch (RepoRootNotFoundException e)
        {
            Log($"[shell] 仓库根定位失败：{e.Message}");
            await FailStartupAsync(mode, "启动失败：找不到仓库根", e.Message, includeCoreDetails: false)
                .ConfigureAwait(true);
            return;
        }

        Log($"[shell] 仓库根={repoRoot}");

        // ② 端口（--port > 配置 core.port > 默认）；配置那一级的回落日志由 resolver 写。
        var configPath = _options.ConfigPath ?? ShellPaths.ConfigPath;
        var resolver = new CorePortResolver(Log);
        var configuredPort = resolver.Resolve(configPath);
        _port = _options.CliPort ?? configuredPort;
        Log($"[shell] 端口={_port}（来源：{(_options.CliPort.HasValue ? "--port 显式参数" : "配置/默认")}；" +
            $"配置文件={configPath}）");

        // ③ 预检：web 产物、dart、仓库根。缺一项都不继续（否则窗口里只有 503 文本）。
        DartExecutable? dart = null;
        string? dartError = null;
        try
        {
            dart = new DartExecutableResolver().Resolve();
        }
        catch (DartNotFoundException e)
        {
            dartError = e.Message;
            Log($"[shell] dart 解析失败：{e.Message}");
        }

        var preflight = new Preflight().Check(new PreflightInputs
        {
            RepoRoot = repoRoot,
            Dart = dart,
            DartError = dartError,
        });
        if (!preflight.Ok)
        {
            var message = string.Join("\n\n", preflight.Problems);
            Log($"[shell] 预检失败：{message}");
            await FailStartupAsync(mode, "启动失败：环境不满足", message, includeCoreDetails: false)
                .ConfigureAwait(true);
            return;
        }

        // ④ 先建托盘图标（核心还没起来），让冷启动等待可见。
        CreateTray();
        _state.Transition(ShellEvent.StartCoreRequested);
        RefreshTrayMenu();

        // ⑤ 起核心子进程。
        var command = CoreCommandBuilder.Build(dart!, repoRoot, _port, configPath);
        var shutdownSender = new WebSocketCoreShutdownSender(Log);
        var launcher = new CoreLauncher(
            command,
            Log,
            gracefulStop: shutdownSender.RequestShutdownAsync,
            gracefulStopTimeout: kGracefulStopTimeout,
            killTimeout: kGracefulStopTimeout);
        _launcher = launcher;
        Process process;
        try
        {
            process = launcher.Start();
        }
        catch (Exception e)
        {
            Log($"[shell] 核心启动失败：{e.Message}");
            await FailStartupAsync(mode, "启动失败：核心进程起不来", e.Message, includeCoreDetails: false)
                .ConfigureAwait(true);
            return;
        }

        // 重启会为本次核心新建 Job Object；上一次核心的句柄先释放，避免每次重启泄漏一个
        // Job 句柄（旧核心此时已退出，KILL_ON_JOB_CLOSE 不会误伤新进程——它尚未入 Job）。
        _job?.Dispose();
        _job = JobObject.TryAttach(process, Log);
        _state.Transition(ShellEvent.CoreProcessStarted);
        RefreshTrayMenu();

        // ⑥ 就绪探测与「子进程已退出」同时监听，先到者决定结果。
        var exitTcs = new TaskCompletionSource<int>(TaskCreationOptions.RunContinuationsAsynchronously);
        void OnExit(int code) => exitTcs.TrySetResult(code);
        _launcher.UnexpectedExit += OnExit;
        var probe = new CoreReadinessProbe(Log);
        var readyTask = probe.WaitUntilReadyAsync(_port, _cts.Token);
        var first = await Task.WhenAny(readyTask, exitTcs.Task).ConfigureAwait(true);
        _launcher.UnexpectedExit -= OnExit;

        if (first == exitTcs.Task)
        {
            var exitCode = await exitTcs.Task.ConfigureAwait(true);
            var lastLine = _launcher.LastOutputLine ?? "(无输出)";
            Log($"[shell] 核心在就绪前退出（exit={exitCode}）：{lastLine}");
            await FailStartupAsync(
                mode,
                "启动失败：核心在就绪前退出",
                $"核心进程退出码 {exitCode}。\n最后一行输出：{lastLine}\n" +
                $"日志：{_logger.LogPath}\n\n常见原因：已有核心在运行（单实例锁被占）、" +
                $"端口 {_port} 被占用、或配置损坏。",
                includeCoreDetails: true).ConfigureAwait(true);
            return;
        }

        bool ready;
        try
        {
            ready = await readyTask.ConfigureAwait(true);
        }
        catch (Exception e)
        {
            Log($"[shell] 就绪探测异常：{e.Message}");
            ready = false;
        }

        if (!ready)
        {
            Log($"[shell] 核心在 {CoreReadinessProbe.TotalBudgetMs}ms 内没有响应 core.ping");
            await FailStartupAsync(
                mode,
                "启动失败：核心没有就绪",
                $"核心在 {CoreReadinessProbe.TotalBudgetMs} 毫秒内没有响应 core.ping。\n" +
                $"端口：{_port}\n日志：{_logger.LogPath}",
                includeCoreDetails: true).ConfigureAwait(true);
            return;
        }

        // ⑦ 就绪后接线：窗口（重启时复用）、窗口显示、托盘菜单、运行态崩溃订阅。
        if (!await ShowWindowAfterReadyAsync(launcher, showWindow: true, mode).ConfigureAwait(true))
        {
            return;
        }

        // ⑧ 第一实例：把 pid 写进命名共享内存 + 后台等「打开窗口」事件。
        _singleInstance.WriteOwnPid(Environment.ProcessId);
        StartSecondInstanceWatcher();
        Log("[shell] 启动完成：窗口已显示");
    }

    /// <summary>
    /// 核心已就绪之后的真实接线（启动与重启共用；任务 6.1c / 6.1d）。
    ///
    /// 顺序：
    ///   1. 状态迁到 `WindowShown`（从这一刻起菜单模型是「打开窗口 + 退出」）；
    ///   2. **重启时复用既有窗口**（6.1d）：旧窗口还在就不新建，只重新导航回壳地址；
    ///      只有首次启动或旧窗口已释放才新建 MainForm 并初始化 WebView2；
    ///   3. 显示窗口（生产 true；测试 false，避免在用户桌面弹窗）；
    ///   4. 运行态崩溃永久订阅（6.1b）后**刷新托盘菜单**（6.1c）——窗口已经显示，
    ///      菜单必须从启动期的「只有退出」切到正常态。
    ///
    /// 返回 false 表示 WebView2 初始化失败。首次启动走「回收 + 退出」，重启走
    /// <see cref="FailRestartAsync"/>「回收本次核心 + 回崩溃态、壳不退出」（任务 6.1e）；
    /// 两种情况下调用方都不许继续写 pid / 开监听。
    /// </summary>
    private async Task<bool> ShowWindowAfterReadyAsync(
        CoreLauncher launcher,
        bool showWindow,
        StartupMode mode)
    {
        _state.Transition(ShellEvent.CoreReady);

        // 6.1d：重启会重走这里。旧窗口还在就复用（重新导航），不许再 new 一个留在屏幕上。
        var reused = TryReuseExistingWindow();
        if (!reused)
        {
            // 首次启动（或旧窗口已释放）：WebView2 初始化失败要**先回收**（停核心 + 放锁）
            // 再弹可归因对话框；重启路径则回崩溃态、壳继续运行（6.1e）。
            _form = new MainForm($"http://127.0.0.1:{_port}/", Log);
            _form.FormClosing += OnFormClosing;
            var policy = new WebView2FailurePolicy(() =>
                throw new InvalidOperationException("生产路径用异步初始化（见 MainForm.InitializeWebView2Async）"));
            var webViewOk = await _form.InitializeWebView2Async(policy, ShellPaths.WebView2UserDataFolder)
                .ConfigureAwait(true);
            if (!webViewOk)
            {
                var abort = _form.AbortDecision;
                Log($"[shell] WebView2 初始化失败，开始回收：{abort?.Describe()}");
                if (mode == StartupMode.RestartAfterCrash)
                {
                    // 重启路径：不许整壳退出（6.1e）。错误页可能也显示不了（WebView2 本身失败），
                    // 但气泡 + 日志仍把原因、日志路径与「重启核心」的入口给出去。
                    await FailRestartAsync("WebView2 初始化失败",
                        abort?.Message ?? "初始化 WebView2 失败。", includeCoreDetails: false)
                        .ConfigureAwait(true);
                    return false;
                }

                await RecycleAfterWebView2FailureAsync().ConfigureAwait(true);
                ShowStartupFailureDialog("启动失败", abort?.Message ?? "初始化 WebView2 失败。");
                Environment.ExitCode = abort?.ExitCode ?? WebView2FailurePolicy.StartupFailureExitCode;
                ExitThread();
                return false;
            }
        }

        MainForm = _form;
        if (showWindow)
        {
            _form!.Show();
            _form.ShowAndActivate();
            if (_state.ConsumePendingOpen())
            {
                // 第二实例在启动期就请求过打开：窗口一就绪直接显示（不丢请求）。
                _form.ShowAndActivate();
            }
        }

        // 运行态：窗口已就绪，把「核心非预期退出」永久接到 UI 线程的崩溃处理（任务 6.1b）。
        // 启动期的临时 OnExit 已在上面解绑；从这一刻起核心再退出就是崩溃，不是启动失败。
        AttachCoreCrashHandler(launcher);

        // 6.1c：窗口显示后必须刷新托盘菜单。最后一次刷新停在 `CoreProcessStarted`
        // （`WaitingReady` 态只有「退出」），不补这一次，启动完成后的右键菜单就会缺
        // 「打开窗口」，要等首次关窗/开窗才恢复。启动与重启都经过这里。
        RefreshTrayMenu();
        return true;
    }

    /// <summary>
    /// 重启时处置旧窗口（任务 6.1d）：旧窗口还在就复用并重新导航回壳地址，返回 true。
    ///
    /// 为什么不能直接 `Close()` 旧窗口：`MainForm` 挂着 `FormClosing += OnFormClosing`，
    /// 非退出态下该处理会 `e.Cancel = true` + `Hide()` —— 直接关只会把它藏起来，旧错误页
    /// 窗口仍然存在。复用同一实例既避免两个窗口，也省掉第二个 WebView2 的初始化。
    /// </summary>
    private bool TryReuseExistingWindow()
    {
        var form = _form;
        if (form == null || form.IsDisposed) return false;
        Log("[shell] 重启：复用既有窗口（不新建第二个），重新导航回壳地址");
        form.ReloadShellPage($"http://127.0.0.1:{_port}/");
        return true;
    }

    /// <summary>
    /// 仅测试用：走「核心已就绪 → 窗口/托盘/崩溃订阅」这段真实生产接线，但不 `Show()` 窗口
    /// （xunit 不许在用户桌面弹窗）。测试用 `SetFormForTests` 预装窗口以走复用路径，
    /// 因此也不会真的初始化 WebView2。
    /// </summary>
    internal Task<bool> ShowWindowAfterReadyForTestsAsync(
        CoreLauncher launcher,
        bool restartAfterCrash = false) =>
        ShowWindowAfterReadyAsync(
            launcher,
            showWindow: false,
            mode: restartAfterCrash ? StartupMode.RestartAfterCrash : StartupMode.FirstLaunch);

    // ---------------------------------------------------------------------
    // 托盘
    // ---------------------------------------------------------------------

    private void CreateTray()
    {
        if (_tray != null) return;
        _tray = new NotifyIcon
        {
            // 首版用系统默认图标（不做美术资源）。
            Icon = SystemIcons.Application,
            Text = "AliasAgent 正在启动核心",
            Visible = true,
        };
        _tray.DoubleClick += (_, _) => OnOpenWindowRequested();
        RefreshTrayMenu();
        Log("[shell] 托盘图标已创建（启动期可见）");
    }

    /// <summary>
    /// 仅测试用：最近一次刷新出的托盘菜单模型（生产里由 `NotifyIcon.ContextMenuStrip` 渲染）。
    /// 6.1c 的行为用例要能断言「启动完成后菜单确实被刷成了正常态」，而不是只读菜单模型类。
    /// </summary>
    internal IReadOnlyList<TrayMenuItem> LastTrayMenuForTests { get; private set; } =
        Array.Empty<TrayMenuItem>();

    /// <summary>
    /// 仅测试用：最近一次发出的托盘气泡（任务 6.1e 要断言「重启失败给了可归因提示」）。
    ///
    /// 生产里由 `NotifyIcon.ShowBalloonTip` 显示；测试不建托盘，但仍经同一个
    /// <see cref="ShowBalloon"/> 入口记录，保证「有没有提示」不是靠日志猜的。
    /// </summary>
    internal (string Title, string Text, ToolTipIcon Icon)? LastBalloonForTests { get; private set; }

    private void ShowBalloon(string title, string text, ToolTipIcon icon)
    {
        LastBalloonForTests = (title, text, icon);
        _tray?.ShowBalloonTip(kBalloonTipTimeoutMs, title, text, icon);
    }

    private void RefreshTrayMenu()
    {
        var items = TrayMenuModel.Build(_state.State);
        // 先记模型再渲染：托盘对象不存在时（测试）也能观察「这次刷新到底给了什么菜单」。
        LastTrayMenuForTests = items;
        Log($"[shell] 托盘菜单已刷新：{_state.State} ⇒ " +
            $"[{string.Join(" / ", items.Select(item => item.Text))}]");
        if (_tray == null) return;

        var menu = new ContextMenuStrip();
        foreach (var item in items)
        {
            var menuItem = new ToolStripMenuItem(item.Text) { Enabled = item.Enabled };
            menuItem.Click += (_, _) => OnTrayMenuClicked(item.Text);
            menu.Items.Add(menuItem);
        }

        _tray.ContextMenuStrip = menu;
        _tray.Text = _state.State switch
        {
            ShellState.StartingCore => "AliasAgent 正在启动核心",
            ShellState.WaitingReady => "AliasAgent 正在等待核心就绪",
            ShellState.CoreCrashed => "AliasAgent（核心已退出）",
            _ => "AliasAgent",
        };
    }

    private void OnTrayMenuClicked(string text)
    {
        switch (text)
        {
            case TrayMenuText.OpenWindow:
                OnOpenWindowRequested();
                break;
            case TrayMenuText.RestartCore:
                _ = RestartCoreAsync();
                break;
            case TrayMenuText.Exit:
                _ = ExitAsync();
                break;
        }
    }

    // ---------------------------------------------------------------------
    // 关窗 / 打开 / 第二实例
    // ---------------------------------------------------------------------

    private void OnFormClosing(object? sender, FormClosingEventArgs e)
    {
        var decision = WindowClosePolicy.Decide(_exitRequested);
        if (decision == WindowCloseDecision.Allow) return;
        e.Cancel = true;
        _form?.Hide();
        _state.Transition(ShellEvent.UserClosedWindow);
        RefreshTrayMenu();
        Log("[shell] 窗口已隐藏到托盘（核心继续常驻）");
        if (!_hiddenHintShown && _tray != null)
        {
            _hiddenHintShown = true;
            // 防「幽灵进程」困惑的唯一可见信号。
            ShowBalloon("AliasAgent 仍在后台运行",
                "双击托盘图标可重新打开，右键菜单可退出。", ToolTipIcon.Info);
        }
    }

    private void OnOpenWindowRequested()
    {
        if (_form == null || _state.State is ShellState.StartingCore or ShellState.WaitingReady
                or ShellState.Resolving)
        {
            _state.Transition(ShellEvent.SecondInstanceOpenRequested);
            Log($"[shell] 打开窗口请求先记下（窗口未就绪，pendingOpen={_state.PendingOpen}）");
            return;
        }

        _state.Transition(ShellEvent.TrayOpenRequested);
        RefreshTrayMenu();
        _form.ShowAndActivate();
        _state.ConsumePendingOpen();
        Log("[shell] 窗口已从托盘显示并激活");
    }

    private void StartSecondInstanceWatcher()
    {
        if (_secondInstanceWatcher != null) return;
        _secondInstanceWatcher = Task.Run(() =>
        {
            while (!_cts.IsCancellationRequested)
            {
                try
                {
                    if (_singleInstance.WaitForOpenRequest(TimeSpan.FromMilliseconds(200)))
                    {
                        // 监听线程 → 消息循环起来之后捕获的 UI 上下文 → OnOpenWindowRequested。
                        // 未捕获时 Post 返回 false 并写日志（不静默丢；6.2(g) 的教训）。
                        if (!_uiMarshaller.Post(OnOpenWindowRequested))
                        {
                            Log("[shell] 第二实例的打开请求没有投递到 UI 线程（见上一条日志）");
                        }
                    }
                }
                catch (ObjectDisposedException)
                {
                    return;
                }
                catch (Exception e)
                {
                    Log($"[shell] 等待「打开窗口」事件失败：{e.Message}");
                    return;
                }
            }
        });
    }

    // ---------------------------------------------------------------------
    // 崩溃 / 重启
    // ---------------------------------------------------------------------

    /// <summary>
    /// 运行态：把「核心非预期退出」**永久**订阅到 UI 线程的崩溃处理（任务 6.1b）。
    ///
    /// 订阅点必须是就绪成功 + 窗口已显示之后：启动期只为「就绪前退出」判定临时订阅
    /// `UnexpectedExit`（见 `StartupCoreAsync` 的就绪等待），两者若同时生效，同一次退出会
    /// 既走启动失败对话框又进崩溃态。6.2(f) 的现场正是「启动完成后没有任何永久处理者」：
    /// `CoreLauncher` 的 `UnexpectedExit` 照常触发，但没有订阅者 ⇒ 壳什么都不做。
    ///
    /// 重启会再走一遍启动序列并**新建** `CoreLauncher`，所以换订前先解绑旧实例：
    /// 每个 launcher 只留一个订阅（不叠加、不泄漏旧实例）。
    /// </summary>
    internal void AttachCoreCrashHandler(CoreLauncher launcher)
    {
        ArgumentNullException.ThrowIfNull(launcher);
        if (_crashHandlerLauncher != null)
        {
            _crashHandlerLauncher.UnexpectedExit -= OnCoreUnexpectedExit;
        }

        _crashHandlerLauncher = launcher;
        launcher.UnexpectedExit += OnCoreUnexpectedExit;
        Log("[shell] 运行态：核心非预期退出已永久订阅（经 UI 同步上下文进入崩溃态）");
    }

    /// <summary>
    /// `CoreLauncher` 的 `Exited` 在**线程池线程**触发；托盘菜单、气泡、WebView2 错误页都
    /// 必须在 UI 线程。未捕获 UI 上下文时 `Post` 返回 false 并已写日志，这里再点名退出码，
    /// 让「崩溃处理没到 UI 线程」在日志里可归因（不静默丢）。
    /// </summary>
    private void OnCoreUnexpectedExit(int exitCode)
    {
        if (!_uiMarshaller.Post(() => HandleCoreCrashed(exitCode)))
        {
            Log($"[shell] 核心非预期退出（exit={exitCode}）没有投递到 UI 线程：崩溃态未处理");
        }
    }

    private void HandleCoreCrashed(int exitCode)
    {
        if (_exitRequested) return;
        _state.Transition(ShellEvent.CoreUnexpectedExit);
        RefreshTrayMenu();
        Log($"[shell] 核心非预期退出（exit={exitCode}）：进入崩溃态（不自动重启）");
        ShowBalloon("AliasAgent 核心已退出",
            $"退出码 {exitCode}。日志：{_logger.LogPath}。右键托盘菜单可「重启核心」。",
            ToolTipIcon.Error);
        _form?.ShowErrorPage(
            "核心已退出",
            $"核心进程非预期退出（退出码 {exitCode}）。",
            $"日志：{_logger.LogPath}。右键托盘菜单点「重启核心」重试。");
    }

    /// <summary>
    /// 崩溃后用户点「重启核心」（spec「显式重启恢复」/ 任务 6.1e）。
    ///
    /// 重新走启动序列时必须带 <see cref="StartupMode.RestartAfterCrash"/>：该模式的失败
    /// 只回收本次起的核心、回崩溃态并给提示，**不退出壳**。另外这里兜住启动序列的
    /// 未预期异常——生产里本方法由托盘点击 `_ = RestartCoreAsync()` 触发，异常若逃出去
    /// 就是「点了没反应」且状态卡在 StartingCore（菜单连「重启核心」都没有），
    /// 正是 spec 禁止的静默无响应。
    /// </summary>
    private async Task RestartCoreAsync()
    {
        Log("[shell] 用户要求重启核心");
        _state.Transition(ShellEvent.RestartCoreRequested);
        RefreshTrayMenu();
        try
        {
            // 重新走启动序列里「起核心 → 等就绪 → 导航」这一段。
            await StartupCoreAsync(StartupMode.RestartAfterCrash).ConfigureAwait(true);
        }
        catch (Exception e)
        {
            Log($"[shell] 重启核心时未预期异常：{e}");
            try
            {
                // 未预期异常可能发生在起核心之前（例如命令构造失败），此时 `_launcher`
                // 还可能是上次崩溃的旧实例；不要把旧核心的「最后一行输出」当成这次的原因。
                await FailRestartAsync("未预期异常", e.Message, includeCoreDetails: false)
                    .ConfigureAwait(true);
            }
            catch (Exception notifyFailure)
            {
                // 提示本身也失败时至少留日志，不许静默消失在启动态。
                Log($"[shell] 重启失败提示未能完成：{notifyFailure.Message}");
            }
        }
    }

    /// <summary>
    /// 仅测试用：走真实的「重启核心」入口（含真实的失败分流），不模拟失败。
    /// 6.1e 的行为用例要断言「重启失败后壳还在、状态回崩溃态、菜单仍有重启核心」。
    /// </summary>
    internal Task RestartCoreForTestsAsync() => RestartCoreAsync();

    // ---------------------------------------------------------------------
    // 退出：礼停 → 杀树 → （极端兜底气泡）→ 释放托盘 → 退出 0
    // ---------------------------------------------------------------------

    private async Task ExitAsync()
    {
        if (_exitRequested) return;
        _exitRequested = true;
        _state.Transition(ShellEvent.ExitRequested);
        RefreshTrayMenu();
        _cts.Cancel();
        Log("[shell] 用户要求退出：先礼停核心");

        if (_launcher != null)
        {
            var report = await _launcher.StopAsync().ConfigureAwait(true);
            Log($"[shell] 停机报告：{report.Describe()}");
            if (report.ExitCode == 3)
            {
                // 壳自己要求的停机：有告警但不是崩溃（spec 明确这条不许当崩溃）。
                Log("[shell] 核心停机有告警（exit=3），已写日志");
            }

            if (report.ExtremeFallback && _tray != null)
            {
                // 极端兜底：**气泡先发**，再释放图标（否则用户什么都看不到）。
                ShowBalloon("未能终止核心",
                    $"核心进程（pid={report.StillRunningPid}）没有在超时内被终止，壳将退出。" +
                    $"详见日志：{_logger.LogPath}",
                    ToolTipIcon.Warning);
            }
        }

        _job?.Dispose();
        _job = null;

        if (_tray != null)
        {
            _tray.Visible = false;
            _tray.Dispose();
            _tray = null;
        }

        try
        {
            _singleInstance.Dispose();
        }
        catch
        {
            // 已经释放。
        }

        // 放行关窗并结束消息循环（关窗策略此时返回 Allow）。
        _form?.Close();
        Environment.ExitCode = 0;
        Log("[shell] 壳退出（exit=0）");
        ExitThread();
    }

    // ---------------------------------------------------------------------
    // 启动失败
    // ---------------------------------------------------------------------

    /// <summary>
    /// 启动序列失败的统一入口（任务 6.1e：按上下文分流）。
    ///
    /// - 首次启动失败：回收（停核心 + 释放托盘/单实例锁）→ 可归因对话框 → 非零退出。
    ///   这条是 spec「启动失败的资源回收」要求的，不变。
    /// - 崩溃后的显式重启失败：**只**回收本次起的核心与 Job 句柄，壳继续运行、回崩溃态、
    ///   给可归因提示并保持「重启核心」可用（见 <see cref="FailRestartAsync"/>）。
    /// </summary>
    private async Task FailStartupAsync(
        StartupMode mode,
        string title,
        string detail,
        bool includeCoreDetails)
    {
        if (mode == StartupMode.RestartAfterCrash)
        {
            await FailRestartAsync(title, detail, includeCoreDetails).ConfigureAwait(true);
            return;
        }

        var lastLine = includeCoreDetails ? (_launcher?.LastOutputLine ?? "(无输出)") : null;
        var text = detail;
        if (includeCoreDetails)
        {
            text = $"{detail}\n\n最后一行输出：{lastLine}";
        }

        text = $"{text}\n\n日志：{_logger.LogPath}";
        Log($"[shell] 启动失败（{title}）：{text}");
        await RecycleAfterWebView2FailureAsync().ConfigureAwait(true);
        ShowStartupFailureDialog(title, text);
        Environment.ExitCode = WebView2FailurePolicy.StartupFailureExitCode;
        ExitThread();
    }

    /// <summary>
    /// 首次启动失败对话框的唯一出口（任务 6.1e 的测试接缝）。
    /// 生产不注入 = 真 `MessageBox.Show`；测试注入记录器，避免在用户桌面弹窗。
    /// </summary>
    private void ShowStartupFailureDialog(string title, string text)
    {
        var fullTitle = $"AliasAgent {title}";
        if (_startupFailureDialog != null)
        {
            _startupFailureDialog(fullTitle, text);
            return;
        }

        MessageBox.Show(text, fullTitle, MessageBoxButtons.OK, MessageBoxIcon.Error);
    }

    /// <summary>
    /// 崩溃后显式重启失败的处置（任务 6.1e / spec「显式重启恢复」）。
    ///
    /// 与首次启动失败的关键区别：壳**本来就在运行**，托盘图标与壳的单实例锁必须继续持有。
    /// 所以这里只做三件事：
    ///   ① 停掉本次尝试起的核心并释放 Job 句柄（不放托盘、不放壳锁）；
    ///   ② 状态迁回 `CoreCrashed` 并刷新托盘菜单（「重启核心」保持可用）；
    ///   ③ 给可归因提示：托盘气泡 + 窗口错误页 + 日志（点名原因与日志路径）。
    /// 任一启动失败分支（仓库根/预检、核心起不来、就绪前退出、预算耗尽、WebView2 失败）
    /// 都经这里收口，绝不 `ExitThread`。
    /// </summary>
    private async Task FailRestartAsync(string title, string detail, bool includeCoreDetails)
    {
        // 启动序列里的标题统一是「启动失败：…」；重启语境下改成原因本身，避免
        // 出现「重启核心失败（启动失败：…）」的叠词。只剥固定前缀，不做模糊替换。
        const string startupPrefix = "启动失败：";
        var summary = title.StartsWith(startupPrefix, StringComparison.Ordinal)
            ? title[startupPrefix.Length..]
            : title;

        var lastLine = includeCoreDetails ? (_launcher?.LastOutputLine ?? "(无输出)") : null;
        var text = detail;
        if (includeCoreDetails)
        {
            text = $"{detail}\n\n最后一行输出：{lastLine}";
        }

        text = $"{text}\n\n日志：{_logger.LogPath}";
        Log($"[shell] 重启核心失败（{summary}）：{text}");

        if (_exitRequested)
        {
            // 用户在重启过程中已经点了「退出」：不要再用失败提示打断收尾。
            Log("[shell] 已要求退出：重启失败不再给提示，按退出流程收尾");
            await RecycleForRestartFailureAsync().ConfigureAwait(true);
            return;
        }

        Log("[shell] 重启核心失败：壳保持运行（不退出），回到 CoreCrashed，「重启核心」仍可用");
        await RecycleForRestartFailureAsync().ConfigureAwait(true);

        _state.Transition(ShellEvent.RestartFailed);
        RefreshTrayMenu();

        ShowBalloon(
            "AliasAgent 重启核心失败",
            $"{summary}。日志：{_logger.LogPath}。修好原因后右键托盘菜单可再次点「重启核心」，或点「退出」。",
            ToolTipIcon.Error);
        _form?.ShowErrorPage(
            "重启核心失败",
            $"{summary}。{detail}",
            $"日志：{_logger.LogPath}。修好原因后，右键托盘菜单点「重启核心」重试；也可以点「退出」。");
    }

    /// <summary>
    /// 重启失败的资源回收：停本次起的核心 + 释放 Job 句柄。
    ///
    /// **不释放托盘图标、不释放壳单实例锁**：壳还要继续运行，用户要能再点「重启核心」
    /// 或「退出」；释放它们等于把壳伪装成已退出（再加一次双击就会起第二个壳）。
    /// 核心自身的锁文件由核心进程退出时释放。
    /// </summary>
    private async Task RecycleForRestartFailureAsync()
    {
        var report = await StopCoreAndReleaseJobAsync("重启失败回收").ConfigureAwait(true);
        if (report == null) return;
        Log($"[shell] 重启失败回收：停机报告 {report.Describe()}");
        if (report.ExtremeFallback)
        {
            // 停不掉也要点名 pid：Job 句柄随后释放，KILL_ON_JOB_CLOSE 是最后兜底。
            Log($"[shell] 重启失败回收：未能终止核心（pid={report.StillRunningPid}），" +
                "释放 Job Object 兜底");
        }
    }

    /// <summary>
    /// 两条启动失败路径共用的核心回收：停本次起的核心 + 释放 Job 句柄。
    ///
    /// **只碰核心资源**：托盘图标与壳单实例锁是否释放由调用方决定——首次启动失败要释放
    /// （壳正在退出），重启失败必须保留（壳要继续运行，见 <see cref="FailRestartAsync"/>）。
    /// </summary>
    private async Task<CoreStopReport?> StopCoreAndReleaseJobAsync(string context)
    {
        var launcher = _launcher;
        _launcher = null;
        CoreStopReport? report = null;
        if (launcher != null)
        {
            try
            {
                report = await launcher.StopAsync().ConfigureAwait(true);
            }
            catch (Exception e)
            {
                Log($"[shell] {context}时停核心出错：{e.Message}");
            }
        }

        _job?.Dispose();
        _job = null;
        return report;
    }

    /// <summary>启动路径上失败后的资源回收：停核心 + 放单实例锁（不留孤儿核心）。</summary>
    private async Task RecycleAfterWebView2FailureAsync()
    {
        await StopCoreAndReleaseJobAsync("失败回收").ConfigureAwait(true);
        if (_tray != null)
        {
            _tray.Visible = false;
            _tray.Dispose();
            _tray = null;
        }

        try
        {
            _singleInstance.Dispose();
        }
        catch
        {
            // 已经释放。
        }
    }
}
