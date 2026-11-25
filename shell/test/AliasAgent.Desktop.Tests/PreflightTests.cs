using AliasAgent.Desktop;
using Xunit;
using Xunit.Abstractions;

namespace AliasAgent.Desktop.Tests;

/// <summary>
/// 任务 3.6：启动前预检（`web/dist/index.html`、`dart`、仓库根三项）。
///
/// 判据（坏了必须红）：
///   - 缺 `web/dist` 时仍然放行；
///   - 只给「启动失败」这种不可操作文案；
///   - 用例去改真实机器的 PATH / 真实目录（本文件全部走注入的文件存在性谓词）。
/// </summary>
public class PreflightTests
{
    private readonly ITestOutputHelper _output;

    public PreflightTests(ITestOutputHelper output)
    {
        _output = output;
    }

    private static PreflightInputs Inputs(
        string? repoRoot = @"C:\repo",
        DartExecutable? dart = null,
        string? repoRootError = null,
        string? dartError = null)
    {
        return new PreflightInputs
        {
            RepoRoot = repoRoot,
            RepoRootError = repoRootError,
            Dart = dart ?? new DartExecutable(@"C:\flutter\bin\dart.exe", false),
            DartError = dartError,
        };
    }

    [Fact]
    public void AllThreePresentPasses()
    {
        var webIndex = Path.Combine(@"C:\repo", "web", "dist", "index.html");
        var preflight = new Preflight(path => path == webIndex);
        var result = preflight.Check(Inputs());
        _output.WriteLine($"[PREFLIGHT] ok={result.Ok} webIndex={result.WebIndexPath}");
        Assert.True(result.Ok);
        Assert.Empty(result.Problems);
        Assert.Equal(webIndex, result.WebIndexPath);
    }

    [Fact]
    public void MissingWebDistBlocksWithTheBuildCommand()
    {
        var preflight = new Preflight(_ => false);
        var result = preflight.Check(Inputs());
        foreach (var problem in result.Problems)
        {
            _output.WriteLine($"[PREFLIGHT] 问题：{problem}");
        }
        Assert.False(result.Ok);
        var joined = string.Join("\n", result.Problems);
        Assert.Contains("web", joined);
        Assert.Contains("index.html", joined);
        Assert.Contains("npm run build", joined, StringComparison.OrdinalIgnoreCase);
        Assert.Contains("npm install", joined, StringComparison.OrdinalIgnoreCase);
    }

    [Fact]
    public void MissingDartBlocksWithTheThreeRemedies()
    {
        var webIndex = Path.Combine(@"C:\repo", "web", "dist", "index.html");
        var preflight = new Preflight(path => path == webIndex);
        var result = preflight.Check(new PreflightInputs
        {
            RepoRoot = @"C:\repo",
            Dart = null,
            DartError = "找不到 dart：环境变量 ALIASAGENT_DART 未设置，PATH 上没有 dart.exe。" +
                        "三种补法：① 装 Flutter SDK；② 把 dart 放进 PATH；③ 用 ALIASAGENT_DART 指定。",
        });
        foreach (var problem in result.Problems)
        {
            _output.WriteLine($"[PREFLIGHT] 问题：{problem}");
        }
        Assert.False(result.Ok);
        var joined = string.Join("\n", result.Problems);
        Assert.Contains("dart", joined, StringComparison.OrdinalIgnoreCase);
        Assert.Contains("Flutter", joined);
        Assert.Contains("ALIASAGENT_DART", joined);
    }

    [Fact]
    public void MissingRepoRootBlocksAndPointsAtTheFlag()
    {
        var preflight = new Preflight(_ => true);
        var result = preflight.Check(new PreflightInputs
        {
            RepoRoot = null,
            RepoRootError = "找不到仓库根：从 \"C:\\app\" 向上都没有同时含 pubspec.yaml、" +
                            "bin\\alias_agent_core.dart 的目录。用 --repo-root 指定仓库根。",
            Dart = new DartExecutable(@"C:\flutter\bin\dart.exe", false),
        });
        foreach (var problem in result.Problems)
        {
            _output.WriteLine($"[PREFLIGHT] 问题：{problem}");
        }
        Assert.False(result.Ok);
        var joined = string.Join("\n", result.Problems);
        Assert.Contains("pubspec.yaml", joined);
        Assert.Contains("--repo-root", joined);
    }

    [Fact]
    public void EveryProblemIsActionableAndNamed()
    {
        // 仓库根在、另外两项缺：每条问题都必须点名「缺什么 + 怎么补」，
        // 不许只剩一句「启动失败」。
        var preflight = new Preflight(_ => false);
        var result = preflight.Check(new PreflightInputs
        {
            RepoRoot = @"C:\repo",
            Dart = null,
            DartError = "找不到 dart（装 Flutter SDK / 放进 PATH / 用 ALIASAGENT_DART 指定）",
        });
        _output.WriteLine($"[PREFLIGHT] 问题条数={result.Problems.Count}");
        foreach (var problem in result.Problems)
        {
            _output.WriteLine($"[PREFLIGHT] 问题：{problem}");
        }
        Assert.Equal(2, result.Problems.Count);
        Assert.All(result.Problems, problem =>
        {
            Assert.False(string.IsNullOrWhiteSpace(problem));
            Assert.DoesNotContain("启动失败", problem);
        });
        var joined = string.Join("\n", result.Problems);
        Assert.Contains("dart", joined, StringComparison.OrdinalIgnoreCase);
        Assert.Contains("ALIASAGENT_DART", joined);
        Assert.Contains("npm run build", joined, StringComparison.OrdinalIgnoreCase);

        // 仓库根缺失单独是一条（此时 web 产物路径无从计算，问题数只有 1，属正常）。
        var onlyRoot = new Preflight(_ => false).Check(new PreflightInputs
        {
            RepoRoot = null,
            RepoRootError = "找不到仓库根",
            Dart = new DartExecutable(@"C:\flutter\bin\dart.exe", false),
        });
        _output.WriteLine($"[PREFLIGHT] 只缺仓库根：条数={onlyRoot.Problems.Count} " +
                          $"内容={string.Join(" | ", onlyRoot.Problems)}");
        Assert.Single(onlyRoot.Problems);
        Assert.Contains("--repo-root", onlyRoot.Problems[0]);
    }
}
