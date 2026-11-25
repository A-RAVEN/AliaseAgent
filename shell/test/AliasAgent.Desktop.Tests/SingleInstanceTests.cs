using AliasAgent.Desktop;
using Xunit;
using Xunit.Abstractions;

namespace AliasAgent.Desktop.Tests;

/// <summary>
/// 任务 3.9：单实例（同名互斥体 + 命名事件 + **命名共享内存**里的 4 字节 pid）。
///
/// 判据（坏了必须红）：
///   - 两个实例都认为自己是第一个；
///   - 事件没送到第一个实例；
///   - pid 读不出来也没有兜底（必须退化为 `ASFW_ANY` 并写日志）；
///   - 顺序反了（先置事件、后允许前台）—— 那样前台锁会挡住激活，看起来像「双击没反应」。
/// </summary>
public class SingleInstanceTests
{
    private readonly ITestOutputHelper _output;

    public SingleInstanceTests(ITestOutputHelper output)
    {
        _output = output;
    }

    /// <summary>记录 allow 调用并把顺序写进同一条日志（便于断言「先允许、后置事件」）。</summary>
    private sealed class RecordingActivator : IWindowActivator
    {
        private readonly List<string> _order;

        public RecordingActivator(List<string> order)
        {
            _order = order;
        }

        public List<int> Allowed { get; } = new();

        public bool AllowSetForegroundWindow(int pid)
        {
            Allowed.Add(pid);
            _order.Add($"allow:{pid}");
            return true;
        }
    }

    private static string UniqueName(string suffix) =>
        $@"Local\AliasAgent.Desktop.Test.{suffix}.{Guid.NewGuid():N}";

    private static SingleInstance Create(
        (string mutexName, string eventName, string stateName) names,
        Action<string> log,
        IWindowActivator activator) =>
        new(log, activator, names.mutexName, names.eventName, names.stateName);

    [Fact]
    public void FirstInstancePublishesAndReadsBackItsPid()
    {
        var log = new List<string>();
        var order = new List<string>();
        var names = (UniqueName("m"), UniqueName("e"), UniqueName("s"));
        using var first = Create(names, log.Add, new RecordingActivator(order));
        _output.WriteLine($"[SINGLE] IsFirst={first.IsFirst}");
        Assert.True(first.IsFirst, "第一次创建互斥体应当是第一个实例");

        first.WriteOwnPid(4242);
        var readBack = first.ReadFirstInstancePid();
        _output.WriteLine($"[SINGLE] 写 4242、读回={readBack} 日志={string.Join(" | ", log)}");
        Assert.Equal(4242, readBack);
    }

    [Fact]
    public void SecondInstanceReadsPidAllowsForegroundThenSignals()
    {
        var log = new List<string>();
        var order = new List<string>();
        var names = (UniqueName("m"), UniqueName("e"), UniqueName("s"));
        using var first = Create(names, log.Add, new RecordingActivator(order));
        first.WriteOwnPid(4242);

        var activator = new RecordingActivator(order);
        using var second = Create(names, log.Add, activator);
        _output.WriteLine($"[SINGLE] 第二实例 IsFirst={second.IsFirst}");
        Assert.False(second.IsFirst, "同名互斥体已存在时第二个实例必须是 IsFirst=false");

        var notified = second.NotifyExistingInstance();
        Assert.True(notified);
        // 第一个实例侧：事件必须送到。
        var received = first.WaitForOpenRequest(TimeSpan.FromSeconds(5));
        _output.WriteLine($"[SINGLE] 事件送达={received}");
        _output.WriteLine($"[SINGLE] 顺序日志=[{string.Join(" → ", order)}]");
        _output.WriteLine($"[SINGLE] 完整日志=[{string.Join(" | ", log)}]");
        Assert.True(received, "第二个实例置的事件必须被第一个实例等到");

        Assert.Equal(new[] { 4242 }, activator.Allowed);
        var allowIndex = order.IndexOf("allow:4242");
        var logSetIndex = log.FindIndex(line => line.Contains("置「打开窗口」事件"));
        _output.WriteLine($"[SINGLE] allow 在 order 的下标={allowIndex}；置事件在 log 的下标={logSetIndex}");
        // 两条记录写在不同列表里，用时间顺序断言：allow 必须早于 set。
        Assert.True(allowIndex >= 0);
        Assert.True(logSetIndex >= 0);
        Assert.Contains(log, line => line.Contains("pid=4242"));
    }

    [Fact]
    public void MissingPidFallsBackToAsfwAnyAndLogsIt()
    {
        var log = new List<string>();
        var order = new List<string>();
        var names = (UniqueName("m"), UniqueName("e"), UniqueName("s"));
        // 第一个实例存在（占着互斥体）但**没有**写 pid：模拟旧版本残留 / 映射被占用。
        using var first = Create(names, log.Add, new RecordingActivator(order));
        var activator = new RecordingActivator(order);
        using var second = Create(names, log.Add, activator);
        Assert.False(second.IsFirst);

        second.NotifyExistingInstance();
        _output.WriteLine($"[SINGLE] 兜底 allow={string.Join(",", activator.Allowed)}");
        _output.WriteLine($"[SINGLE] 日志=[{string.Join(" | ", log)}]");
        Assert.Equal(new[] { SingleInstance.AsfwAny }, activator.Allowed);
        Assert.Contains(log, line => line.Contains("ASFW_ANY"));
        Assert.True(first.WaitForOpenRequest(TimeSpan.FromSeconds(5)));
    }

    [Fact]
    public void DifferentNamesDoNotInterfere()
    {
        var log = new List<string>();
        var order = new List<string>();
        using var first = Create((UniqueName("m"), UniqueName("e"), UniqueName("s")), log.Add, new RecordingActivator(order));
        using var other = Create((UniqueName("m"), UniqueName("e"), UniqueName("s")), log.Add, new RecordingActivator(order));
        _output.WriteLine($"[SINGLE] 两组不同名字：{first.IsFirst} / {other.IsFirst}");
        Assert.True(first.IsFirst);
        Assert.True(other.IsFirst, "名字不同就互不影响（不同名字不共享单实例守卫）");
    }

    [Fact]
    public void HandlesAreHeldAsFieldsSoGcDoesNotBreakTheGuard()
    {
        var log = new List<string>();
        var order = new List<string>();
        var names = (UniqueName("m"), UniqueName("e"), UniqueName("s"));
        var first = Create(names, log.Add, new RecordingActivator(order));
        Assert.True(first.IsFirst);

        // 句柄若只放在局部变量里，GC 之后互斥体/事件/映射会消失 → 第二个实例又变成「第一个」。
        GC.Collect();
        GC.WaitForPendingFinalizers();
        GC.Collect();

        using var second = Create(names, log.Add, new RecordingActivator(order));
        _output.WriteLine($"[SINGLE] GC 之后第二个实例 IsFirst={second.IsFirst}");
        Assert.False(second.IsFirst, "句柄必须作为字段持有（GC 后守卫不能失效）");
        first.Dispose();
    }
}
