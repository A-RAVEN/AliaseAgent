using AliasAgent.Desktop;
using Xunit;
using Xunit.Abstractions;

namespace AliasAgent.Desktop.Tests;

/// <summary>
/// 任务 3.3：壳侧读配置 `core.port`（与 Dart 侧同一张优先级表的第二级）。
///
/// 六个分支各一用例：缺文件 / 缺 core 块 / 缺 port 键 / 非整数 / 越界 / 合法值。
/// 判据（坏了必须红）：缺键时抛异常、非法值**静默**回落（没有日志）。
/// </summary>
public class CorePortResolverTests
{
    private readonly ITestOutputHelper _output;

    public CorePortResolverTests(ITestOutputHelper output)
    {
        _output = output;
    }

    private static string WriteConfig(string json)
    {
        var dir = Path.Combine(Path.GetTempPath(), "aliasagent_shell_cfg_" + Guid.NewGuid().ToString("N"));
        Directory.CreateDirectory(dir);
        var path = Path.Combine(dir, "config.json");
        File.WriteAllText(path, json);
        return path;
    }

    private (int port, List<string> logs) Resolve(string configPath)
    {
        var logs = new List<string>();
        var resolver = new CorePortResolver(logs.Add);
        var port = resolver.Resolve(configPath);
        return (port, logs);
    }

    [Fact]
    public void MissingFileFallsBackToDefaultWithOneLogLine()
    {
        var missing = Path.Combine(Path.GetTempPath(), "aliasagent_no_such_" + Guid.NewGuid().ToString("N") + ".json");
        var (port, logs) = Resolve(missing);
        _output.WriteLine($"[PORT] 缺文件 ⇒ port={port} logs={string.Join(" | ", logs)}");
        Assert.Equal(DesktopOptions.DefaultCorePort, port);
        Assert.Single(logs);
        Assert.Contains("core.port", logs[0]);
        Assert.Contains(DesktopOptions.DefaultCorePort.ToString(), logs[0]);
    }

    [Fact]
    public void MissingCoreBlockFallsBackToDefaultWithOneLogLine()
    {
        var path = WriteConfig("""{"version": 1, "providers": {}, "agent_types": {}}""");
        var (port, logs) = Resolve(path);
        _output.WriteLine($"[PORT] 缺 core 块 ⇒ port={port} logs={string.Join(" | ", logs)}");
        Assert.Equal(DesktopOptions.DefaultCorePort, port);
        Assert.Single(logs);
        Assert.Contains("core.port", logs[0]);
    }

    [Fact]
    public void MissingPortKeyFallsBackToDefaultWithOneLogLine()
    {
        var path = WriteConfig("""{"version": 1, "core": {}}""");
        var (port, logs) = Resolve(path);
        _output.WriteLine($"[PORT] 缺 port 键 ⇒ port={port} logs={string.Join(" | ", logs)}");
        Assert.Equal(DesktopOptions.DefaultCorePort, port);
        Assert.Single(logs);
        Assert.Contains("core.port", logs[0]);
    }

    [Theory]
    [InlineData("\"9100\"")]
    [InlineData("9100.5")]
    [InlineData("null")]
    public void NonIntegerPortFallsBackToDefaultWithOneLogLine(string rawPort)
    {
        var path = WriteConfig("{\"version\": 1, \"core\": {\"port\": " + rawPort + "}}");
        var (port, logs) = Resolve(path);
        _output.WriteLine($"[PORT] core.port={rawPort} ⇒ port={port} logs={string.Join(" | ", logs)}");
        Assert.Equal(DesktopOptions.DefaultCorePort, port);
        Assert.Single(logs);
        Assert.Contains("core.port", logs[0]);
        Assert.Contains(DesktopOptions.DefaultCorePort.ToString(), logs[0]);
    }

    [Theory]
    [InlineData("0")]
    [InlineData("-1")]
    [InlineData("65536")]
    public void OutOfRangePortFallsBackToDefaultWithOneLogLine(string rawPort)
    {
        var path = WriteConfig("{\"version\": 1, \"core\": {\"port\": " + rawPort + "}}");
        var (port, logs) = Resolve(path);
        _output.WriteLine($"[PORT] core.port={rawPort} ⇒ port={port} logs={string.Join(" | ", logs)}");
        Assert.Equal(DesktopOptions.DefaultCorePort, port);
        Assert.Single(logs);
        Assert.Contains("core.port", logs[0]);
        Assert.Contains(rawPort, logs[0]);
    }

    [Theory]
    [InlineData(1)]
    [InlineData(9000)]
    [InlineData(65535)]
    public void ValidPortIsHonored(int configured)
    {
        var path = WriteConfig("{\"version\": 1, \"core\": {\"port\": " + configured + "}}");
        var (port, logs) = Resolve(path);
        _output.WriteLine($"[PORT] core.port={configured} ⇒ port={port} logs={string.Join(" | ", logs)}");
        Assert.Equal(configured, port);
        Assert.Single(logs);
        Assert.Contains(configured.ToString(), logs[0]);
        Assert.DoesNotContain("回落", logs[0]);
    }

    [Fact]
    public void MalformedJsonFallsBackToDefaultWithOneLogLine()
    {
        var path = WriteConfig("{ this is not json");
        var (port, logs) = Resolve(path);
        _output.WriteLine($"[PORT] malformed ⇒ port={port} logs={string.Join(" | ", logs)}");
        Assert.Equal(DesktopOptions.DefaultCorePort, port);
        Assert.Single(logs);
        Assert.Contains("core.port", logs[0]);
    }

    [Fact]
    public void DefaultPortMatchesDartSideConstant()
    {
        // 三处同源的第一、二处：Dart 的 kDefaultCorePort 与壳的 DefaultCorePort。
        var repoRoot = TestRepoRoot.Find();
        var dartSource = File.ReadAllText(Path.Combine(repoRoot, "lib", "models", "app_config.dart"));
        var match = System.Text.RegularExpressions.Regex.Match(
            dartSource, @"kDefaultCorePort\s*=\s*(\d+)\s*;");
        _output.WriteLine($"[PORT] Dart 侧常量命中={match.Value}，壳侧={DesktopOptions.DefaultCorePort}");
        Assert.True(match.Success, "lib/models/app_config.dart 里找不到 kDefaultCorePort = <数字>;");
        Assert.Equal(int.Parse(match.Groups[1].Value), DesktopOptions.DefaultCorePort);
    }
}

/// <summary>
/// 测试侧自己找仓库根（从测试程序集目录向上找 `pubspec.yaml` + `bin/alias_agent_core.dart`）。
/// 刻意**不**复用 <see cref="RepoRootLocator"/>：那条是被测对象，测试不能用被测对象来找夹具。
/// </summary>
public static class TestRepoRoot
{
    public static string Find()
    {
        var dir = new DirectoryInfo(AppContext.BaseDirectory);
        while (dir != null)
        {
            if (File.Exists(Path.Combine(dir.FullName, "pubspec.yaml")) &&
                File.Exists(Path.Combine(dir.FullName, "bin", "alias_agent_core.dart")))
            {
                return dir.FullName;
            }

            dir = dir.Parent;
        }

        throw new InvalidOperationException(
            $"从 {AppContext.BaseDirectory} 向上找不到仓库根（pubspec.yaml + bin/alias_agent_core.dart）");
    }
}
