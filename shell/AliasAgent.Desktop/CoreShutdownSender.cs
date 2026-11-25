using System.Net.WebSockets;
using System.Text;
using System.Text.Json;

namespace AliasAgent.Desktop;

/// <summary>
/// 向核心发 `core.shutdown` 的礼停发送器（change `windows-desktop-shell` D3 / 任务 4.2）。
///
/// 与 `CoreLauncher.StopAsync` 的关系：launcher 负责「先礼停、超时再杀树」的顺序与
/// 超时，本类只负责「把礼停请求送到并读到 `{ok:true}`」。生产用真 WebSocket；单测里
/// launcher 注入假发送器（不联网）。
/// </summary>
public interface ICoreShutdownSender
{
    /// <summary>发一次礼停请求，返回核心是否回了 `ok=true`（超时/失败返回 false）。</summary>
    Task<bool> RequestShutdownAsync(int port, TimeSpan timeout, CancellationToken cancellationToken);
}

/// <summary>真 WebSocket 实现：连 `ws://127.0.0.1:&lt;port&gt;/ws`，发 `core.shutdown`。</summary>
public sealed class WebSocketCoreShutdownSender : ICoreShutdownSender
{
    private readonly Action<string> _log;

    public WebSocketCoreShutdownSender(Action<string>? log = null)
    {
        _log = log ?? (_ => { });
    }

    public async Task<bool> RequestShutdownAsync(int port, TimeSpan timeout,
        CancellationToken cancellationToken)
    {
        using var socket = new ClientWebSocket();
        using var timeoutCts = CancellationTokenSource.CreateLinkedTokenSource(cancellationToken);
        timeoutCts.CancelAfter(timeout);
        try
        {
            await socket.ConnectAsync(
                new Uri($"ws://127.0.0.1:{port}{CoreReadinessProbe.WebSocketPath}"),
                timeoutCts.Token).ConfigureAwait(false);
            var request = "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"core.shutdown\",\"params\":{}}";
            await socket.SendAsync(Encoding.UTF8.GetBytes(request), WebSocketMessageType.Text, true,
                timeoutCts.Token).ConfigureAwait(false);

            var buffer = new byte[8192];
            using var messageStream = new MemoryStream();
            WebSocketReceiveResult result;
            do
            {
                result = await socket.ReceiveAsync(buffer, timeoutCts.Token).ConfigureAwait(false);
                if (result.MessageType == WebSocketMessageType.Close) return false;
                messageStream.Write(buffer, 0, result.Count);
            } while (!result.EndOfMessage);

            var text = Encoding.UTF8.GetString(messageStream.ToArray());
            using var document = JsonDocument.Parse(text);
            var ok = document.RootElement.TryGetProperty("result", out var payload) &&
                     payload.ValueKind == JsonValueKind.Object &&
                     payload.TryGetProperty("ok", out var okElement) &&
                     okElement.ValueKind == JsonValueKind.True;
            _log($"[shell] core.shutdown 响应：{text}（ok={ok}）");
            return ok;
        }
        catch (Exception e)
        {
            _log($"[shell] core.shutdown 请求失败：{e.GetType().Name}: {e.Message}");
            return false;
        }
    }
}
