## Context

当前测试架构三层：
- **Tier 1 (C++ Catch2)**: 单元测试覆盖 provider 逻辑，但不经过 `sidecar_api.cpp` FFI 包装器
- **Tier 2 (Dart widget)**: 使用 FakeSidecar，完全模拟 FFI 调用
- **Tier 3 (Dart integration)**: 同上，使用 FakeSidecar

缺失的一层：真实 sidecar.dll 的 Dart 集成测试。这一层应验证：
1. DLL 能正确加载（已在 `test/unit/sidecar_bridge_test.dart` 部分覆盖）
2. 每个 `extern "C"` FFI 函数能正确调用并返回合理结果
3. 应用能启动到无红屏状态

fakeSidecar 的问题：所有 FFI 调用（包括 `ensure_search_infra`）被替换为 Dart mock，`sidecar_api.cpp` 的 C++ 包装器从未被测试路径调用，导致函数重载歧义（无限递归）漏网。

## Goals / Non-Goals

**Goals:**
- 为每个 `extern "C"` FFI 导出函数添加至少一个真实 DLL 调用测试
- 修复 `test/smoke/04_launch_and_verify.sh` 使其可实际运行
- 测试不依赖外部网络或 API key
- 测试可在 `flutter test` 中运行（自动发现、可 CI）

**Non-Goals:**
- 不替换现有 widget/integration 测试
- 不添加需要真实 API key 的端到端对话测试（那是 smoke test 的范畴）
- 不添加需要 GUI 交互的测试

## Decisions

### D1: 真实 DLL 测试放在 `test/unit/sidecar_bridge_test.dart`

扩展已有的 smoke test 文件，为每个 FFI 函数添加独立的 `test()` 块。

**Rationale**: 已有 `DynamicLibrary.open` 验证，该文件是 DLL 加载的唯一真实测试入口。每个函数独立测试，失败时能精确定位是哪个 FFI 符号崩了。

### D2: DLL 路径搜索策略

测试中 `DynamicLibrary.open('sidecar.dll')` 只搜索当前目录（`flutter test` 的 CWD = 项目根）。DLL 由 `run.bat` 在测试前拷贝到项目根。

**Rationale**: 避免路径依赖问题。Release sidecar.dll 无 CRT 依赖问题。

### D3: 不依赖网络的测试范围

只测不需要网络的函数：
- `set_workspace` — 设置工作目录，验证返回值
- `read_file` — 读已知文件，验证内容
- `list_dir` — 列已知目录，验证 JSON 格式
- `ensure_search_infra` — 传入空配置 `{}`，验证返回 `{"ok":true}` 且不挂起
- `get_search_providers` — 验证返回合法 JSON 数组

**不测**（需要网络/API key）：
- `web_search` — 需要真实 search provider
- `web_fetch` — 需要真实 HTTP server
- `send_message` — 需要真实 API key

### D4: Smoke test 修复策略

`test/smoke/04_launch_and_verify.sh` 当前逻辑是正确的但从未通过：
- `launch_app` 函数需要能找到 exe 路径
- `wait_for_window` 需要能用 PowerShell 检测窗口标题
- `verify_logs` 需要检查 sidecar.log 无 ERROR
- `verify_db` 需要检查 aliasagent.db 有正确的表结构

不需要新增逻辑，只需修复现有脚本中的路径、变量和命令引用。

## Risks / Trade-offs

| Risk | Mitigation |
|------|------------|
| Debug DLL CRT 依赖导致 `flutter test` 中加载失败 | 使用 Release sidecar.dll（由 `run.bat` 构建并拷贝） |
| `read_file`/`list_dir` 测试依赖文件系统状态 | 使用项目根目录下的已知文件（pubspec.yaml 等）作为测试目标 |
| `ensure_search_infra` 的 SearXNG liveness check 阻塞 | 空配置 `{}` 走快速返回路径，不触发 check |
