using System.Diagnostics;
using System.Net;
using System.Net.Sockets;
using System.Text;

namespace AliasAgent.Desktop;

/// <summary>
/// 无窗口自检模式（change `windows-desktop-shell` D7 / 任务 4.4）。
///
/// 必须能与「用户此刻正开着壳」并存，因此四件事一起做：
///   1. **不取壳的命名互斥体**：分流发生在 `Program` 取互斥体**之前**；
///   2. **不读用户真实配置**：显式传 `--config &lt;临时目录&gt;\config.json`；
///   3. **不碰用户数据与日志**：子进程 `USERPROFILE` 指向临时目录，并显式传
///      `--lock &lt;临时目录&gt;\core.lock`；自检自己的日志也写临时目录；
///   4. **不抢配置里的固定端口**：当场 `TcpListener` 绑 0 取一个空闲端口、释放后
///      显式传给核心。
///
/// 端口取用与绑定之间存在竞态（TOCTOU）：被抢时得到可归因的 bind 失败，**不**做
/// 换端口重试（那会把真实占用掩盖成偶发）。
///
/// 步骤：web 产物存在 → 起核心（第 1 个）→ `core.ping` → `HTTP GET /` 断言 200 且正文
/// 含 `&lt;div id="root"&gt;` → `core.shutdown` → 第 1 个进程 0 退出 → 同锁再启动
/// （第 2 个）→ **对第 2 个也发 `core.shutdown` 并等它退出** → 退出 0。
/// 每步打印 `[SELFTEST] &lt;步骤&gt; &lt;结果&gt;`。不建窗口、不建托盘图标。
/// </summary>
internal static class SelfTestRunner
{
    private const string StepPrefix = "[SELFTEST]";
    private static readonly TimeSpan kReadyBudget = TimeSpan.FromSeconds(CoreReadinessProbe.TotalBudgetMs);
    private static readonly TimeSpan kExitTimeout = TimeSpan.FromSeconds(15);

    public static int Run(DesktopOptions options)
    {
        try
        {
            return RunAsync(options).GetAwaiter().GetResult();
        }
        catch (Exception e)
        {
            Fail("自检未预期异常", $"{e.GetType().Name}: {e.Message}");
            return 1;
        }
    }

    private static async Task<int> RunAsync(DesktopOptions options)
    {
        var tempRoot = Path.Combine(Path.GetTempPath(),
            "aliasagent_selftest_" + Guid.NewGuid().ToString("N"));
        Directory.CreateDirectory(tempRoot);
        var configPath = Path.Combine(tempRoot, "config.json");
        var lockPath = Path.Combine(tempRoot, "core.lock");
        var logPath = Path.Combine(tempRoot, "desktop-shell-selftest.log");
        using var logger = new ShellLogger(logPath);
        void Log(string line)
        {
            logger.Write(line);
        }

        Log($"[selftest] 临时目录={tempRoot}");
        Log($"[selftest] 日志={logPath}");

        CoreLauncher? first = null;
        CoreLauncher? second = null;
        try
        {
            // ① 仓库根
            string repoRoot;
            try
            {
                repoRoot = options.RepoRoot ?? new RepoRootLocator().Locate();
            }
            catch (RepoRootNotFoundException e)
            {
                return Fail("仓库根", e.Message);
            }

            Ok("仓库根", repoRoot);

            // ② web 产物
            var webIndex = Path.Combine(repoRoot, "web", "dist", "index.html");
            if (!File.Exists(webIndex))
            {
                return Fail("web 产物", $"不存在：{webIndex}。先构建：cd web && npm install && npm run build");
            }

            Ok("web 产物", webIndex);

            // ③ dart
            DartExecutable dart;
            try
            {
                dart = new DartExecutableResolver().Resolve();
            }
            catch (DartNotFoundException e)
            {
                return Fail("dart 解析", e.Message);
            }

            Ok("dart 解析", dart.Path + (dart.RequiresCmdWrapper ? "（经 cmd.exe /C）" : string.Empty));

            // ④ 当场取空闲端口（TOCTOU 竞态如实记录，不做换端口重试）。
            int port;
            try
            {
                port = GrabFreePort();
            }
            catch (Exception e)
            {
                return Fail("取空闲端口", e.Message);
            }

            Ok("取空闲端口", $"{port}（端口从释放到核心 bind 之间可能被抢：竞态如实记录，不做换端口重试）");
            Log($"[selftest] 说明：端口 {port} 是「绑 0 → 立即释放 → 显式传给核心」，" +
                "期间若有别的进程抢到它，会得到可归因的绑定失败，不是假绿");

            // ⑤ 临时配置（空配置启动：核心 serve 首启向导，静态页照样 200）。
            File.WriteAllText(configPath, "{\"version\": 1}");
            Ok("临时配置", configPath);
            Log($"[selftest] 子进程 USERPROFILE={tempRoot}（用户真实 ~/.aliasagent 不参与）");
            Log($"[selftest] 临时单实例锁={lockPath}");

            // ⑥ 第 1 个核心（临时 config / 临时锁 / 临时 USERPROFILE 全部注入）。
            var environment = new Dictionary<string, string>
            {
                ["USERPROFILE"] = tempRoot,
                ["HOME"] = tempRoot,
            };
            var command = CoreCommandBuilder.Build(
                dart, repoRoot, port, configPath, environment, lockPath);

            first = new CoreLauncher(command, Log,
                gracefulStop: null,
                gracefulStopTimeout: TimeSpan.FromSeconds(0),
                killTimeout: kExitTimeout);
            try
            {
                first.Start();
            }
            catch (Exception e)
            {
                return Fail("起核心（第 1 个）", e.Message);
            }

            Ok("起核心（第 1 个）", $"pid={first.Process?.Id}，端口={port}");

            var (ready, firstExitCode) = await WaitReadyOrExitAsync(first, port, Log);
            if (ready != ReadyOutcome.Ready)
            {
                return Fail("core.ping",
                    ready == ReadyOutcome.Exited
                        ? $"核心在就绪前退出（exit={firstExitCode}）；最后输出={first.LastOutputLine}"
                        : $"核心在 {kReadyBudget.TotalMilliseconds}ms 内没有响应 core.ping");
            }

            Ok("core.ping", "ok（核心已就绪）");

            // ⑦ 静态页
            var page = await HttpGetAsync(port, "/", TimeSpan.FromSeconds(5));
            if (page.StatusCode != 200)
            {
                return Fail("HTTP GET /", $"状态码 {page.StatusCode}（期望 200）");
            }

            if (!page.Body.Contains("<div id=\"root\"", StringComparison.Ordinal))
            {
                var preview = page.Body.Length > 200 ? page.Body.Substring(0, 200) : page.Body;
                return Fail("HTTP GET /", $"正文不含 <div id=\"root\">；前 200 字符={preview}");
            }

            Ok("HTTP GET /", $"200，正文含 <div id=\"root\">（{page.Body.Length} 字符）");

            // ⑧ 礼停第 1 个
            if (!await RequestShutdownAsync(port, Log))
            {
                return Fail("core.shutdown（第 1 个）", "没有收到 {ok:true}");
            }

            Ok("core.shutdown（第 1 个）", "已回 {ok:true}");
            var firstExit = await WaitExitAsync(first, kExitTimeout);
            if (firstExit == null)
            {
                return Fail("第 1 个核心退出", $"{kExitTimeout.TotalSeconds}s 内没有退出");
            }

            if (firstExit != 0)
            {
                return Fail("第 1 个核心退出", $"退出码 {firstExit}（期望 0）");
            }

            Ok("第 1 个核心退出", "exit=0（礼停成功，锁应已释放）");

            // ⑨ 同锁再启动（第 2 个）：证明锁确实释放了。
            var secondCommand = CoreCommandBuilder.Build(
                dart, repoRoot, port, configPath, environment, lockPath);
            second = new CoreLauncher(secondCommand, Log,
                gracefulStop: null,
                gracefulStopTimeout: TimeSpan.FromSeconds(0),
                killTimeout: kExitTimeout);
            try
            {
                second.Start();
            }
            catch (Exception e)
            {
                return Fail("再次启动（第 2 个）", e.Message);
            }

            Ok("再次启动（第 2 个）", $"pid={second.Process?.Id}（同锁 {lockPath} 能再启动 ⇒ 锁已释放）");

            var (secondReady, secondExitCode) = await WaitReadyOrExitAsync(second, port, Log);
            if (secondReady != ReadyOutcome.Ready)
            {
                return Fail("core.ping（第 2 个）", $"第 2 个核心没有就绪（锁或端口没释放）；outcome={secondReady} exit={secondExitCode}");
            }

            Ok("core.ping（第 2 个）", "ok");

            // ⑩ 第 2 个也必须被礼停并等退出（不许为验锁释放留孤儿核心）。
            if (!await RequestShutdownAsync(port, Log))
            {
                return Fail("core.shutdown（第 2 个）", "没有收到 {ok:true}");
            }

            Ok("core.shutdown（第 2 个）", "已回 {ok:true}");
            var secondExit = await WaitExitAsync(second, kExitTimeout);
            if (secondExit == null)
            {
                return Fail("第 2 个核心退出", $"{kExitTimeout.TotalSeconds}s 内没有退出");
            }

            if (secondExit != 0)
            {
                return Fail("第 2 个核心退出", $"退出码 {secondExit}（期望 0）");
            }

            Ok("第 2 个核心退出", "exit=0（没有留孤儿核心）");

            Console.Out.WriteLine($"{StepPrefix} 结果 通过（退出码 0）");
            return 0;
        }
        finally
        {
            // 收尾：任何失败路径都不许留残留核心（Job Object 只是兜底，不是收尾手段）。
            foreach (var launcher in new[] { first, second })
            {
                if (launcher?.Process == null) continue;
                try
                {
                    if (!launcher.Process.HasExited)
                    {
                        Log("[selftest] 收尾：停止残留核心");
                        await launcher.StopAsync();
                    }
                }
                catch
                {
                    // 已经退了。
                }
            }

            try
            {
                Directory.Delete(tempRoot, recursive: true);
            }
            catch
            {
                // 目录被占用（日志句柄）时留给人看：路径已打印在 [SELFTEST] 里。
            }
        }
    }

    private enum ReadyOutcome
    {
        Ready,
        Timeout,
        Exited,
    }

    private static async Task<(ReadyOutcome Outcome, int? ExitCode)> WaitReadyOrExitAsync(
        CoreLauncher launcher, int port, Action<string> log)
    {
        var probe = new CoreReadinessProbe(log);
        var readyTask = probe.WaitUntilReadyAsync(port);
        var process = launcher.Process!;
        var exitTask = process.WaitForExitAsync();
        var first = await Task.WhenAny(readyTask, exitTask);
        if (first == exitTask)
        {
            var exitCode = process.HasExited ? process.ExitCode : (int?)null;
            return (ReadyOutcome.Exited, exitCode);
        }

        return (await readyTask ? ReadyOutcome.Ready : ReadyOutcome.Timeout, null);
    }

    private static async Task<int?> WaitExitAsync(CoreLauncher launcher, TimeSpan timeout)
    {
        var process = launcher.Process;
        if (process == null) return 0;
        try
        {
            await process.WaitForExitAsync().WaitAsync(timeout);
            return process.ExitCode;
        }
        catch (TimeoutException)
        {
            return null;
        }
    }

    private static async Task<bool> RequestShutdownAsync(int port, Action<string> log)
    {
        var sender = new WebSocketCoreShutdownSender(log);
        return await sender.RequestShutdownAsync(port, TimeSpan.FromSeconds(5), CancellationToken.None);
    }

    private static int GrabFreePort()
    {
        var listener = new TcpListener(IPAddress.Loopback, 0);
        listener.Start();
        var port = ((IPEndPoint)listener.LocalEndpoint).Port;
        listener.Stop();
        return port;
    }

    private static async Task<(int StatusCode, string Body)> HttpGetAsync(int port, string path, TimeSpan timeout)
    {
        using var client = new HttpClient { Timeout = timeout };
        using var response = await client.GetAsync($"http://127.0.0.1:{port}{path}");
        var body = await response.Content.ReadAsStringAsync();
        return ((int)response.StatusCode, body);
    }

    private static void Ok(string step, string detail)
    {
        Console.Out.WriteLine($"{StepPrefix} {step} ok：{detail}");
    }

    private static int Fail(string step, string reason)
    {
        Console.Out.WriteLine($"{StepPrefix} {step} 失败：{reason}");
        Console.Error.WriteLine($"{StepPrefix} {step} 失败：{reason}");
        return 1;
    }
}
