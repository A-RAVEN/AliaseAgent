## Context

当前 `web_fetch_impl`（`sidecar/src/web_fetch.cpp`）使用 libcurl 直接抓取 URL，然后 `strip_html_tags()` 逐字符剥离 HTML 标签。产出的是无结构的纯文本——导航栏、页脚、广告和正文混在一起。无页面标题、无 Markdown 结构、无主体内容提取。本质上只是一个 "HTML tag stripper"，不是真正的 web content extractor。

crawl4ai 是 Python 开源库（GitHub 50k+ stars），专门为 LLM 设计：Playwright 渲染 → 智能主体提取 → 干净 Markdown 输出。通过 subprocess 调用的方式，利用 OS 级进程隔离获得天然崩溃保护，无需 Docker 或长驻 HTTP 服务。

## Goals / Non-Goals

**Goals:**
- web_fetch 返回干净、结构化的 Markdown 内容（标题 + 正文），模型可以直接理解和引用
- 保留页面 title 元数据，用于 UI 展示
- subprocess 崩溃隔离：Python/crawl4ai/Chromium 任何一环崩了，不影响 C++ sidecar 和后续调用
- 保留 SSRF 防护：URL 和 socket 层面的安全检查仍由 C++ 执行

**Non-Goals:**
- 不实现 JS 渲染的动态内容抓取（crawl4ai 自身支持，但本次不暴露）
- 不实现结构化提取（CSS/XPath/LLM schema）
- 不实现多 URL 并发抓取
- 不修改 Dart FFI bridge 接口
- 不删除旧的 curl 实现（保留作为 fallback）

## Decisions

### D1: subprocess 通信协议 — stdin/stdout JSON，换行分隔

C++ sidecar 启动 Python worker，使用平台原生进程 API 以获得进程句柄（超时强杀需要）：

```
C++                                      Python (fetch_worker.py)
│                                               │
├── CreateProcess/fork+exec ────────────────────┤  启动，stdin/stdout pipe
│  ("python3", "fetch_worker.py")               │
│                                               │
├── write stdin: {"url":"..."}\n ──────────────┤  读取一行 JSON
│                                               │  await crawl4ai
│                                               │
├── read stdout line (30s timeout) ────────────┤  write {"ok":true,...}\n
│                                               │
├── CloseHandle/waitpid ────────────────────────┤  正常退出
│                                               │
│  OR (timeout):                                │
├── TerminateProcess/killpg ────────────────────┤  强制终止整个进程树
├── wait/cleanup ───────────────────────────────┤  回收资源
```

- **Windows**: `CreateProcess` + `CreatePipe` 重定向 stdin/stdout，`TerminateProcess` 杀进程，`JobObject` 杀子进程
- **POSIX**: `fork()` + `exec()` + `dup2()` 重定向，`killpg(pid, SIGKILL)` 杀进程组（子进程用 `setpgid` 归入同一组）

**Why**: 需要进程句柄/PID 来实现真正的超时强杀。`popen()` 只返回 `FILE*`，无法获取 PID，且 `pclose()` 只是 `wait` 不是 `kill`，不能用于超时场景。

**Alternatives considered**:
- `popen()` + `pclose()` → 无法 kill，超时时会永远阻塞在 `waitpid`
- HTTP subprocess → 太复杂，需要端口管理
- 临时文件 → 慢，竞态条件

### D2: Python worker 位置解析

`scripts/fetch_worker.py` — 独立可执行的 Python 脚本。C++ sidecar 在 subprocess 路径中通过以下策略找到它：

1. **开发模式**: 基于 DLL 路径向上找到项目根目录的 `scripts/`
   - Windows: `GetModuleFileName` 获取 sidecar.dll 路径 → 向上级目录搜索 `scripts/fetch_worker.py`
   - Linux: `dladdr` / `/proc/self/maps` 获取 .so 路径 → 同上
2. **安装模式**: CMake `install(FILES scripts/fetch_worker.py DESTINATION share/aliasagent/scripts)` 安装到固定位置，C++ 编译期知道安装路径

**Why**: 裸相对路径 `scripts/fetch_worker.py` 依赖 CWD，而安装版 app 的 CWD 可能是用户 home 目录或任意路径。DLL-relative 路径保证了无论在 IDE 中运行还是安装后运行都能找到脚本。

```python
import sys, json, asyncio
from crawl4ai import AsyncWebCrawler

async def main():
    line = sys.stdin.readline()
    req = json.loads(line)
    async with AsyncWebCrawler() as crawler:
        result = await crawler.arun(req["url"])
        resp = {
            "ok": True,
            "url": req["url"],
            "title": result.metadata.get("title", "") if result.metadata else "",
            "content": result.markdown or "",
        }
    print(json.dumps(resp, ensure_ascii=False), flush=True)

if __name__ == "__main__":
    asyncio.run(main())
```

### D3: Python 可用性检测 + 优雅降级

C++ sidecar 启动时检测 `python3` / `python` 是否可用（`popen("python3 --version")`），结果缓存到静态变量。如果不可用，`web_fetch_impl` 走旧 curl 路径并 log info。

同样，subprocess 调用本身失败（非零退出码、超时、进程无法启动）也 fallback 到 curl。

**Known limitation**: 检测结果缓存在 sidecar 进程生命周期内。如果用户在 sidecar 运行期间安装了 Python+crawl4ai，需重启 app 才能使用 crawl4ai 路径。重启对于桌面应用是正常行为，curl fallback 保证功能不受阻。

**Why**: 不强制用户安装 Python + crawl4ai。安装了就好用，没装也能用（质量较低但可用的旧实现）。

### D4: SSRF 三级防护

subprocess 路径需要在 C++ 侧完成充分的 SSRF 检查——不能依赖 Chromium sandbox（那只管进程隔离，不管网络出口）。

**第一级：URL pre-flight**（已有，保留）
- Scheme 校验：仅允许 `http://` 和 `https://`（case-insensitive）
- Hostname 字符串检查：拒绝 `localhost`（case-insensitive）

**第二级：IP + DNS 解析检查**（新增）
subprocess 调用前，对 URL hostname 做完整的 IP 检查：
1. 如果 hostname 是字面 IP 地址（dotted-quad IPv4 或 bracket IPv6）→ 直接用现有 `is_blocked_ipv4` / `is_blocked_ipv6` 检查
2. 如果 hostname 是域名 → 调用 `getaddrinfo` 解析，对每个解析到的 IP address 逐一用 blocklist 检查
3. 任一 IP 命中 blocklist → 拒绝请求并返回错误，不启动 subprocess

**第三级：已知限制**

crawl4ai 启动的 headless Chromium 会执行页面 JavaScript。页面内 JS 发起的子请求（`fetch()`、`XMLHttpRequest`）不受 C++ 侧控制。攻击者可以构造一个外部 URL 的页面，其 JS 向内网 IP 发请求并把结果注入 DOM，crawl4ai 会将其提取到 Markdown 输出中。

**Mitigation**: 在 Python worker 的 Playwright 配置中启用 `page.route()` 拦截，阻止对 RFC 1918 和保留 IP 段的子请求。这作为 defense-in-depth，不能完全替代 C++ 侧的主 URL 检查。

**为何不保留 `CURLOPT_OPENSOCKETFUNCTION`**: 该回调是 curl 专属的。subprocess 路径不使用 curl，等效的 socket 级防护由上述三级检查提供。

### D5: 移除 extract_mode 参数

当前 tool definition 中 `extract_mode` 仅支持 `"text"`，无实际可选值。crawl4ai 的 Markdown 输出在所有场景下优于 tag-stripped text。因此移除 `extract_mode` 参数，tool definition 简化为仅需 `url`。

### D6: 响应格式升级

crawl4ai 路径:
```
{"ok":true, "url":"https://...", "title":"Page Title", "content":"# Markdown..."}
```

curl fallback 路径（与旧格式兼容，新增 `url` 和 `title` 字段保持结构一致）:
```
{"ok":true, "url":"https://...", "title":"", "content":"stripped text..."}
```

新增 `url`（回显请求 URL）和 `title`（页面标题，curl 路径为空字符串）。Dart 端 `_buildResultSections` 读取 `title` 字段显示在卡片上。

### D7: 超时与进程清理

- **超时**: 30 秒 wall-clock（比 curl 的 15 秒宽松，crawl4ai 需启动 browser + 渲染）
- **超时处理**: 
  1. Windows: `TerminateProcess(hProcess, 1)` + 若子进程被归入 JobObject 则一并终止
  2. POSIX: `killpg(pid, SIGKILL)` 杀整个进程组（Python worker 启动时 `setpgid(0, 0)` 将自身和子进程归入新进程组）
  3. 杀进程后 `waitpid`/`WaitForSingleObject` 回收资源
  4. 清理后 fallback 到 curl
- **正常退出**: 等待进程退出 → 读取 stdout → 关闭 handles → `waitpid` 回收
- **已知风险**: 极端情况下 Chromium 子进程可能在被 kill 前脱离进程组（如 double-fork）。Playwright 通常不会这样做，但若发生会残留孤儿进程。进程组 ID 重用可以缓解但不能完全消除。若后续有问题可升级为 OS 级 cgroup/JobObject 隔离。

## Risks / Trade-offs

- [crawl4ai 未安装] 用户没跑 `pip install crawl4ai` → C++ fallback 到旧 curl 实现，log info 提示
- [首次调用慢] crawl4ai 冷启动 Playwright + Chromium 约 2-5 秒 → 可接受，web_fetch 不是高频调用
- [Python 版本] crawl4ai 需要 Python 3.9+ → 检测时验证版本
- [Windows 兼容] Windows 上 `python` vs `python3` 命令名差异 → 按平台自动探测
- [Chromium 下载] `crawl4ai-setup` 会下载 Chromium（~150MB）→ 在安装文档中说明
- [内存占用] Chromium 单 tab 约 300-500MB 常驻内存。每次 web_fetch 调用创建新进程 → 无并发限制时可能叠加。Mitigation: 目前无并发 web_fetch 场景（单模型单轮只发一个 tool call），但应在文档中标明内存建议
- [JS SSRF] 页面内 JavaScript 可通过 fetch() 访问内网 IP → D4 第三级：Python worker 用 `page.route()` 拦截 RFC 1918 请求
- [孤儿 Chromium 进程] 超时强杀 Python 进程后 Chromium 子进程可能残留 → D7 用进程组/job object 清理，极端 double-fork 场景仍有残留可能（已知限制）
- [Python 环境隔离] 推荐 `python3 -m venv` 隔离安装，避免 crawl4ai 的传递依赖污染系统 Python → 在安装文档中说明

## Open Questions

无。
