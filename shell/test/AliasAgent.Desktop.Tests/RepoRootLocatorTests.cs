using AliasAgent.Desktop;
using Xunit;
using Xunit.Abstractions;

namespace AliasAgent.Desktop.Tests;

/// <summary>
/// 任务 3.4：仓库根定位（从可执行文件目录向上找含 `pubspec.yaml` 与
/// `bin/alias_agent_core.dart` 的目录）。
///
/// 判据（坏了必须红）：
///   - 找不到时返回 null / 空串，而不是**可归因**错误；
///   - 把「缺 bin/alias_agent_core.dart」的目录（或 `bin` 是文件而不是目录）当成仓库根。
/// </summary>
public class RepoRootLocatorTests
{
    private readonly ITestOutputHelper _output;

    public RepoRootLocatorTests(ITestOutputHelper output)
    {
        _output = output;
    }

    private static string NewTempDir(string prefix)
    {
        var dir = Path.Combine(Path.GetTempPath(), prefix + Guid.NewGuid().ToString("N"));
        Directory.CreateDirectory(dir);
        return dir;
    }

    [Fact]
    public void FindsTheNearestDirectoryThatLooksLikeTheRepoRoot()
    {
        var root = NewTempDir("aliasagent_reporoot_hit_");
        File.WriteAllText(Path.Combine(root, "pubspec.yaml"), "name: alias_agent\n");
        Directory.CreateDirectory(Path.Combine(root, "bin"));
        File.WriteAllText(Path.Combine(root, "bin", "alias_agent_core.dart"), "void main() {}\n");
        var nested = Path.Combine(root, "shell", "exe", "bin");
        Directory.CreateDirectory(nested);

        var locator = new RepoRootLocator(() => nested);
        var found = locator.Locate();
        _output.WriteLine($"[REPOROOT] 起点={nested}");
        _output.WriteLine($"[REPOROOT] 命中={found}");
        Assert.Equal(root, found);
        Assert.True(RepoRootLocator.IsRepoRoot(found));
    }

    [Fact]
    public void MissingMarkersGivesAnAttributableError()
    {
        var dir = NewTempDir("aliasagent_reporoot_miss_");
        var locator = new RepoRootLocator(() => dir);
        var error = Assert.Throws<RepoRootNotFoundException>(() => locator.Locate());
        _output.WriteLine($"[REPOROOT] 不命中 ⇒ {error.Message}");
        Assert.Contains(dir, error.Message);
        Assert.Contains("pubspec.yaml", error.Message);
        Assert.Contains("alias_agent_core.dart", error.Message);
    }

    [Fact]
    public void DirectoryWithoutBinDartIsNotARepoRoot()
    {
        var root = NewTempDir("aliasagent_reporoot_nodart_");
        File.WriteAllText(Path.Combine(root, "pubspec.yaml"), "name: alias_agent\n");
        Directory.CreateDirectory(Path.Combine(root, "bin"));
        // 没有 bin/alias_agent_core.dart —— 这是「看着像但不是」的夹具。
        var nested = Path.Combine(root, "child");
        Directory.CreateDirectory(nested);

        var locator = new RepoRootLocator(() => nested);
        var error = Assert.Throws<RepoRootNotFoundException>(() => locator.Locate());
        _output.WriteLine($"[REPOROOT] 缺 bin/alias_agent_core.dart ⇒ {error.Message}");
        Assert.Contains(root, error.Message);
        Assert.False(RepoRootLocator.IsRepoRoot(root));
    }

    [Fact]
    public void FileNamedBinIsNotADirectoryAndCannotBeARepoRoot()
    {
        var root = NewTempDir("aliasagent_reporoot_filebin_");
        File.WriteAllText(Path.Combine(root, "pubspec.yaml"), "name: alias_agent\n");
        // `bin` 是**文件**而不是目录：同名文件不算。
        File.WriteAllText(Path.Combine(root, "bin"), "not a directory\n");

        _output.WriteLine($"[REPOROOT] bin 是文件：IsRepoRoot={RepoRootLocator.IsRepoRoot(root)}");
        Assert.False(RepoRootLocator.IsRepoRoot(root));

        var locator = new RepoRootLocator(() => root);
        Assert.Throws<RepoRootNotFoundException>(() => locator.Locate());
    }
}
