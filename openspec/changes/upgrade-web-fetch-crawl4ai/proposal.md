## Why

`web_fetch` 当前通过 libcurl 抓取原始 HTML 后用 `strip_html_tags()` 逐字符去标签，产出的文本混杂导航、页脚、广告，无结构无标题。对真实网页基本不可用——模型拿到一锅粥很难提取有效信息。crawl4ai（50k+ stars 的 Python 开源库）可以做到 Playwright 渲染 → 主体提取 → 干净 Markdown 输出，且通过 subprocess 调用保证崩溃隔离，不需要爬坑 Docker/端口/长驻进程。

## What Changes

- **C++ sidecar `web_fetch_impl`**: 新增 subprocess 路径——通过平台原生进程 API（Windows `CreateProcess` / POSIX `fork+exec`）调用 `fetch_worker.py`，stdin/stdout JSON 通信，30s 超时+进程组强杀。Python 不可用时降级到现有 curl 路径
- **C++ SSRF 升级**: subprocess 调用前解析 URL hostname，对字面 IP 直接检查黑名单；对域名先 DNS 解析再逐 IP 检查，命中黑名单则拒绝，不启动 subprocess
- **新增 `scripts/fetch_worker.py`**: 封装 crawl4ai 的 Python worker，接收 `{"url":"..."}`，输出 `{"ok":true,"title":"...","content":"# Markdown..."}`，内置基本的 scheme 校验作为 defense-in-depth
- **返回格式升级**: 响应新增 `title` 字段（页面标题）、`url` 字段（回显），`content` 从去标签纯文本变为干净 Markdown
- **Dart `_buildResultSections`**: web_fetch UI 卡片现在可以显示页面标题
- **保留 curl fallback**: 现有 libcurl + `strip_html_tags` 实现完整保留，作为 Python 不可用/超时/崩溃时的降级路径

## Capabilities

### New Capabilities
- `web-fetch`: Web 页面抓取与内容提取 — 通过 crawl4ai subprocess 获取干净、结构化的 Markdown 内容，含页面标题和主体文本

### Modified Capabilities
- `tool-call-result-display`: web_fetch 返回结果新增 `title` 字段，UI 卡片应展示页面标题

## Impact

- **2 新文件**: `scripts/fetch_worker.py`（Python worker）, `requirements.txt`（crawl4ai 依赖）
- **修改**: `sidecar/src/web_fetch.cpp`（新增 subprocess 路径、SSRF 增强、curl fallback 保留）、`sidecar/CMakeLists.txt`（安装 scripts/ 目录、保留 curl 链接）
- **修改**: `lib/main.dart`（`_buildResultSections` 读取 title）
- **保留**: `web_fetch.cpp` 中现有的 curl + `strip_html_tags` 逻辑作为 fallback（curl fallback 时 `content` 为 tag-stripped 纯文本）
- **sidecar C++ 测试**: `search_provider_test.cpp` 中的 `strip_html_tags` 和 curl 常量测试保留不删
- **用户依赖**: 推荐 `python3 -m venv .venv && source .venv/bin/activate && pip install crawl4ai && crawl4ai-setup`（隔离安装，不影响系统 Python）
- 无 FFI 接口变更，无持久化格式变更
