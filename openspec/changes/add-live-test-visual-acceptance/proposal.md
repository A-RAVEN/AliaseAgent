## Why

Live 测试（`integration_test/real_api_test.dart`、`integration_test/live_file_tools_test.dart`）用**真实模型 + 真实桌面包**（`-d windows`）驱动完整应用，但断言只校验文本/状态，**从不留存界面画面**——真实模型渲染出的回答气泡、工具卡、思考卡的实际视觉效果，审查者无从看见。现有两条视觉路线都覆盖不到这个洞：`visual-assertions` 用 PowerShell `CopyFromScreen` 截的是**独立 exe** 的全屏黑盒；`visual-regression` 用 `RepaintBoundary.toImage()` 但配 **FakeSidecar 假事件**（无真实模型输出，看不到真实回答/真实工具结果）。同时主循环（Claude）拥有**原生视觉**（`Read` 工具直读 PNG，不依赖任何 MCP 图像分析工具），恰好能对 live 测试的截图做**判断式视觉效果验收**。主循环自身本就不依赖 MCP 图像工具，原生读图可用且免去 MCP 分析工具的依赖/质量不确定性——这一选择基于**主循环自身能力**，而非 MCP 禁令（该禁令约束的是 Workflow agent，不是做验收的主循环，见批判性自审 #10）。

## What Changes

- **测试侧（每用例结尾截图）**：在 8 个 live 用例（`real_api_test` 的 3.1/3.2/3.3/3.4 + `live_file_tools_test` 的 Test 1–4）结尾，用 **`RepaintBoundary.toImage()`** 把**Flutter 场景**渲染截为 PNG（非 OS 窗口像素，无标题栏/边框，见语义澄清）。方法：调用点**测试侧**包裹 `RepaintBoundary(key: ...)` 于 `MyApp`（**无任何 lib/ 生产代码改动**），复用现有 `test/integration/helpers/screenshot_utils.dart` 的 `captureWidgetAsPng(key, path)`。输出到**独立目录** `test/live_visual/`（按用例命名如 `3.1_basic.png`），不撞 `test/smoke/`（那是 FakeSidecar 的像素回归基线）。**返工要求**：截图须在**fail 路径也执行**（try/finally 或 pre-fail capture），并带**非空白/尺寸校验 + 失败删 stale 文件**守卫（见 design D3 返工 #1/#2）。
- **验收侧（主循环原生视觉读图）**：测试套件跑完后，主循环用 `Read` 工具逐张读 PNG，做**判断式视觉效果验收**：回答气泡正确渲染？工具卡状态=done、能看到工具名+结果预览？思考卡渲染？布局正常（左会话边栏+右聊天）？无溢出/裁切/黑块？**返工要求**：验收锚定**结构线索 + 量化阈值**（如非流式气泡 ≥ N 字符、空白占比 < 阈值），不比对真实模型的非确定文本（见 design D4 返工 #4）。
- **Spike 优先（本 change 第一阶段，硬门槛）**：先在**单个用例（3.1）**上验证 `RepaintBoundary.toImage()` 在**真实 live 窗口**能稳定出**真图**（非黑/空白帧）。Spike 通过 → **停下向用户报告、用户确认"继续"后**才铺满其余 7 个用例（非自动继续，见 design D2 返工 #11）；Spike 失败 → 按 design 的决策点切换到 PowerShell `CopyFromScreen`（方案 C）。**禁止**在 spike 未过前假设 `toImage` 可行而一次铺满全部用例。
- **明确边界（诚实范围）**：本 change 做的是**视觉验收**（judgment-based，人/主循环判断"看着对不对"），**不是**视觉回归（deterministic hash/pixel 比对——后者已由现有 `integration_test/screenshot_test.dart` + `visual-regression` spec 承担，本 change 不重复）。

## Capabilities

### New Capabilities
- `live-test-visual-acceptance`: 定义 live 窗口测试在用例结尾捕获真实窗口渲染截图（`RepaintBoundary.toImage`，测试侧包裹，无生产改动），并由主循环用原生视觉（`Read` 工具直读 PNG，非 MCP）做判断式视觉效果验收的规范；含 spike 优先门槛（先单用例验证 `toImage` 在真实 live 窗口出真图，再铺满其余用例）。

### Modified Capabilities
<!-- 无——本 change 不改变既有 visual-assertions / visual-regression 的需求；live 测试截图与主循环原生验收是一条新增能力，不与既有像素回归合并。 -->

## Impact

- `integration_test/real_api_test.dart`、`integration_test/live_file_tools_test.dart` — 调用点测试侧包 `RepaintBoundary` + 每用例调 `captureWidgetAsPng`（**成功与 fail 路径都执行**——try/finally 或 pre-fail capture，见 design D3 返工 #1；spike 阶段仅 `real_api_test` 3.1 一处）。**不再是"每用例结尾"**（易被误读为只在通过路径，与 fail-path 要求矛盾，round-2 一致性审查订正）。
- `test/integration/helpers/screenshot_utils.dart` — 复用 `captureWidgetAsPng`；可能新增 live 专用封装（命名/目录/时机封装）。
- `test/live_visual/` — 新输出目录（追加 `.gitignore`，截图不入库）。
- `integration_test/screenshot_test.dart`、`test/smoke/` — **不改**（既有 FakeSidecar 像素回归保持原样）。
- **不碰生产代码**（`lib/` 不动）；**不碰 C++ sidecar**；无新依赖。
- **主循环原生视觉读图验收，不依赖 MCP**（与 CLAUDE.md「Workflow agent 禁网络/MCP」约束兼容——主循环读图不受限）。
