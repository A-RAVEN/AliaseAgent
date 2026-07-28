## Context

当前测试架构三层：
- **Tier 1 (C++ Catch2)**: 单元测试覆盖 provider 逻辑、SSRF blocklist、write callback 等，但不经过 `sidecar_api.cpp` FFI 包装器
- **Tier 2 (Dart widget)**: 使用 FakeSidecar，完全模拟 FFI 调用
- **Tier 3 (Dart integration)**: 同上，使用 FakeSidecar

缺失的一层：真实 sidecar.dll 的 Dart 集成测试。这一层应验证：
1. DLL 能正确加载（已在 `test/unit/sidecar_bridge_test.dart` 部分覆盖）
2. 每个离线可测的 `extern "C"` FFI 函数能正确调用并返回合理结果
3. 应用能启动到无红屏状态

fakeSidecar 的问题：所有 FFI 调用（包括 `ensure_search_infra`）被替换为 Dart mock，`sidecar_api.cpp` 的 C++ 包装器从未被测试路径调用，导致函数重载歧义（无限递归）漏网。

crawl4ai 升级后的新问题：web_fetch 引入了 subprocess 架构（Python 检测、脚本路径解析、pipe 管理、SSRF 前置检查），pipe 死锁 bug 就是 mock 测试无法发现的典型案例。

## Goals / Non-Goals

**Goals:**
- 为每个离线可测的 `extern "C"` FFI 导出函数添加至少一个真实 DLL 调用测试（含 `ping`）
- 验证 web_fetch SSRF 前置检查（字面 IP 拦截，不需要网络）
- 测试不依赖外部网络或 API key
- 测试可在 `flutter test` 中运行（自动发现、可 CI）

**Non-Goals:**
- 不替换现有 widget/integration 测试
- 不添加需要真实 API key 的端到端对话测试（那是 smoke test 的范畴）
- 不添加需要 GUI 交互的测试
- 不添加需要真实网络请求的测试（web_search 端到端、web_fetch 抓取真实页面）

## Decisions

### D1: 真实 DLL 测试放在 `test/unit/sidecar_bridge_test.dart`

扩展已有的 smoke test 文件，为每个 FFI 函数添加独立的 `test()` 块。

**Rationale**: 已有 `DynamicLibrary.open` 验证，该文件是 DLL 加载的唯一真实测试入口。每个函数独立测试，失败时能精确定位是哪个 FFI 符号崩了。

### D2: DLL 路径搜索策略

测试中 `DynamicLibrary.open` 搜索两个路径：`sidecar.dll`（CWD）和 `build\windows\x64\runner\Debug\sidecar.dll`。DLL 由 `run.bat` 构建并拷贝。

### D3: 测试范围

**离线可测**（不需要网络）：
- `ping` — 返回 "pong"，验证 FFI bridge 基本连通性
- `set_workspace` — 设置工作目录，验证返回值。**必须在 read_file/list_dir 之前调用**
- `read_file` — 读已知文件（需先 set_workspace），验证内容
- `list_dir` — 列已知目录（需先 set_workspace），验证 JSON 格式
- `ensure_search_infra` — 传入空配置 `{}`，验证返回 `{"ok":true}` 且不挂起
- `get_search_providers` — 验证返回合法 JSON 数组
- `web_fetch` SSRF 前置检查 — 传入 `http://192.168.1.1/` 等内网 IP，验证返回 SSRF 错误（请求在 DNS/IP 检查阶段被拒绝，不发出网络请求）

**不测**（需要网络/API key/外部依赖）：
- `web_search` — 需要真实 search provider API key
- `web_fetch` 端到端抓取 — 需要真实 HTTP 请求（crawl4ai 或 curl）
- `send_message` — 需要真实 API key

**关于 web_fetch**: 虽然端到端抓取需要网络，但 SSRF 前置检查（`is_hostname_ssrf_blocked`）在发出任何网络请求之前就执行，传入字面内网 IP 时立即返回错误。这部分可以离线测试，且是安全关键路径。

### D4: Smoke test 状态

`test/smoke/` 脚本已完整实现（`utils.sh` 包含 launch_app、wait_for_window、verify_logs、verify_db、capture_screenshot、kill_app），`04_launch_and_verify.sh` 是完整的 6 步流程。`run.bat` step 3 已运行 `flutter test test\unit\sidecar_bridge_test.dart`。

剩余工作：端到端运行确认（task 3.6）和 run.bat 全流程确认（task 4.2）。

## Risks / Trade-offs

| Risk | Mitigation |
|------|------------|
| Debug DLL CRT 依赖导致 `flutter test` 中加载失败 | 测试搜索两个路径（CWD + build/Debug），兼容不同构建配置 |
| `read_file`/`list_dir` 测试依赖文件系统状态 | 使用项目根目录下的已知文件（pubspec.yaml 等）作为测试目标 |
| `ensure_search_infra` 的 SearXNG liveness check 阻塞 | 空配置 `{}` 走快速返回路径，不触发 check |
| web_fetch SSRF 测试中 DNS 解析可能触发网络 | 只测字面 IP（如 `192.168.1.1`），不测域名（域名需要 DNS 解析） |
| Python/crawl4ai 依赖链断裂导致 web_fetch 静默降级到 curl | 当前测试层不覆盖（需要 Python 环境），由 C++ Catch2 测试覆盖 SSRF blocklist 逻辑 |
| `set_workspace` 未在 `read_file` 前调用导致路径解析失败 | 测试中显式按顺序调用：set_workspace → read_file/list_dir |
