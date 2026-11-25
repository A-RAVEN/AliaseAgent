namespace AliasAgent.Desktop;

/// <summary>预检输入（全部由调用方注入，测试不碰真实环境）。</summary>
public sealed class PreflightInputs
{
    /// <summary>已定位的仓库根；null = 没找到。</summary>
    public string? RepoRoot { get; init; }

    /// <summary>仓库根定位失败的原因（可归因文本，直接进问题清单）。</summary>
    public string? RepoRootError { get; init; }

    /// <summary>已解析的 dart；null = 没找到。</summary>
    public DartExecutable? Dart { get; init; }

    /// <summary>dart 解析失败的原因（可归因文本，直接进问题清单）。</summary>
    public string? DartError { get; init; }
}

/// <summary>预检结果：`Ok=false` 时 <see cref="Problems"/> 每条都点名「缺什么 + 怎么补」。</summary>
public sealed class PreflightResult
{
    public PreflightResult(IReadOnlyList<string> problems, string? webIndexPath)
    {
        Problems = problems;
        WebIndexPath = webIndexPath;
    }

    public bool Ok => Problems.Count == 0;

    public IReadOnlyList<string> Problems { get; }

    /// <summary>检查过的 `web/dist/index.html` 路径（仓库根没找到时为 null）。</summary>
    public string? WebIndexPath { get; }
}

/// <summary>
/// 启动前预检（change `windows-desktop-shell` D3 / 任务 3.6）。
///
/// 三项：仓库根、`dart`、`web/dist/index.html`。失败项**逐条点名并可操作**，不带着
/// 已知缺失继续启动 —— 否则窗口里只会得到一个 503 文本页，用户看不出该补什么。
/// 文件存在性从构造函数注入（测试不建真实目录、不改真实机器环境）。
/// </summary>
public sealed class Preflight
{
    private readonly Func<string, bool> _fileExists;

    public Preflight(Func<string, bool>? fileExists = null)
    {
        _fileExists = fileExists ?? File.Exists;
    }

    public PreflightResult Check(PreflightInputs inputs)
    {
        var problems = new List<string>();

        var repoRoot = inputs.RepoRoot;
        if (string.IsNullOrWhiteSpace(repoRoot))
        {
            problems.Add("仓库根不可定位：" +
                         (string.IsNullOrWhiteSpace(inputs.RepoRootError)
                             ? "从可执行文件目录向上找不到含 pubspec.yaml 与 bin\\alias_agent_core.dart 的目录。"
                             : inputs.RepoRootError) +
                         " 补法：用 --repo-root <仓库根> 指定，或把壳放回仓库目录树下运行。");
        }

        if (inputs.Dart == null)
        {
            problems.Add("dart 不可解析：" +
                         (string.IsNullOrWhiteSpace(inputs.DartError)
                             ? "环境变量 ALIASAGENT_DART 未设置，PATH 上也没有 dart。"
                             : inputs.DartError) +
                         " 补法：装 Flutter SDK / 把 dart 放进 PATH / 用 ALIASAGENT_DART 指定。");
        }

        string? webIndexPath = null;
        if (!string.IsNullOrWhiteSpace(repoRoot))
        {
            webIndexPath = Path.Combine(repoRoot, "web", "dist", "index.html");
            if (!_fileExists(webIndexPath))
            {
                problems.Add($"web 客户端构建产物不存在：{webIndexPath}。 " +
                             "补法：先构建 —— cd web && npm install && npm run build");
            }
        }

        return new PreflightResult(problems, webIndexPath);
    }
}
