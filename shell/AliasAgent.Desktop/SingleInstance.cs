using System.IO.MemoryMappedFiles;
using System.Runtime.InteropServices;

namespace AliasAgent.Desktop;

/// <summary>
/// 允许某个进程把窗口带到前台（Windows 前台锁的解锁手段）。
///
/// 接口化的原因：测试不许真的影响用户桌面，也不该依赖当前前台窗口是谁。
/// </summary>
public interface IWindowActivator
{
    /// <summary>
    /// `AllowSetForegroundWindow(pid)`：允许该 pid 的进程抢前台；`-1`（`ASFW_ANY`）
    /// 表示任何进程都允许（权限面更宽，只作兜底）。
    /// </summary>
    bool AllowSetForegroundWindow(int pid);
}

/// <summary>生产实现：Win32 `user32.dll`。</summary>
public sealed class Win32WindowActivator : IWindowActivator
{
    [DllImport("user32.dll", SetLastError = true, EntryPoint = "AllowSetForegroundWindow")]
    private static extern bool Win32AllowSetForegroundWindow(int dwProcessId);

    public bool AllowSetForegroundWindow(int pid) => Win32AllowSetForegroundWindow(pid);
}

/// <summary>
/// 单实例守卫（change `windows-desktop-shell` D5 / 任务 3.9）。
///
/// 三个命名对象，统一 `Local\` 前缀（作用域 = 当前登录会话，与「每用户一份配置与
/// 数据库」一致）：
///   - 互斥体：挡双开壳（`createdNew == false` ⇒ 这是第二个实例）；
///   - 命名事件：第二个实例通知第一个「打开窗口」；
///   - 命名共享内存（4 字节 pid）：第一个实例写入自己的 pid，第二个实例读它来给
///     `AllowSetForegroundWindow` 传对目标 —— 互斥体与事件都不携带数据。
///
/// **三个句柄都作为字段持有**（不许只放局部变量）：句柄被 GC 提前回收会让单实例
/// 守卫时有时无（单元测试用 GC 后角色判定来守这条）。
/// </summary>
public sealed class SingleInstance : IDisposable
{
    /// <summary>壳互斥体名（与核心的锁文件是**两把不同的锁**）。</summary>
    public const string DefaultMutexName = @"Local\AliasAgent.Desktop.SingleInstance";

    /// <summary>「打开窗口」请求事件名。</summary>
    public const string DefaultEventName = @"Local\AliasAgent.Desktop.OpenWindow";

    /// <summary>pid 共享内存名。</summary>
    public const string DefaultStateName = @"Local\AliasAgent.Desktop.State";

    /// <summary>`AllowSetForegroundWindow(ASFW_ANY)` 的实参（权限面更宽，只作兜底）。</summary>
    public const int AsfwAny = -1;

    private readonly Action<string> _log;
    private readonly IWindowActivator _activator;
    private readonly Mutex _mutex;
    private readonly EventWaitHandle _openRequestEvent;
    private readonly MemoryMappedFile _state;
    private bool _disposed;

    public SingleInstance(
        Action<string> log,
        IWindowActivator activator,
        string mutexName = DefaultMutexName,
        string eventName = DefaultEventName,
        string stateName = DefaultStateName)
    {
        _log = log ?? throw new ArgumentNullException(nameof(log));
        _activator = activator ?? throw new ArgumentNullException(nameof(activator));
        MutexName = mutexName;
        EventName = eventName;
        StateName = stateName;

        // 注意：命名互斥体已存在时 `initiallyOwned` 不生效（不会阻塞、也不会抢所有权），
        // 所以这里只把它当「存在性」判定，`createdNew` 就是角色。
        _mutex = new Mutex(initiallyOwned: true, name: mutexName, out var createdNew);
        IsFirst = createdNew;

        _openRequestEvent = new EventWaitHandle(false, EventResetMode.AutoReset, eventName);
        _state = MemoryMappedFile.CreateOrOpen(stateName, sizeof(int));

        _log(IsFirst
            ? $"[shell] 单实例：本进程是第一个实例（互斥体 {mutexName}）"
            : $"[shell] 单实例：已有实例在运行（互斥体 {mutexName}），本进程是第二个");
    }

    public string MutexName { get; }

    public string EventName { get; }

    public string StateName { get; }

    /// <summary>是否第一个实例。</summary>
    public bool IsFirst { get; }

    /// <summary>第一个实例：把自己的 pid 写进命名共享内存（4 字节）。</summary>
    public void WriteOwnPid(int pid)
    {
        try
        {
            using var view = _state.CreateViewAccessor(0, sizeof(int));
            view.Write(0, pid);
            _log($"[shell] 单实例：已把 pid={pid} 写进命名共享内存 {StateName}");
        }
        catch (Exception e)
        {
            // 写不进去不阻塞启动：第二实例读不到时会退化为 ASFW_ANY（有日志）。
            _log($"[shell] 单实例：写 pid 失败（{e.Message}）；第二实例会退化为 ASFW_ANY");
        }
    }

    /// <summary>读第一个实例的 pid；读不到返回 null。</summary>
    public int? ReadFirstInstancePid()
    {
        try
        {
            using var view = _state.CreateViewAccessor(0, sizeof(int));
            var pid = view.ReadInt32(0);
            return pid > 0 ? pid : null;
        }
        catch (Exception e)
        {
            _log($"[shell] 单实例：读 pid 失败（{e.Message}）");
            return null;
        }
    }

    /// <summary>
    /// 第二个实例：读 pid → `AllowSetForegroundWindow(pid)` → 置事件。
    ///
    /// **顺序不可反**：光置事件不够 —— 第一个实例随后调 `SetForegroundWindow` 会被
    /// Windows 前台锁挡住，用户看到的是「双击没反应」。
    /// </summary>
    public bool NotifyExistingInstance()
    {
        if (IsFirst)
        {
            throw new InvalidOperationException("第一个实例不该调用 NotifyExistingInstance");
        }

        var pid = ReadFirstInstancePid();
        if (pid.HasValue)
        {
            _log($"[shell] 单实例：允许前台激活 pid={pid}（AllowSetForegroundWindow）");
            _activator.AllowSetForegroundWindow(pid.Value);
        }
        else
        {
            _log("[shell] 单实例：读不到第一实例 pid ⇒ 退化为 ASFW_ANY" +
                 "（权限面更宽，只作兜底、不作默认）");
            _activator.AllowSetForegroundWindow(AsfwAny);
        }

        _log("[shell] 单实例：置「打开窗口」事件（通知第一个实例）");
        return _openRequestEvent.Set();
    }

    /// <summary>第一个实例侧：等「打开窗口」请求（超时返回 false）。</summary>
    public bool WaitForOpenRequest(TimeSpan timeout) => _openRequestEvent.WaitOne(timeout);

    public void Dispose()
    {
        if (_disposed) return;
        _disposed = true;
        try
        {
            _state.Dispose();
        }
        catch
        {
            // 已释放。
        }

        try
        {
            _openRequestEvent.Dispose();
        }
        catch
        {
            // 已释放。
        }

        try
        {
            // 只释放自己的句柄：若仍持有所有权（createdNew 那次），先放掉再关。
            try
            {
                _mutex.ReleaseMutex();
            }
            catch (ApplicationException)
            {
                // 没持有所有权（第二个实例）：忽略。
            }

            _mutex.Dispose();
        }
        catch
        {
            // 已释放。
        }
    }
}
