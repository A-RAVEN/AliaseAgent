using AliasAgent.Desktop;
using Xunit;
using Xunit.Abstractions;

namespace AliasAgent.Desktop.Tests;

/// <summary>
/// 任务 3.2：壳的选项解析（`--config` / `--port` / `--repo-root` / `--selftest` / `--help`）。
///
/// 判据（坏了必须红）：
///   - 未知参数被忽略（而不是报错）；
///   - 端口越界被接受；
///   - **`--port 0` 被放行**（壳 MUST NOT 接受 0：导航地址会变成没意义的 `:0`）。
/// </summary>
public class DesktopOptionsTests
{
    private readonly ITestOutputHelper _output;

    public DesktopOptionsTests(ITestOutputHelper output)
    {
        _output = output;
    }

    private void Dump(string label, DesktopOptions options)
    {
        _output.WriteLine($"[OPTIONS] {label}: config={options.ConfigPath ?? "<null>"} " +
                          $"port={(options.CliPort.HasValue ? options.CliPort.Value.ToString() : "<null>")} " +
                          $"repoRoot={options.RepoRoot ?? "<null>"} " +
                          $"selftest={options.SelfTest} help={options.Help}");
    }

    [Fact]
    public void ParsesEverySupportedOption()
    {
        var options = DesktopOptions.Parse(new[]
        {
            "--config", @"C:\tmp\config.json",
            "--port", "9100",
            "--repo-root", @"C:\repo",
            "--selftest",
            "--help",
        });
        Dump("全部参数", options);
        Assert.Equal(@"C:\tmp\config.json", options.ConfigPath);
        Assert.Equal(9100, options.CliPort);
        Assert.Equal(@"C:\repo", options.RepoRoot);
        Assert.True(options.SelfTest);
        Assert.True(options.Help);
    }

    [Fact]
    public void ParsesShortHelpFlag()
    {
        var options = DesktopOptions.Parse(new[] { "-h" });
        Dump("-h", options);
        Assert.True(options.Help);
    }

    [Fact]
    public void NoArgumentsMeansAllDefaults()
    {
        var options = DesktopOptions.Parse(Array.Empty<string>());
        Dump("无参数", options);
        Assert.Null(options.ConfigPath);
        Assert.Null(options.CliPort);
        Assert.Null(options.RepoRoot);
        Assert.False(options.SelfTest);
        Assert.False(options.Help);
        var record = DesktopOptions.Parse(new[] { "--selftest" });
        Dump("--selftest", record);
        Assert.True(record.SelfTest);
    }

    [Theory]
    [InlineData("0")]
    [InlineData("abc")]
    [InlineData("-1")]
    [InlineData("65536")]
    [InlineData("9100.5")]
    public void RejectsInvalidPorts(string raw)
    {
        var error = Assert.Throws<DesktopOptionException>(
            () => DesktopOptions.Parse(new[] { "--port", raw }));
        _output.WriteLine($"[OPTIONS] --port {raw} ⇒ {error.Message}");
        Assert.Contains("--port", error.Message);
        Assert.Contains(raw, error.Message);
    }

    [Fact]
    public void RejectsZeroPortWithCoreDebugWording()
    {
        var error = Assert.Throws<DesktopOptionException>(
            () => DesktopOptions.Parse(new[] { "--port", "0" }));
        _output.WriteLine($"[OPTIONS] --port 0 ⇒ {error.Message}");
        // spec：壳收到 0 时 SHALL 报错退出并说明「0 仅核心调试可用」。
        Assert.Contains("0", error.Message);
        Assert.Contains("仅核心调试", error.Message);
    }

    [Fact]
    public void RejectsMissingOptionValues()
    {
        foreach (var flag in new[] { "--config", "--port", "--repo-root" })
        {
            var error = Assert.Throws<DesktopOptionException>(
                () => DesktopOptions.Parse(new[] { flag }));
            _output.WriteLine($"[OPTIONS] {flag}（缺值）⇒ {error.Message}");
            Assert.Contains(flag, error.Message);
        }
    }

    [Fact]
    public void RejectsUnknownArguments()
    {
        var error = Assert.Throws<DesktopOptionException>(
            () => DesktopOptions.Parse(new[] { "--nope" }));
        _output.WriteLine($"[OPTIONS] --nope ⇒ {error.Message}");
        Assert.Contains("--nope", error.Message);
    }

    [Fact]
    public void DefaultPortConstantAndRangeArePinned()
    {
        _output.WriteLine($"[OPTIONS] DefaultCorePort={DesktopOptions.DefaultCorePort} " +
                          $"MinPort={DesktopOptions.MinPort} MaxPort={DesktopOptions.MaxPort}");
        // 默认值本身不在测试里写死（那个数字是受守卫的字面量，只许出现在两处常量声明里）：
        // 这里验「落在合法范围内」与「与 Dart 侧 kDefaultCorePort 同值」。
        Assert.InRange(DesktopOptions.DefaultCorePort, DesktopOptions.MinPort, DesktopOptions.MaxPort);
        Assert.Equal(1, DesktopOptions.MinPort);
        Assert.Equal(65535, DesktopOptions.MaxPort);
        Assert.True(DesktopOptions.Parse(new[] { "--port", "65535" }).CliPort == 65535);
        Assert.True(DesktopOptions.Parse(new[] { "--port", "1" }).CliPort == 1);

        var repoRoot = TestRepoRoot.Find();
        var dartSource = File.ReadAllText(Path.Combine(repoRoot, "lib", "models", "app_config.dart"));
        var match = System.Text.RegularExpressions.Regex.Match(
            dartSource, @"kDefaultCorePort\s*=\s*(\d+)\s*;");
        _output.WriteLine($"[OPTIONS] Dart 侧 kDefaultCorePort 命中={match.Value}");
        Assert.True(match.Success);
        Assert.Equal(int.Parse(match.Groups[1].Value), DesktopOptions.DefaultCorePort);
    }

    [Fact]
    public void UsageMentionsEveryFlagAndTheZeroPortRule()
    {
        _output.WriteLine("[OPTIONS] Usage:");
        _output.WriteLine(DesktopOptions.Usage);
        foreach (var flag in new[] { "--config", "--port", "--repo-root", "--selftest", "--help" })
        {
            Assert.Contains(flag, DesktopOptions.Usage);
        }
        Assert.Contains("仅核心调试", DesktopOptions.Usage);
    }
}
