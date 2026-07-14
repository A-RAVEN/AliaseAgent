## Context

AliasAgent 是一个 Flutter 桌面应用，核心状态集中在 `_ChatScreenState`，通过 C FFI 调用 sidecar。当前验证手段分散：`dart analyze`（静态）、`flutter build`（编译）、`checkpoint_X_verify.dart`（逻辑层）、手动启动 + 侧车日志（运行时）。缺少一个统一的编排层，也没有视觉验证能力。

Claude 运行环境：可执行 bash 命令、读写文件、查询 SQLite、读取日志，且 MCP 提供 `ui_diff_check`、`analyze_image`、`extract_text_from_screenshot` 等截图分析工具。瓶颈在截图——Flutter 的 GPU 渲染无法被 Windows GDI `PrintWindow` 捕获，但 PowerShell `CopyFromScreen` 直接读取屏幕缓冲区，可以正确捕获 GPU 渲染窗口。

## Goals / Non-Goals

**Goals:**
- 提供一键 `bash test/smoke/run_all.sh`，跑完整 verification pipeline
- 串联现有 checkpoint 脚本到统一流程
- 截图 + MCP 图像分析做 UI 视觉验证
- 通过 sidecar 日志和 SQLite DB 验证运行时行为

**Non-Goals:**
- 不做 Flutter `integration_test`（方案 2，后续再说）
- 不做 C++ 侧车单元测试（方案 C）
- 不改变任何应用代码
- 不改变构建过程

## Decisions

### D1: 截图工具选 PowerShell CopyFromScreen

**选择**: PowerShell `CopyFromScreen`（Windows 自带，零外部依赖）。
通过 `System.Drawing.Graphics.CopyFromScreen()` 读取屏幕缓冲区，不依赖目标窗口的渲染管线，因此 Flutter GPU 渲染窗口也能正确捕获。

**替代方案**: 
- `nircmd.exe savescreenshot` — 150KB 免安装，但需手动下载外部二进制；`savescreenshot` 同样截全屏
- `flutter screenshot` — 仅支持移动设备，桌面端不支持
- Windows GDI `PrintWindow` — 向目标窗口发送 WM_PRINT 消息，Flutter GPU 渲染窗口无法响应，返回黑屏
- Rust/Go 写的 DXGI capture 小工具 — 更可控但需要编译工具链

### D2: 脚本用 bash（Git Bash）

**选择**: 项目已用 bash 作为 shell，所有现有脚本均为 sh。保持一致性。
**备选**: PowerShell — 用户环境有，但现有 checkpoint 脚本都是 `dart run`，bash 够用。

### D3: 目录结构

```
test/smoke/
├── run_all.sh           ← 统一入口，串所有步骤
├── utils.sh             ← 公共函数 (launch_app, kill_app, capture_screenshot)
├── 01_build.sh          ← flutter build windows --debug
├── 02_analyze.sh        ← dart analyze lib/
├── 03_checkpoints.sh    ← 跑所有 checkpoint_X_verify.dart
├── 04_launch_and_verify.sh ← 启动 app + 截图 + 日志检查 + DB 检查
├── references/          ← 参考截图 (baseline)
│   ├── empty_state.png
│   ├── auto_title.png
│   └── tool_card.png
└── output/              ← 本次 run 输出 (gitignore)
    ├── screenshot_01.png
    └── run.log
```

### D4: 验证流水线设计

```
Step 1: Build       → flutter build windows --debug
Step 2: Analyze     → dart analyze lib/
Step 3: Checkpoints → 串行跑所有 checkpoint_X_verify.dart
Step 4: Launch      → 启动 alias_agent.exe，等待窗口出现
Step 5: Visual      → 截图 + MCP analyze 验证关键 UI 状态
Step 6: Logs        → grep sidecar.log 检查 ERROR
Step 7: DB          → sqlite3 检查 sessions/messages 表
Step 8: Cleanup     → kill 进程
```

每步 exit code ≠ 0 则标记失败，最后汇总报告。

### D5: 视觉验证策略

**方式**: capture screenshot → MCP `ui_diff_check(reference.png, actual.png)` → 报告差异。
**参考截图**: 在已知 good state 下手动截取，存入 `references/`。
**可验场景**:
- 空状态：sidebar 显示 "New Chat"，主区域显示 "No messages yet"
- Auto-title：sidebar 第一个会话标题非 "New Chat"
- Tool card：消息列表中出现工具调用卡片
- Error：错误提示气泡出现

## Risks / Trade-offs

- **[R] PowerShell 截图捕获全屏而非单窗口** → Mitigation：`CopyFromScreen` 读取屏幕缓冲区而非向窗口发消息，无法限定单窗口。对 smoke test 而言可接受——验证的是"界面上确实出现了预期内容"而非像素级窗口截图。MCP `ui_diff_check`/`extract_text_from_screenshot` 可从全屏截图中定位 UI 元素。
- **[R] 参考截图会随 UI 变更过期** → Mitigation：`references/` 是 git-tracked 文件，UI 改动时同时更新。
- **[R] GPU 缩放/DPI 差异导致截图不一致** → Mitigation：MCP `ui_diff_check` 支持语义对比而非像素级对比。固定窗口大小 1280×720。
- **[R] Flutter 启动慢，step 4 中 sleep 不可靠** → Mitigation：用 `wait_for_window` 函数轮询 `tasklist` 确认进程存活 + 窗口出现，而非固定 sleep。
