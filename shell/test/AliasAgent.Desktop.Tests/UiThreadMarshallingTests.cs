using AliasAgent.Desktop;
using Xunit;
using Xunit.Abstractions;

namespace AliasAgent.Desktop.Tests;

/// <summary>
/// 消息循环串行执行：本文件的用例会起真实的 WinForms 消息循环，彼此不许并行
/// （`Application.Idle` 是进程级静态事件，并行会互相串到对方的循环里）。
/// </summary>
[CollectionDefinition("WinFormsMessageLoop", DisableParallelization = true)]
public sealed class WinFormsMessageLoopCollection
{
}

/// <summary>
/// 任务 6.1a：第二实例的「打开窗口」请求必须被编组到**消息循环起来之后**捕获的 UI 上下文。
///
/// 缺陷现场（6.2(g)）：`ShellApplication` 构造函数在 `Application.Run` 之前执行，那时
/// `SynchronizationContext.Current` 是 null；`WindowsFormsSynchronizationContext` 要等消息
/// 循环起来才安装。构造期捕获 ⇒ 目标恒为 null ⇒ 监听线程的 `Post` 是空操作 ⇒ 第二实例
/// 退出 0、第一实例窗口永不重开。
///
/// 本文件覆盖两件事：
///   (a) 消息循环之前捕获必须失败，且 `Post` 明确记为「丢弃」（不是静默 no-op）；
///   (b) 在真实 `Application.Run` 里经真实 `ShellApplication.StartOnce` 捕获后，`Post`
///       的回调必须执行在 UI 线程（同一线程 id），且启动委托确实被调用。
///
/// 覆盖边界（诚实登记）：单测验的是「捕获点 + Post 真的被调用」这条接缝；真实 exe 的
/// 窗口被前台激活只能由 6.2(g) 的运行时复验（主循环做，单测不假装覆盖）。
/// </summary>
[Collection("WinFormsMessageLoop")]
public class UiThreadMarshallingTests
{
    private readonly ITestOutputHelper _output;

    public UiThreadMarshallingTests(ITestOutputHelper output)
    {
        _output = output;
    }

    /// <summary>只允许本文件的探针线程使用；记录调用不产生任何桌面副作用。</summary>
    private sealed class NoopActivator : IWindowActivator
    {
        public bool AllowSetForegroundWindow(int pid) => true;
    }

    private static string UniqueName(string suffix) =>
        $@"Local\AliasAgent.Desktop.Test.Marshalling.{suffix}.{Guid.NewGuid():N}";

    [Fact]
    public void CapturingBeforeTheMessageLoopIsNullAndPostIsDroppedWithALog()
    {
        var contextWasNull = false;
        var captured = true;
        var posted = true;
        var callbackRan = true;
        Exception? failure = null;
        var log = new List<string>();

        // 模拟 Program.Main 在 Application.Run 之前的主线程：线程上还没有 WinForms 同步上下文。
        var thread = new Thread(() =>
        {
            try
            {
                SynchronizationContext.SetSynchronizationContext(null);
                contextWasNull = SynchronizationContext.Current == null;
                var marshaller = new UiThreadMarshaller(log: line =>
                {
                    lock (log) log.Add(line);
                });
                captured = marshaller.Capture();
                callbackRan = false;
                posted = marshaller.Post(() => callbackRan = true);
            }
            catch (Exception e)
            {
                failure = e;
            }
        });
        thread.SetApartmentState(ApartmentState.STA);
        thread.Start();
        var finished = thread.Join(TimeSpan.FromSeconds(10));

        string[] logLines;
        lock (log) logLines = log.ToArray();
        _output.WriteLine($"[6.1a] 探针线程结束={finished} 捕获前 Context 为 null={contextWasNull}");
        _output.WriteLine($"[6.1a] Capture()={captured} Post()={posted} 回调执行={callbackRan}");
        _output.WriteLine($"[6.1a] 日志=[{string.Join(" | ", logLines)}]");

        Assert.True(finished, "STA 探针线程没有在 10 秒内结束");
        Assert.Null(failure);
        Assert.True(contextWasNull, "消息循环之前的线程不该有 WinForms 同步上下文（缺陷现场的前提）");
        Assert.False(captured, "消息循环之前捕获必须失败：构造期捕获正是 6.2(g) 的根因");
        Assert.False(posted, "未捕获时 Post 必须返回 false（不许假装送达）");
        Assert.False(callbackRan, "未捕获时回调不许执行");
        Assert.Contains(logLines, line => line.Contains("捕获失败"));
        Assert.Contains(logLines, line => line.Contains("丢弃"));
    }

    [Fact]
    public void OpenRequestPostedAfterMessageLoopCaptureRunsOnTheUiThread()
    {
        var logPath = Path.Combine(
            Path.GetTempPath(), $"aliasagent-shell-6.1a-{Guid.NewGuid():N}.log");
        Exception? failure = null;
        var startupRan = false;
        var captured = false;
        var postReturned = false;
        var callbackRan = false;
        var uiThreadId = -1;
        var callbackThreadId = -1;
        var checksRun = false;

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
                var app = new ShellApplication(
                    options,
                    singleInstance,
                    logger,
                    startupOverride: () =>
                    {
                        startupRan = true;
                        return Task.CompletedTask;
                    });

                void OnIdle(object? sender, EventArgs e)
                {
                    if (checksRun) return;
                    checksRun = true;
                    uiThreadId = Environment.CurrentManagedThreadId;
                    captured = app.UiMarshallerForTests.IsCaptured;
                    postReturned = app.UiMarshallerForTests.Post(() =>
                    {
                        callbackRan = true;
                        callbackThreadId = Environment.CurrentManagedThreadId;
                        Application.ExitThread();
                    });
                }

                // 先构造再订阅：ShellApplication 构造时已把自己的 StartOnce 挂到 Idle（它先跑，
                // 也就是生产里的捕获点），本探针在同一轮 Idle 里后跑，看到的是「启动后」状态。
                Application.Idle += OnIdle;
                // 兜底时钟：Post 没送达（缺陷态）时也别让消息循环永远不退出。
                using var watchdog = new System.Windows.Forms.Timer { Interval = 5000 };
                watchdog.Tick += (_, _) =>
                {
                    watchdog.Stop();
                    Application.ExitThread();
                };
                watchdog.Start();
                try
                {
                    Application.Run(app);
                }
                finally
                {
                    Application.Idle -= OnIdle;
                    watchdog.Stop();
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
        var finished = thread.Join(TimeSpan.FromSeconds(20));

        var logText = File.Exists(logPath) ? File.ReadAllText(logPath) : "(无日志文件)";
        _output.WriteLine($"[6.1a] 消息循环线程结束={finished} 启动委托执行={startupRan}");
        _output.WriteLine($"[6.1a] UI 线程 id={uiThreadId} 捕获成功={captured} Post 返回={postReturned}");
        _output.WriteLine($"[6.1a] 回调执行={callbackRan} 回调线程 id={callbackThreadId}");
        _output.WriteLine($"[6.1a] 壳日志：{logText}");

        try
        {
            File.Delete(logPath);
        }
        catch
        {
            // 临时日志删不掉不影响断言。
        }

        Assert.True(finished, "消息循环线程没有在 20 秒内结束（Application.Run 没退出）");
        Assert.Null(failure);
        Assert.True(startupRan, "StartOnce 没有执行启动委托（启动序列没跑起来）");
        Assert.True(captured,
            "StartOnce 之后必须已捕获 UI 同步上下文：构造期捕获会得到 null，这就是 6.2(g)");
        Assert.True(postReturned, "捕获之后 Post 必须真的把请求投递出去");
        Assert.True(callbackRan, "Post 的回调没有执行（请求没到 UI 线程）");
        Assert.Equal(uiThreadId, callbackThreadId);
        Assert.Contains("已捕获 UI 同步上下文", logText);
    }
}
