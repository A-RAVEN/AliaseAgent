using System.Text.Json;

namespace AliasAgent.Desktop;

/// <summary>
/// 壳侧读配置里的固定端口 `core.port`（change `windows-desktop-shell` D2 / 任务 3.3）。
///
/// 口径与 Dart 侧 `AppConfig._parseCorePort` **同一张表**：`core.port` 缺席 / 不是
/// 整数 / 越界时回落具名默认并**留一行日志**（回落可见，不静默、也不拒绝启动）；
/// 合法值生效。日志走构造注入的落点（生产 = 壳日志文件，测试 = 内存收集）。
///
/// 这里**不**重算优先级里的 `--port` 那一级：壳是决策者，`CorePortResolver` 只负责
/// 配置这一级，最终值由壳的启动序列按 `--port` > 配置 > 默认 决定；测试直接验这一级
/// 的六个分支。
/// </summary>
public sealed class CorePortResolver
{
    private readonly Action<string> _log;
    private readonly int _defaultPort;

    public CorePortResolver(Action<string> log, int defaultPort = DesktopOptions.DefaultCorePort)
    {
        _log = log ?? throw new ArgumentNullException(nameof(log));
        _defaultPort = defaultPort;
    }

    /// <summary>产品默认配置文件路径（`%USERPROFILE%\.aliasagent\config.json`）。</summary>
    public static string DefaultConfigPath()
    {
        var home = Environment.GetFolderPath(Environment.SpecialFolder.UserProfile);
        return Path.Combine(home, ".aliasagent", "config.json");
    }

    /// <summary>按配置算端口；任何缺失 / 非法都回落默认并写一行日志。</summary>
    public int Resolve(string configPath)
    {
        if (string.IsNullOrWhiteSpace(configPath) || !File.Exists(configPath))
        {
            return Fallback(configPath, "配置文件不存在");
        }

        JsonDocument document;
        try
        {
            document = JsonDocument.Parse(File.ReadAllText(configPath));
        }
        catch (Exception e)
        {
            return Fallback(configPath, $"配置无法解析（{e.Message}）");
        }

        using (document)
        {
            var root = document.RootElement;
            if (root.ValueKind != JsonValueKind.Object ||
                !root.TryGetProperty("core", out var core) ||
                core.ValueKind != JsonValueKind.Object)
            {
                return Fallback(configPath, "缺 core 块");
            }

            if (!core.TryGetProperty("port", out var portElement))
            {
                return Fallback(configPath, "缺 core.port 键");
            }

            if (portElement.ValueKind != JsonValueKind.Number || !portElement.TryGetInt32(out var port))
            {
                return Fallback(configPath, $"core.port 不是整数（{portElement.GetRawText()}）");
            }

            if (port < DesktopOptions.MinPort || port > DesktopOptions.MaxPort)
            {
                return Fallback(configPath,
                    $"core.port 越界（{port} 不在 {DesktopOptions.MinPort}–{DesktopOptions.MaxPort}）");
            }

            _log($"[shell] core.port={port}（来自配置 {configPath}）");
            return port;
        }
    }

    private int Fallback(string configPath, string reason)
    {
        _log($"[shell] core.port 回落默认 {_defaultPort}：{reason}（配置 {configPath}）");
        return _defaultPort;
    }
}
