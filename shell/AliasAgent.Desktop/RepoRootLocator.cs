namespace AliasAgent.Desktop;

/// <summary>
/// 仓库根定位（change `windows-desktop-shell` D3 / 任务 3.4）。
///
/// 为什么需要它：核心子进程的工作目录**必须是仓库根** —— `sidecar.dll` 以裸名字
/// `DynamicLibrary.open('sidecar.dll')` 加载，DLL 就在仓库根。双击启动时当前目录
/// 是产物目录（`shell/dist`），所以只能从壳可执行文件所在目录向上找。
///
/// 判定：目录里同时有 `pubspec.yaml`（文件）、`bin`（**目录**）与
/// `bin/alias_agent_core.dart`（文件）。只查前两个会漏掉「`bin` 是文件」这种假命中。
/// </summary>
public sealed class RepoRootLocator
{
    private readonly Func<string> _startDirectory;

    /// <param name="startDirectory">从哪个目录开始向上找（生产 = 可执行文件目录；测试注入临时树）。</param>
    public RepoRootLocator(Func<string> startDirectory)
    {
        _startDirectory = startDirectory ?? throw new ArgumentNullException(nameof(startDirectory));
    }

    /// <summary>从可执行文件所在目录开始找（双击启动的默认形态）。</summary>
    public RepoRootLocator()
        : this(() => AppContext.BaseDirectory)
    {
    }

    /// <summary>判定某个目录是否仓库根（三条都必须是：文件 / 目录 / 文件）。</summary>
    public static bool IsRepoRoot(string path)
    {
        if (string.IsNullOrWhiteSpace(path)) return false;
        var bin = Path.Combine(path, "bin");
        return File.Exists(Path.Combine(path, "pubspec.yaml")) &&
               Directory.Exists(bin) &&
               File.Exists(Path.Combine(bin, "alias_agent_core.dart"));
    }

    /// <summary>向上找仓库根。找不到抛 <see cref="RepoRootNotFoundException"/>（点名找过哪些目录）。</summary>
    public string Locate()
    {
        var start = _startDirectory();
        var searched = new List<string>();
        DirectoryInfo? dir;
        try
        {
            dir = new DirectoryInfo(start);
        }
        catch (Exception e)
        {
            throw new RepoRootNotFoundException(
                $"仓库根定位失败：起点 \"{start}\" 不是有效目录（{e.Message}）。" +
                "用 --repo-root 指定仓库根。", start, new[] { start });
        }

        while (dir != null)
        {
            searched.Add(dir.FullName);
            if (IsRepoRoot(dir.FullName)) return dir.FullName;
            dir = dir.Parent;
        }

        throw new RepoRootNotFoundException(
            $"找不到仓库根：从 \"{start}\" 向上都没有同时含 pubspec.yaml、bin\\alias_agent_core.dart " +
            $"的目录。用 --repo-root 指定仓库根。已检查：{string.Join(" → ", searched)}",
            start,
            searched);
    }
}

/// <summary>仓库根定位失败（可归因：带起点与已检查的目录列表）。</summary>
public sealed class RepoRootNotFoundException : Exception
{
    public RepoRootNotFoundException(string message, string startDirectory, IReadOnlyList<string> searched)
        : base(message)
    {
        StartDirectory = startDirectory;
        Searched = searched;
    }

    public string StartDirectory { get; }

    public IReadOnlyList<string> Searched { get; }
}
