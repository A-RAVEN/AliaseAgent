using System.Net;
using System.Net.Sockets;
using System.Net.WebSockets;
using System.Security.Cryptography;
using System.Text;
using System.Text.Json;
using AliasAgent.Desktop;
using Xunit;
using Xunit.Abstractions;

namespace AliasAgent.Desktop.Tests;

/// <summary>
/// 任务 3.8：就绪探测（`core.ping`）。
///
/// 用**进程内假 WebSocket 服务**（`TcpListener` + 手写 HTTP 升级握手 +
/// `WebSocket.CreateFromStream(isServer: true)`）验四件事：
///   1. 正常应答 → true；
///   2. 不应答 → 预算耗尽 false（不把「连上 TCP」当成就绪）；
///   3. 回 JSON-RPC 错误 → false；
///   4. 探针发出的方法名逐字是 `core.ping`。
///
/// 另加一条守卫：探针的三个等待参数必须等于 `web/src/tokens.ts` 的
/// `kDefaultReconnectBaseMs` / `kDefaultHeartbeatTimeoutMs` / `kDefaultReconnectCapMs`
/// （C# 是硬编码副本，不绑就会漂移）。
/// </summary>
public class CoreReadinessProbeTests
{
    private readonly ITestOutputHelper _output;

    public CoreReadinessProbeTests(ITestOutputHelper output)
    {
        _output = output;
    }

    [Fact]
    public async Task NormalPingResponseMeansReady()
    {
        await using var server = FakeWebSocketServer.Start(FakeWebSocketServer.Mode.PingOk);
        var received = new List<string>();
        server.OnTextReceived = received.Add;

        var probe = new CoreReadinessProbe(message => _output.WriteLine($"[PROBE] {message}"),
            retryIntervalMs: 50, perAttemptTimeoutMs: 2000, totalBudgetMs: 5000);
        var ready = await probe.WaitUntilReadyAsync(server.Port).WaitAsync(TimeSpan.FromSeconds(20));

        _output.WriteLine($"[PROBE] ready={ready} received=[{string.Join(" ; ", received)}]");
        Assert.True(ready);
        Assert.Single(received);
        using var document = JsonDocument.Parse(received[0]);
        Assert.Equal("core.ping", document.RootElement.GetProperty("method").GetString());
    }

    [Fact]
    public async Task SilentServerExhaustsBudgetAndReturnsFalse()
    {
        await using var server = FakeWebSocketServer.Start(FakeWebSocketServer.Mode.Silent);
        var attempts = 0;
        server.OnConnection = () => Interlocked.Increment(ref attempts);

        var probe = new CoreReadinessProbe(message => _output.WriteLine($"[PROBE] {message}"),
            retryIntervalMs: 40, perAttemptTimeoutMs: 80, totalBudgetMs: 400);
        var ready = await probe.WaitUntilReadyAsync(server.Port).WaitAsync(TimeSpan.FromSeconds(20));

        _output.WriteLine($"[PROBE] ready={ready} 连接次数={attempts}");
        Assert.False(ready);
        Assert.True(attempts > 1, $"应当重试到预算耗尽（实际连接 {attempts} 次）");
    }

    [Fact]
    public async Task JsonRpcErrorIsNotReady()
    {
        await using var server = FakeWebSocketServer.Start(FakeWebSocketServer.Mode.ErrorResponse);
        var probe = new CoreReadinessProbe(message => _output.WriteLine($"[PROBE] {message}"),
            retryIntervalMs: 40, perAttemptTimeoutMs: 2000, totalBudgetMs: 5000);
        var ready = await probe.WaitUntilReadyAsync(server.Port).WaitAsync(TimeSpan.FromSeconds(20));
        _output.WriteLine($"[PROBE] JSON-RPC 错误 ⇒ ready={ready}");
        Assert.False(ready);
    }

    [Fact]
    public void ProbeParametersMatchWebTokens()
    {
        var repoRoot = TestRepoRoot.Find();
        var tokensPath = Path.Combine(repoRoot, "web", "src", "tokens.ts");
        var source = File.ReadAllText(tokensPath);
        var baseMs = ParseTokenConstant(source, "kDefaultReconnectBaseMs");
        var heartbeatTimeoutMs = ParseTokenConstant(source, "kDefaultHeartbeatTimeoutMs");
        var capMs = ParseTokenConstant(source, "kDefaultReconnectCapMs");
        _output.WriteLine($"[PROBE] tokens.ts: base={baseMs} heartbeatTimeout={heartbeatTimeoutMs} cap={capMs}");
        _output.WriteLine($"[PROBE] C# 副本: retry={CoreReadinessProbe.RetryIntervalMs} " +
                          $"perAttempt={CoreReadinessProbe.PerAttemptTimeoutMs} " +
                          $"budget={CoreReadinessProbe.TotalBudgetMs}");
        Assert.Equal(baseMs, CoreReadinessProbe.RetryIntervalMs);
        Assert.Equal(heartbeatTimeoutMs, CoreReadinessProbe.PerAttemptTimeoutMs);
        Assert.Equal(capMs, CoreReadinessProbe.TotalBudgetMs);
    }

    private static int ParseTokenConstant(string source, string name)
    {
        var match = System.Text.RegularExpressions.Regex.Match(
            source, @"export\s+const\s+" + name + @"\s*=\s*(\d+)\s*;");
        Assert.True(match.Success, $"web/src/tokens.ts 里找不到 export const {name} = <数字>;");
        return int.Parse(match.Groups[1].Value);
    }
}

/// <summary>
/// 进程内假 WebSocket 服务：`TcpListener` + 手写 HTTP 升级握手 +
/// `WebSocket.CreateFromStream(isServer: true)`（**不用 `HttpListener`**：它在 Windows
/// 上需要 URL ACL 前置）。
/// </summary>
internal sealed class FakeWebSocketServer : IAsyncDisposable
{
    public enum Mode
    {
        PingOk,
        Silent,
        ErrorResponse,
    }

    private readonly TcpListener _listener;
    private readonly CancellationTokenSource _cts = new();
    private readonly Task _acceptLoop;

    private FakeWebSocketServer(TcpListener listener, Mode mode)
    {
        _listener = listener;
        ModeValue = mode;
        _acceptLoop = Task.Run(() => AcceptLoopAsync(_cts.Token));
    }

    public Mode ModeValue { get; }

    public int Port { get; private init; }

    public Action<string>? OnTextReceived { get; set; }

    public Action? OnConnection { get; set; }

    public static FakeWebSocketServer Start(Mode mode)
    {
        var listener = new TcpListener(IPAddress.Loopback, 0);
        listener.Start();
        var port = ((IPEndPoint)listener.LocalEndpoint).Port;
        return new FakeWebSocketServer(listener, mode) { Port = port };
    }

    private async Task AcceptLoopAsync(CancellationToken token)
    {
        while (!token.IsCancellationRequested)
        {
            TcpClient client;
            try
            {
                client = await _listener.AcceptTcpClientAsync(token);
            }
            catch
            {
                return;
            }

            _ = Task.Run(() => HandleClientAsync(client, token));
        }
    }

    private async Task HandleClientAsync(TcpClient client, CancellationToken token)
    {
        try
        {
            using (client)
            using (var stream = client.GetStream())
            {
                OnConnection?.Invoke();
                var key = await ReadUpgradeRequestAsync(stream, token);
                var accept = ComputeAccept(key);
                var response = "HTTP/1.1 101 Switching Protocols\r\n" +
                               "Upgrade: websocket\r\n" +
                               "Connection: Upgrade\r\n" +
                               $"Sec-WebSocket-Accept: {accept}\r\n\r\n";
                var responseBytes = Encoding.ASCII.GetBytes(response);
                await stream.WriteAsync(responseBytes, token);
                await stream.FlushAsync(token);

                using var socket = WebSocket.CreateFromStream(stream, isServer: true,
                    subProtocol: null, keepAliveInterval: TimeSpan.Zero);
                var buffer = new byte[8192];
                var result = await socket.ReceiveAsync(buffer, token);
                if (result.MessageType == WebSocketMessageType.Close)
                {
                    return;
                }

                var text = Encoding.UTF8.GetString(buffer, 0, result.Count);
                OnTextReceived?.Invoke(text);

                switch (ModeValue)
                {
                    case Mode.Silent:
                        await Task.Delay(Timeout.Infinite, token);
                        break;
                    case Mode.PingOk:
                        var id = ReadId(text);
                        var ok = $"{{\"jsonrpc\":\"2.0\",\"id\":{id},\"result\":{{\"ok\":true}}}}";
                        await socket.SendAsync(Encoding.UTF8.GetBytes(ok), WebSocketMessageType.Text,
                            true, token);
                        // 让客户端有时间读到响应再断开。
                        await Task.Delay(200, token);
                        break;
                    case Mode.ErrorResponse:
                        var errorId = ReadId(text);
                        var error = $"{{\"jsonrpc\":\"2.0\",\"id\":{errorId},\"error\":" +
                                    "{\"code\":-32601,\"message\":\"Method not found: core.ping (fake)\"}}";
                        await socket.SendAsync(Encoding.UTF8.GetBytes(error), WebSocketMessageType.Text,
                            true, token);
                        await Task.Delay(200, token);
                        break;
                }
            }
        }
        catch
        {
            // 客户端提前断开 / 取消：假服务器的正常路径。
        }
    }

    private static int ReadId(string text)
    {
        using var document = JsonDocument.Parse(text);
        return document.RootElement.TryGetProperty("id", out var id) ? id.GetInt32() : 0;
    }

    private static async Task<string> ReadUpgradeRequestAsync(NetworkStream stream, CancellationToken token)
    {
        var buffer = new List<byte>();
        var one = new byte[1];
        while (true)
        {
            var read = await stream.ReadAsync(one, token);
            if (read == 0) throw new IOException("客户端在握手前断开");
            buffer.Add(one[0]);
            var count = buffer.Count;
            if (count >= 4 &&
                buffer[count - 4] == '\r' && buffer[count - 3] == '\n' &&
                buffer[count - 2] == '\r' && buffer[count - 1] == '\n')
            {
                break;
            }
        }

        var text = Encoding.ASCII.GetString(buffer.ToArray());
        foreach (var line in text.Split("\r\n"))
        {
            if (line.StartsWith("Sec-WebSocket-Key:", StringComparison.OrdinalIgnoreCase))
            {
                return line.Substring("Sec-WebSocket-Key:".Length).Trim();
            }
        }

        throw new IOException("握手请求里没有 Sec-WebSocket-Key");
    }

    private static string ComputeAccept(string key)
    {
        using var sha1 = SHA1.Create();
        var bytes = sha1.ComputeHash(Encoding.ASCII.GetBytes(key + "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"));
        return Convert.ToBase64String(bytes);
    }

    public async ValueTask DisposeAsync()
    {
        _cts.Cancel();
        try
        {
            _listener.Stop();
        }
        catch
        {
            // 已经停了。
        }

        try
        {
            await _acceptLoop.WaitAsync(TimeSpan.FromSeconds(5));
        }
        catch
        {
            // 收尾失败不影响断言。
        }

        _cts.Dispose();
    }
}
