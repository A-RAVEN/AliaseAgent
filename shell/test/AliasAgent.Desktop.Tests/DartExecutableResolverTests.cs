using AliasAgent.Desktop;
using Xunit;
using Xunit.Abstractions;

namespace AliasAgent.Desktop.Tests;

/// <summary>
/// 任务 3.5：`dart` 可执行文件解析。
///
/// 顺序（design D3）：`ALIASAGENT_DART` → PATH 上的 `dart.exe` → PATH 上的
/// `dart.bat` / `dart.cmd`（**必须经 `cmd.exe /C`**，本机 `Get-Command dart` 就指向
/// `E:\Flutter\flutter\bin\dart.bat`，`CreateProcess` 不能直接执行批处理）→ 报错。
///
/// 环境变量与 PATH 全部**构造函数注入**：用例不读、也不改真实机器的 PATH。
/// </summary>
public class DartExecutableResolverTests
{
    private readonly ITestOutputHelper _output;

    public DartExecutableResolverTests(ITestOutputHelper output)
    {
        _output = output;
    }

    private static DartExecutableResolver Resolver(
        IReadOnlyDictionary<string, string> env,
        string pathValue,
        ISet<string> existingFiles)
    {
        return new DartExecutableResolver(
            variable: name => env.TryGetValue(name, out var value) ? value : null,
            pathValue: () => pathValue,
            fileExists: existingFiles.Contains);
    }

    private void Dump(string label, DartExecutable executable)
    {
        _output.WriteLine($"[DART] {label}: Path={executable.Path} " +
                          $"RequiresCmdWrapper={executable.RequiresCmdWrapper} " +
                          $"FileName={executable.FileName} " +
                          $"PrefixArguments=[{string.Join(",", executable.PrefixArguments)}]");
    }

    [Fact]
    public void EnvironmentVariableWinsOverPath()
    {
        const string overflow = @"C:\custom\sdk\bin\dart.exe";
        var resolver = Resolver(
            new Dictionary<string, string> { ["ALIASAGENT_DART"] = overflow },
            @"C:\flutter\bin",
            new HashSet<string>(StringComparer.OrdinalIgnoreCase)
            {
                overflow,
                @"C:\flutter\bin\dart.exe",
            });
        var executable = resolver.Resolve();
        Dump("ALIASAGENT_DART 覆盖", executable);
        Assert.Equal(overflow, executable.Path);
        Assert.False(executable.RequiresCmdWrapper);
        Assert.Equal(overflow, executable.FileName);
        Assert.Empty(executable.PrefixArguments);
    }

    [Fact]
    public void PathDartExeIsUsedWhenNoEnvironmentOverride()
    {
        var resolver = Resolver(
            new Dictionary<string, string>(),
            @"C:\one;C:\flutter\bin;C:\three",
            new HashSet<string>(StringComparer.OrdinalIgnoreCase)
            {
                @"C:\flutter\bin\dart.exe",
                @"C:\flutter\bin\dart.bat",
            });
        var executable = resolver.Resolve();
        Dump("PATH dart.exe 优先", executable);
        Assert.Equal(@"C:\flutter\bin\dart.exe", executable.Path);
        Assert.False(executable.RequiresCmdWrapper);
    }

    [Fact]
    public void BatchOnPathIsWrappedThroughCmdExe()
    {
        // 本机的真实形态：PATH 上只有 dart.bat。
        var resolver = Resolver(
            new Dictionary<string, string>(),
            @"C:\Windows;C:\flutter\bin",
            new HashSet<string>(StringComparer.OrdinalIgnoreCase)
            {
                @"C:\flutter\bin\dart.bat",
            });
        var executable = resolver.Resolve();
        Dump("PATH dart.bat", executable);
        Assert.Equal(@"C:\flutter\bin\dart.bat", executable.Path);
        Assert.True(executable.RequiresCmdWrapper);
        Assert.Equal("cmd.exe", executable.FileName, ignoreCase: true);
        Assert.Equal(new[] { "/C" }, executable.PrefixArguments);
    }

    [Fact]
    public void CmdOnPathIsAlsoWrappedThroughCmdExe()
    {
        var resolver = Resolver(
            new Dictionary<string, string>(),
            @"C:\tools",
            new HashSet<string>(StringComparer.OrdinalIgnoreCase)
            {
                @"C:\tools\dart.cmd",
            });
        var executable = resolver.Resolve();
        Dump("PATH dart.cmd", executable);
        Assert.Equal(@"C:\tools\dart.cmd", executable.Path);
        Assert.True(executable.RequiresCmdWrapper);
        Assert.Equal("cmd.exe", executable.FileName, ignoreCase: true);
    }

    [Fact]
    public void NothingFoundGivesAttributableErrorWithThreeRemedies()
    {
        var resolver = Resolver(
            new Dictionary<string, string>(),
            @"C:\Windows",
            new HashSet<string>(StringComparer.OrdinalIgnoreCase));
        var error = Assert.Throws<DartNotFoundException>(() => resolver.Resolve());
        _output.WriteLine($"[DART] 全都没有 ⇒ {error.Message}");
        Assert.Contains("dart", error.Message, StringComparison.OrdinalIgnoreCase);
        Assert.Contains("ALIASAGENT_DART", error.Message);
        Assert.Contains("PATH", error.Message);
        Assert.Contains("Flutter", error.Message);
    }

    [Fact]
    public void EnvironmentVariablePointingAtMissingFileIsAttributable()
    {
        var resolver = Resolver(
            new Dictionary<string, string> { ["ALIASAGENT_DART"] = @"C:\gone\dart.exe" },
            @"C:\flutter\bin",
            new HashSet<string>(StringComparer.OrdinalIgnoreCase) { @"C:\flutter\bin\dart.exe" });
        var error = Assert.Throws<DartNotFoundException>(() => resolver.Resolve());
        _output.WriteLine($"[DART] ALIASAGENT_DART 指向不存在的文件 ⇒ {error.Message}");
        Assert.Contains("ALIASAGENT_DART", error.Message);
        Assert.Contains(@"C:\gone\dart.exe", error.Message);
    }
}
