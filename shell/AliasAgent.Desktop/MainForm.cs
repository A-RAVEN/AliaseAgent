using System.Runtime.InteropServices;
using System.Text;
using Microsoft.Web.WebView2.Core;
using Microsoft.Web.WebView2.WinForms;

namespace AliasAgent.Desktop;

/// <summary>
/// 壳的窗口：`Form` 承载 `WebView2`（change `windows-desktop-shell` D4 / 任务 4.1）。
///
/// 要点：
///   - 先 `CoreWebView2Environment.CreateAsync(null, 用户数据目录, null)` 建环境，再
///     `EnsureCoreWebView2Async(env)`，然后 `Navigate(http://127.0.0.1:&lt;port&gt;/)`；
///   - 用户数据目录 = `%LOCALAPPDATA%\AliasAgent\WebView2`（不跟配置/数据库混放）；
///   - 初始化失败 → 走 <see cref="WebView2FailurePolicy"/> 的决策（停核心 + 放锁 +
///     非零退出）：这里只产出决策，回收动作由启动序列执行；
///   - 导航失败 → 就地上错误页（`NavigateToString`），点托盘重新打开时再导航一次；
///   - 首次打开即最大化（不发明「屏宽百分之多少」）。
///
/// 窗口外观归视觉验收（任务 6.2，需用户当场许可）；本类只保证「不把窗口塞进外部
/// 浏览器」「失败不留孤儿核心」这两条可核行为。
/// </summary>
internal sealed class MainForm : Form
{
    private string _url;
    private readonly Action<string> _log;
    private readonly WebView2 _webView;
    private bool _lastNavigationFailed;

    public MainForm(string url, Action<string> log)
    {
        _url = url ?? throw new ArgumentNullException(nameof(url));
        _log = log ?? (_ => { });

        Text = "AliasAgent";
        StartPosition = FormStartPosition.CenterScreen;
        WindowState = FormWindowState.Maximized;
        _webView = new WebView2 { Dock = DockStyle.Fill };
        Controls.Add(_webView);
    }

    /// <summary>WebView2 初始化失败时的回收决策（成功时为 null）。</summary>
    public ShellAbortDecision? AbortDecision { get; private set; }

    /// <summary>初始化 WebView2 并导航到固定地址。失败返回 false（决策在 <see cref="AbortDecision"/>）。</summary>
    public async Task<bool> InitializeWebView2Async(WebView2FailurePolicy policy, string userDataFolder)
    {
        try
        {
            var environment = await CoreWebView2Environment.CreateAsync(
                browserExecutableFolder: null,
                userDataFolder: userDataFolder,
                options: null).ConfigureAwait(true);
            await _webView.EnsureCoreWebView2Async(environment).ConfigureAwait(true);
        }
        catch (Exception e)
        {
            AbortDecision = policy.Failure(e, userDataFolder).Abort;
            _log($"[shell] WebView2 初始化失败：{e.Message}");
            return false;
        }

        var core = _webView.CoreWebView2;
        if (core == null)
        {
            AbortDecision = policy.Failure(
                new InvalidOperationException("EnsureCoreWebView2Async 返回后 CoreWebView2 仍为 null"),
                userDataFolder).Abort;
            return false;
        }

        core.NavigationCompleted += OnNavigationCompleted;
        core.Navigate(_url);
        _log($"[shell] 窗口已导航到 {_url}");
        return true;
    }

    /// <summary>显示并激活窗口；上次导航失败则重新导航一次（错误页上的「再打开可重试」）。</summary>
    public void ShowAndActivate()
    {
        if (!Visible) Show();
        if (WindowState == FormWindowState.Minimized) WindowState = FormWindowState.Maximized;
        Activate();
        BringToFront();
        try
        {
            Win32SetForegroundWindow(Handle);
        }
        catch
        {
            // 前台锁偶尔会挡住；已经 Activate 过，不因此失败。
        }

        if (_lastNavigationFailed)
        {
            _lastNavigationFailed = false;
            _webView.CoreWebView2?.Navigate(_url);
            _log($"[shell] 上次导航失败，重新打开窗口后重试 {_url}");
        }
    }

    /// <summary>
    /// 重启核心后复用本窗口：把地址更新成当前壳地址并重新导航（任务 6.1d）。
    ///
    /// 为什么需要单独入口：崩溃错误页是 `NavigateToString` 进去的，而 `ShowAndActivate`
    /// 只在「上次导航失败」时重试；重启复用旧窗口时必须显式回到固定地址，否则窗口会一直
    /// 停在错误页。地址用参数传入（重启会重新解析配置，端口可能变）。
    /// </summary>
    public void ReloadShellPage(string url)
    {
        _url = url ?? throw new ArgumentNullException(nameof(url));
        _lastNavigationFailed = false;
        var core = _webView.CoreWebView2;
        if (core == null)
        {
            // 生产里重启只发生在窗口已初始化之后；走到这里说明窗口还没初始化，
            // 留给 ShowAndActivate 的失败重试分支再试（不静默当成功）。
            _lastNavigationFailed = true;
            _log($"[shell] 重启：窗口的 WebView2 尚未初始化，暂不能重新导航到 {_url}");
            return;
        }

        core.Navigate(_url);
        _log($"[shell] 重启：窗口已重新导航到 {_url}");
    }

    /// <summary>核心崩溃时就地显示可归因错误页（不弹一堆对话框）。</summary>
    public void ShowErrorPage(string title, string detail, string hint)
    {
        var html = BuildErrorPage(title, detail, hint);
        try
        {
            _webView.CoreWebView2?.NavigateToString(html);
            _log($"[shell] 窗口已切到错误页：{title}");
        }
        catch (Exception e)
        {
            _log($"[shell] 显示错误页失败：{e.Message}");
        }
    }

    private void OnNavigationCompleted(object? sender, CoreWebView2NavigationCompletedEventArgs e)
    {
        if (e.IsSuccess) return;
        _lastNavigationFailed = true;
        _log($"[shell] 导航失败：{e.WebErrorStatus}（{e.NavigationId}）");
        ShowErrorPage(
            "界面加载失败",
            $"导航到 {_url} 失败：{e.WebErrorStatus}",
            "从托盘关掉窗口再打开可重试（核心可能还没就绪，或 web 产物不完整）。");
    }

    private static string BuildErrorPage(string title, string detail, string hint)
    {
        static string Escape(string value) => System.Net.WebUtility.HtmlEncode(value);
        var builder = new StringBuilder();
        builder.AppendLine("<!doctype html><html lang=\"zh-CN\"><head><meta charset=\"utf-8\">");
        builder.AppendLine($"<title>{Escape(title)}</title>");
        builder.AppendLine("<style>body{font-family:system-ui,'Segoe UI',sans-serif;background:#0b0f19;color:#e6e9ef;" +
                           "margin:0;display:flex;min-height:100vh;align-items:center;justify-content:center}" +
                           "main{max-width:640px;padding:32px;border:1px solid #2a3346;border-radius:12px;background:#111726}" +
                           "h1{font-size:20px;margin:0 0 16px}p{font-size:14px;line-height:1.6;margin:8px 0}</style>");
        builder.AppendLine("</head><body><main>");
        builder.AppendLine($"<h1>{Escape(title)}</h1>");
        builder.AppendLine($"<p>{Escape(detail)}</p>");
        builder.AppendLine($"<p>{Escape(hint)}</p>");
        builder.AppendLine("</main></body></html>");
        return builder.ToString();
    }

    [DllImport("user32.dll", SetLastError = true)]
    private static extern bool Win32SetForegroundWindow(IntPtr hWnd);
}
