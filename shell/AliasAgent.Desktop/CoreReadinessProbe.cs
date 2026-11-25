using System.Diagnostics;
using System.Net.WebSockets;
using System.Text;
using System.Text.Json;

namespace AliasAgent.Desktop;

/// <summary>
/// 核心就绪探测（change `windows-desktop-shell` D3 / 任务 3.8）。
///
/// 只有 `ws://127.0.0.1:&lt;port&gt;/ws` 上收到 `core.ping` 的 `result.ok = true` 才算就绪：
/// 「连上 TCP」不算（那只是端口有人在听），回了 JSON-RPC 错误也不算。
///
/// 三个等待参数是**壳自己的**（design 附录 B 第 5 条）：数值借自
/// `web/src/tokens.ts` 的三个 `kDefault…Ms` 常量，语义不同（那三个是重连退避/心跳），
/// 取同值只为不新增第二套等待数量级；单元测试把这两边绑死防漂移。
/// </summary>
public sealed class CoreReadinessProbe
{
    /// <summary>重试间隔（毫秒）。</summary>
    public const int RetryIntervalMs = 1000;

    /// <summary>单次探测等待上限（毫秒）。</summary>
    public const int PerAttemptTimeoutMs = 5000;

    /// <summary>就绪总预算（毫秒）。</summary>
    public const int TotalBudgetMs = 30000;

    /// <summary>探针发出的方法名（逐字核对用）。</summary>
    public const string PingMethod = "core.ping";

    /// <summary>核心 WebSocket 路径（与 `lib/core/headless_core.dart` 的常量同值）。</summary>
    public const string WebSocketPath = "/ws";

    private readonly Action<string> _log;
    private readonly int _retryIntervalMs;
    private readonly int _perAttemptTimeoutMs;
    private readonly int _totalBudgetMs;

    public CoreReadinessProbe(
        Action<string>? log = null,
        int? retryIntervalMs = null,
        int? perAttemptTimeoutMs = null,
        int? totalBudgetMs = null)
    {
        _log = log ?? (_ => { });
        _retryIntervalMs = retryIntervalMs ?? RetryIntervalMs;
        _perAttemptTimeoutMs = perAttemptTimeoutMs ?? PerAttemptTimeoutMs;
        _totalBudgetMs = totalBudgetMs ?? TotalBudgetMs;
    }

    /// <summary>在总预算内反复探测，返回是否就绪（预算耗尽 = false）。</summary>
    public async Task<bool> WaitUntilReadyAsync(int port, CancellationToken cancellationToken = default)
    {
        var stopwatch = Stopwatch.StartNew();
        var attempt = 0;
        while (stopwatch.ElapsedMilliseconds < _totalBudgetMs)
        {
            cancellationToken.ThrowIfCancellationRequested();
            attempt++;
            var remaining = _totalBudgetMs - (int)stopwatch.ElapsedMilliseconds;
            var timeout = Math.Min(_perAttemptTimeoutMs, Math.Max(remaining, 50));
            var outcome = await AttemptOnceAsync(port, timeout, cancellationToken).ConfigureAwait(false);
            _log($"[shell] core.ping 第 {attempt} 次尝试 ⇒ {outcome}（已用 {stopwatch.ElapsedMilliseconds}ms / 预算 {_totalBudgetMs}ms）");
            switch (outcome)
            {
                case AttemptOutcome.Ready:
                    _log($"[shell] 核心就绪：core.ping ok（端口 {port}，第 {attempt} 次尝试）");
                    return true;
                case AttemptOutcome.JsonRpcError:
                    return false;
                case AttemptOutcome.NotReady:
                    break;
            }

            var elapsed = (int)stopwatch.ElapsedMilliseconds;
            var wait = Math.Min(_retryIntervalMs, Math.Max(_totalBudgetMs - elapsed, 0));
            if (wait <= 0) break;
            try
            {
                await Task.Delay(wait, cancellationToken).ConfigureAwait(false);
            }
            catch (OperationCanceledException)
            {
                return false;
            }
        }

        _log($"[shell] 核心在 {_totalBudgetMs}ms 内没有响应 {PingMethod}（尝试 {attempt} 次）");
        return false;
    }

    private enum AttemptOutcome
    {
        Ready,
        NotReady,
        JsonRpcError,
    }

    private async Task<AttemptOutcome> AttemptOnceAsync(int port, int timeoutMs, CancellationToken cancellationToken)
    {
        using var socket = new ClientWebSocket();
        using var timeoutCts = CancellationTokenSource.CreateLinkedTokenSource(cancellationToken);
        timeoutCts.CancelAfter(timeoutMs);
        try
        {
            await socket.ConnectAsync(new Uri($"ws://127.0.0.1:{port}{WebSocketPath}"), timeoutCts.Token)
                .ConfigureAwait(false);
            var request = $"{{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"{PingMethod}\",\"params\":{{}}}}";
            await socket.SendAsync(Encoding.UTF8.GetBytes(request), WebSocketMessageType.Text, true,
                timeoutCts.Token).ConfigureAwait(false);

            var buffer = new byte[8192];
            using var messageStream = new MemoryStream();
            WebSocketReceiveResult result;
            do
            {
                result = await socket.ReceiveAsync(buffer, timeoutCts.Token).ConfigureAwait(false);
                if (result.MessageType == WebSocketMessageType.Close) return AttemptOutcome.NotReady;
                messageStream.Write(buffer, 0, result.Count);
            } while (!result.EndOfMessage);

            var text = Encoding.UTF8.GetString(messageStream.ToArray());
            using var document = JsonDocument.Parse(text);
            var root = document.RootElement;
            if (root.TryGetProperty("error", out var error))
            {
                _log($"[shell] core.ping 回了 JSON-RPC 错误：{error.GetRawText()}");
                return AttemptOutcome.JsonRpcError;
            }

            if (root.TryGetProperty("result", out var payload) &&
                payload.ValueKind == JsonValueKind.Object &&
                payload.TryGetProperty("ok", out var ok) &&
                ok.ValueKind == JsonValueKind.True)
            {
                return AttemptOutcome.Ready;
            }

            _log($"[shell] core.ping 响应没有 result.ok=true：{text}");
            return AttemptOutcome.NotReady;
        }
        catch (OperationCanceledException)
        {
            return AttemptOutcome.NotReady;
        }
        catch (Exception e)
        {
            _log($"[shell] core.ping 连接/收发失败（不算就绪）：{e.GetType().Name}: {e.Message}");
            return AttemptOutcome.NotReady;
        }
    }
}
