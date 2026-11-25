namespace AliasAgent.Desktop;

/// <summary>
/// 解析到的 `dart` 可执行文件（change `windows-desktop-shell` D3 / 任务 3.5）。
///
/// 本机 `Get-Command dart` 只给到 `E:\Flutter\flutter\bin\dart.bat`：`CreateProcess`
/// 不能直接执行批处理，所以 `.bat` / `.cmd` 必须经 `cmd.exe /C` 启动（并且引用规则
/// 是另一套 —— 见 <see cref="CoreCommandBuilder"/>）。
/// </summary>
public sealed class DartExecutable
{
    public DartExecutable(string path, bool requiresCmdWrapper)
    {
        Path = path;
        RequiresCmdWrapper = requiresCmdWrapper;
    }

    /// <summary>真实的 dart 路径（`.exe` / `.bat` / `.cmd` 之一）。</summary>
    public string Path { get; }

    /// <summary>是否必须经 `cmd.exe /C` 启动（批处理为 true）。</summary>
    public bool RequiresCmdWrapper { get; }

    /// <summary>进程启动时用的可执行文件：批处理 → `cmd.exe`；其余 → dart 自己。</summary>
    public string FileName => RequiresCmdWrapper ? "cmd.exe" : Path;

    /// <summary>启动时先放的可执行文件参数（批处理 → `/C`；其余 → 无）。</summary>
    public IReadOnlyList<string> PrefixArguments =>
        RequiresCmdWrapper ? new[] { "/C" } : Array.Empty<string>();
}

/// <summary>
/// `dart` 解析器（change `windows-desktop-shell` D3 / 任务 3.5）。
///
/// 顺序：环境变量 `ALIASAGENT_DART` → PATH 上的 `dart.exe` → PATH 上的
/// `dart.bat` / `dart.cmd` → 报错（三种补法都点名）。环境变量与 PATH 都从构造函数
/// 注入，测试不读、也不改真实机器的环境。
/// </summary>
public sealed class DartExecutableResolver
{
    public const string EnvironmentVariable = "ALIASAGENT_DART";

    private readonly Func<string, string?> _variable;
    private readonly Func<string> _pathValue;
    private readonly Func<string, bool> _fileExists;

    public DartExecutableResolver(
        Func<string, string?>? variable = null,
        Func<string>? pathValue = null,
        Func<string, bool>? fileExists = null)
    {
        _variable = variable ?? Environment.GetEnvironmentVariable;
        _pathValue = pathValue ?? (() => Environment.GetEnvironmentVariable("PATH") ?? string.Empty);
        _fileExists = fileExists ?? File.Exists;
    }

    /// <summary>解析 dart。全部落空抛 <see cref="DartNotFoundException"/>（可归因）。</summary>
    public DartExecutable Resolve()
    {
        var overridden = _variable(EnvironmentVariable);
        if (!string.IsNullOrWhiteSpace(overridden))
        {
            var candidate = overridden.Trim().Trim('"');
            if (!_fileExists(candidate))
            {
                throw new DartNotFoundException(
                    $"{EnvironmentVariable} 指向的文件不存在：\"{candidate}\"。\n" +
                    "三种补法：① 装 Flutter SDK；② 把 dart 放进 PATH；③ 用 " +
                    $"{EnvironmentVariable} 指定真实的 dart 可执行文件路径。");
            }

            return new DartExecutable(candidate, RequiresCmdWrapper(candidate));
        }

        var directories = (_pathValue() ?? string.Empty)
            .Split(Path.PathSeparator, StringSplitOptions.RemoveEmptyEntries)
            .Select(entry => entry.Trim().Trim('"'))
            .Where(entry => entry.Length > 0)
            .ToList();

        // 第一轮：所有目录里的 dart.exe（exe 优先于批处理）。
        foreach (var directory in directories)
        {
            var candidate = Path.Combine(directory, "dart.exe");
            if (_fileExists(candidate)) return new DartExecutable(candidate, false);
        }

        // 第二轮：dart.bat / dart.cmd（本机的真实形态）。
        foreach (var name in new[] { "dart.bat", "dart.cmd" })
        {
            foreach (var directory in directories)
            {
                var candidate = Path.Combine(directory, name);
                if (_fileExists(candidate)) return new DartExecutable(candidate, true);
            }
        }

        throw new DartNotFoundException(
            "找不到 dart：环境变量 " + EnvironmentVariable + " 未设置，PATH 上也没有 " +
            "dart.exe / dart.bat / dart.cmd。\n" +
            "三种补法：① 装 Flutter SDK；② 把 dart 放进 PATH；③ 用 " +
            EnvironmentVariable + " 指定 dart 可执行文件的绝对路径。\n" +
            "（当前检查的 PATH 条目：" + string.Join("；", directories) + "）");
    }

    private static bool RequiresCmdWrapper(string path)
    {
        var extension = Path.GetExtension(path);
        return extension.Equals(".bat", StringComparison.OrdinalIgnoreCase) ||
               extension.Equals(".cmd", StringComparison.OrdinalIgnoreCase);
    }
}

/// <summary>`dart` 找不到 / 环境变量指向无效路径（可归因：三种补法都写出来）。</summary>
public sealed class DartNotFoundException : Exception
{
    public DartNotFoundException(string message) : base(message)
    {
    }
}
