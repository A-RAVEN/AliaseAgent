namespace AliasAgent.Desktop;

/// <summary>
/// 壳的命令行选项（change `windows-desktop-shell` D2 / 任务 3.2）。
///
/// 口径：
///   - `--config` / `--port` / `--repo-root` / `--selftest` / `--help`（`-h`）；
///   - 未知参数与缺值都**报错**（不静默忽略，否则用户以为生效了）；
///   - `--port 0` **必须被拒绝**：壳的全部意义是导航到 `http://127.0.0.1:&lt;port&gt;/`，
///     端口 0 只会得到一个空窗口；`0` 只保留给核心侧的调试与测试。
/// </summary>
public sealed class DesktopOptions
{
    /// <summary>
    /// 配置缺键时的默认端口（change `windows-desktop-shell` D2）。
    ///
    /// **这是壳侧唯一一处字面量**：`test/unit/desktop_shell_docs_test.dart` 会扫描
    /// `shell/**/*.cs`，别处再写一个同样的数字即红。数字出处见 design 附录 B。
    /// </summary>
    public const int DefaultCorePort = 16705;

    /// <summary>合法端口下界（TCP 端口域）。</summary>
    public const int MinPort = 1;

    /// <summary>合法端口上界（TCP 端口域）。</summary>
    public const int MaxPort = 65535;

    /// <summary>`--config`：配置文件路径；null = 核心自己用产品默认路径。</summary>
    public string? ConfigPath { get; private init; }

    /// <summary>`--port`：显式端口；null = 按配置 / 默认算（0 不允许出现在这里）。</summary>
    public int? CliPort { get; private init; }

    /// <summary>`--repo-root`：显式仓库根（跳过向上查找）。</summary>
    public string? RepoRoot { get; private init; }

    /// <summary>`--selftest`：无窗口自检模式（不取壳互斥体、不读用户配置）。</summary>
    public bool SelfTest { get; private init; }

    /// <summary>`--help` / `-h`。</summary>
    public bool Help { get; private init; }

    /// <summary>`--help` 的全文（用户文档与测试读同一份）。</summary>
    public const string Usage = """
        AliasAgent 桌面壳

        用法：AliasAgent.Desktop.exe [选项]

        选项：
          --config <path>    指定配置文件（默认 ~/.aliasagent/config.json）
          --port <n>         显式端口（1–65535）。0 仅核心调试可用，壳不接受
          --repo-root <path> 指定仓库根（默认从可执行文件目录向上找 pubspec.yaml）
          --selftest         无窗口自检：起核心 → core.ping → 静态页 → 停机（不开窗、不建托盘）
          -h, --help         显示本帮助
        """;

    /// <summary>
    /// 解析命令行。任何非法输入抛 <see cref="DesktopOptionException"/>（可归因，不猜）。
    /// </summary>
    public static DesktopOptions Parse(string[] args)
    {
        string? configPath = null;
        int? cliPort = null;
        string? repoRoot = null;
        var selfTest = false;
        var help = false;

        for (var i = 0; i < args.Length; i++)
        {
            var arg = args[i];
            string TakeValue()
            {
                if (i + 1 >= args.Length)
                {
                    throw new DesktopOptionException($"{arg} 需要一个参数（收到的命令里它是最后一个）");
                }

                i++;
                return args[i];
            }

            switch (arg)
            {
                case "--config":
                    configPath = TakeValue();
                    break;
                case "--port":
                    cliPort = ParsePort(TakeValue());
                    break;
                case "--repo-root":
                    repoRoot = TakeValue();
                    break;
                case "--selftest":
                    selfTest = true;
                    break;
                case "-h":
                case "--help":
                    help = true;
                    break;
                default:
                    throw new DesktopOptionException($"未知参数：{arg}");
            }
        }

        return new DesktopOptions
        {
            ConfigPath = configPath,
            CliPort = cliPort,
            RepoRoot = repoRoot,
            SelfTest = selfTest,
            Help = help,
        };
    }

    /// <summary>端口校验：显式输入非法即报错；`0` 单独给出「仅核心调试」的原因。</summary>
    private static int ParsePort(string raw)
    {
        if (!int.TryParse(raw, out var parsed))
        {
            throw new DesktopOptionException(
                $"--port 必须是整数（{MinPort}–{MaxPort}；0 仅核心调试可用），收到 \"{raw}\"");
        }

        if (parsed == 0)
        {
            throw new DesktopOptionException(
                "--port 0 被拒绝：0 仅核心调试可用（壳要导航到固定地址，端口 0 没有意义）");
        }

        if (parsed < MinPort || parsed > MaxPort)
        {
            throw new DesktopOptionException(
                $"--port 超出范围 {MinPort}–{MaxPort}（0 仅核心调试可用），收到 \"{raw}\"");
        }

        return parsed;
    }
}

/// <summary>命令行错误：入口打印消息 + 用法并以非零码退出。</summary>
public sealed class DesktopOptionException : Exception
{
    public DesktopOptionException(string message) : base(message)
    {
    }
}
