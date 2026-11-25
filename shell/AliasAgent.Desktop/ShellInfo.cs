namespace AliasAgent.Desktop;

/// <summary>
/// 壳工程骨架的自述信息（change `windows-desktop-shell` 任务 3.1 的验收锚点）。
/// </summary>
public static class ShellInfo
{
    /// <summary>目标框架（长期支持版；本机用 SDK 11 构建 net10 目标）。</summary>
    public const string TargetFramework = "net10.0-windows";

    /// <summary>自包含产物里的壳可执行文件名（构建脚本与用户文档都读它）。</summary>
    public const string ExecutableName = "AliasAgent.Desktop.exe";

    /// <summary>WebView2 加载器（构建脚本的产物校验项之一）。</summary>
    public const string WebView2LoaderName = "WebView2Loader.dll";
}
