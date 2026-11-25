namespace AliasAgent.Desktop;

/// <summary>
/// 把后台线程的「打开窗口」请求编组回 UI 线程（change `windows-desktop-shell` 任务 6.1a）。
///
/// 为什么单独抽这个类：`SynchronizationContext.Current` 在 `Program.Main` 的
/// `Application.Run(app)` **之前**是 null —— `WindowsFormsSynchronizationContext` 要等
/// 消息循环起来才安装。若在 `ShellApplication` 构造函数里捕获，目标恒为 null，监听线程的
/// `Post` 就退化成空操作：第二实例退出 0、日志显示「已置事件」，但第一实例窗口永不重开
/// （6.2(g) 的现场）。所以：
///   - 捕获点必须在消息循环已起来之后（<see cref="ShellApplication"/> 的 `StartOnce`）；
///   - 未捕获时的 <see cref="Post"/> 必须**返回 false 并写日志**，不许静默丢弃请求。
/// </summary>
public sealed class UiThreadMarshaller
{
    private readonly Func<SynchronizationContext?> _captureSource;
    private readonly Action<string> _log;
    private SynchronizationContext? _context;

    /// <param name="captureSource">
    /// 捕获来源（默认 `SynchronizationContext.Current`；测试可注入，生产不传）。
    /// </param>
    /// <param name="log">日志落点（生产 = 壳日志；测试 = 内存）。</param>
    public UiThreadMarshaller(
        Func<SynchronizationContext?>? captureSource = null,
        Action<string>? log = null)
    {
        _captureSource = captureSource ?? (() => SynchronizationContext.Current);
        _log = log ?? (_ => { });
    }

    /// <summary>是否已捕获到 UI 线程的同步上下文（未捕获时 <see cref="Post"/> 一律丢弃并留日志）。</summary>
    public bool IsCaptured => _context != null;

    /// <summary>
    /// 捕获调用线程当前的同步上下文。
    ///
    /// **必须在消息循环已起来之后调用**（构造期调用会拿到 null，这正是 6.1a 的缺陷）。
    /// 返回是否捕获成功。
    /// </summary>
    public bool Capture()
    {
        var context = _captureSource();
        _context = context;
        if (context == null)
        {
            _log("[shell] UI 同步上下文捕获失败：当前线程没有 SynchronizationContext" +
                 "（捕获点必须在消息循环已起来之后，构造期捕获会得到 null）");
            return false;
        }

        _log($"[shell] 已捕获 UI 同步上下文：{context.GetType().Name}" +
             $"（线程 {Environment.CurrentManagedThreadId}）");
        return true;
    }

    /// <summary>
    /// 把动作 Post 到已捕获的 UI 同步上下文。未捕获时返回 false 并写日志——**不静默丢弃**，
    /// 否则现象就是「第二实例退出 0，第一实例窗口不回来」。
    /// </summary>
    public bool Post(Action action)
    {
        ArgumentNullException.ThrowIfNull(action);
        var context = _context;
        if (context == null)
        {
            _log("[shell] 打开窗口请求丢弃：还没有捕获 UI 同步上下文（第二实例请求到不了 UI 线程）");
            return false;
        }

        context.Post(_ => action(), null);
        return true;
    }
}
