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

### D8: 移除 100KB write callback cap

curl fallback 路径的 `fetch_write_callback` 中有一个 100KB 累积上限（`FetchWriteCtx::MAX_RESPONSE_SIZE`），超过后返回 0 中断传输。

**问题**: 100KB 对现代网页太小。B 站等 SPA 页面原始 HTML 轻松超过 100KB，导致 curl fallback 误杀正常请求（`CURLE_WRITE_ERROR` → "Failed writing received data"）。

**分析**: 该 cap 的原始理由是防 zip bomb 和无限流。但 15s 超时已经是天然的流量上限——即使 1Gbps 带宽，15 秒也只能传 ~1.8GB。真正需要防的 gzip 解压炸弹，用 `CURLOPT_MAXFILESIZE`（基于 Content-Length 头）比在 write callback 里硬截断更精确。主观数字 cap 和写死 5 轮循环是同一类问题——用猜测的常量假设外部世界。

**决定**: 移除 write callback 中的 100KB cap，同时添加 `CURLOPT_MAXFILESIZE`（10MB）作为替代防护。该选项基于 Content-Length 头，在传输开始前拒绝声明过大的响应，比在 write callback 里硬截断更精确。对于不发送 Content-Length 的 chunked 响应，15s 超时仍是兜底。crawl4ai 路径不受影响（输出是提取后的 Markdown，天然有界）。

**测试影响**: `search_provider_test.cpp` 中 "write callback caps at 100KB" TEST_CASE（lines 559-577）引用 `FetchWriteCtx::MAX_RESPONSE_SIZE` 并断言 cap 行为。需更新为验证无 cap 行为（正常追加、返回 total）。需用户明确授权修改测试代码。

**注释清理**: `web_fetch.h`（Features 注释、FetchWriteCtx 文档）和 `web_fetch.cpp`（section banner）中描述 100KB cap 的注释需同步更新。

### D9: Python worker stdout 编码修复

`fetch_worker.py` 使用 `print(json.dumps(resp, ensure_ascii=False))` 输出结果。在 Windows 上，stdout 默认编码为 cp1252（系统 locale），无法编码中文字符 → `UnicodeEncodeError` → 进程崩溃 → C++ 读到空 stdout → 误判为 "subprocess produced no output"。

**决定**: 改为 `ensure_ascii=True`（Python json.dumps 默认值）。所有非 ASCII 字符转为 `\uXXXX` 转义序列，对任何 stdout 编码安全。C++ 端 nlohmann/json 能正确解析 `\uXXXX`。

**替代方案**: 也可以用 `sys.stdout.buffer.write(json.dumps(...).encode('utf-8'))` 强制 UTF-8 输出。但 `ensure_ascii=True` 更简单，且 JSON 标准保证 `\uXXXX` 转义在所有解析器中等价。

### D10: 捕获 subprocess stderr 到 sidecar.log

当前 subprocess 的 stderr 直接继承父进程，输出到控制台（或黑洞）。crawl4ai/Python 的错误信息（如 UnicodeEncodeError 的 traceback）完全丢失，无法排查问题。

**决定**: 创建第三个 pipe 捕获 stderr。subprocess 结束后读取 stderr 内容写入 sidecar.log。

- **Windows**: `CreatePipe(&hStdErrRd, &hStdErrWr, &sa, 0)`，`SetHandleInformation(hStdErrRd, HANDLE_FLAG_INHERIT, 0)`（读端不可继承），`si.hStdError = hStdErrWr`。`CreateProcess` 后**立即** `CloseHandle(hStdErrWr)`（父进程关闭 write end，否则 ReadFile 等不到 EOF）。读取用 `PeekNamedPipe` 检查可用数据 + `ReadFile`，避免 blocking hang。
- **POSIX**: `pipe(pipe_stderr)`，子进程 `dup2(pipe_stderr[1], STDERR_FILENO)` + `close(pipe_stderr[0])`，父进程 `close(pipe_stderr[1])`（关闭 write end）。读取用 `fcntl(O_NONBLOCK)` + `read()`，避免孤儿进程持有 write end 时 blocking hang。

**日志级别**: 成功时 stderr 内容（crawl4ai 进度日志 `[INIT][FETCH][SCRAPE][COMPLETE]`）用 `LOG_DEBUG`；失败/超时时用 `LOG_WARN`。避免每次成功调用产生 WARN 噪音。

stderr 内容仅用于日志，不参与结果解析。

### D11: 修复 Windows pipe 死锁（stdout + stderr）

当前 Windows 路径的读取顺序是：`WaitForSingleObject(进程退出)` → `ReadFile(stdout)` → `PeekNamedPipe(stderr)`。当 subprocess 的 stdout **或 stderr** 输出超过 pipe buffer（Windows 匿名管道默认 4KB）时，Python 端阻塞在 write，进程无法退出；C++ 端等待进程退出后才读——**双向等待，死锁**。30s 超时后 fallback 到 curl。

**stderr 比 stdout 更早触发**：fetch_worker.py 在 import 阶段就 dump 全量环境变量到 stderr（>4KB），此时 stdin 还没读、stdout 还没写。即使只修 stdout 不修 stderr，死锁仍然发生。

小页面（example.com ~300 bytes stdout）不触发，大页面（bilibili ~45KB stdout）必触发。env dump（>4KB stderr）在所有页面都触发。

**决定**: 两层修复：

**第一层：增大 pipe buffer**。`CreatePipe` 的 `nSize` 参数从默认 0（4KB）改为 1MB（stdin/stdout/stderr 三个管道都改）。这覆盖了绝大多数正常场景，一行代码。

**第二层：并发轮询**。Windows 路径改为 `PeekNamedPipe` 同时轮询 stdout 和 stderr + 短间隔 `WaitForSingleObject`（100ms）交替循环。进程退出后做最终 drain（两个管道都读到 PeekNamedPipe 返回 0），确保不丢尾部数据。

```
loop:
  PeekNamedPipe(hStdOutRd) → 有数据就 ReadFile → append to output
  PeekNamedPipe(hStdErrRd) → 有数据就 ReadFile → append to stderr_output
  WaitForSingleObject(hProcess, 100ms)
    → WAIT_OBJECT_0: 做最终 drain（两个管道都 PeekNamedPipe+ReadFile 直到 avail==0）→ break
    → WAIT_TIMEOUT: 继续循环
  超时检查 → 30s 到就 kill → 做最终 drain → break
```

**POSIX 路径**：stdout 已有 `select()` 并发读取，不受影响。stderr 当前不在 `select()` 里，但 POSIX pipe buffer 是 64KB，env dump 通常不超。将 stderr 加入 `select()` 的 fd_set 作为加固。

**替代方案考虑**：只增大 pipe buffer 不做并发轮询 → 如果页面内容 >1MB 仍然死锁。两层一起做才完整。

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
