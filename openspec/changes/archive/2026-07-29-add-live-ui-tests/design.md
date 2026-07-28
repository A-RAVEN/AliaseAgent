## Context

当前测试架构：
- **Unit/Widget tests**: FakeSidecar，离线，快速回归
- **Real sidecar tests**: 真实 DLL，FFI 级调用，无 UI
- **Smoke test**: 启动 app，验证窗口/日志/数据库，无交互

缺失：在 app 的 widget 树中，用真实 API 驱动完整对话（打字 → AI 回复 → 工具调用 → 结果展示）。

已有基础设施：
- `integration_test/` 目录存在，`screenshot_test.dart` 有 4 个 FakeSidecar 测试
- `integration_test` SDK 依赖已在 pubspec.yaml
- `ChatScreen` 支持注入 `sidecar`/`sessionRepo`/`msgRepo`
- API key 在 `~/.aliasagent/config.json`
- `DatabaseService.openAt()` 已有测试用接口

## Goals / Non-Goals

**Goals:**
- 在 widget 树中驱动真实对话：输入文本 → 发送 → 等待 AI 回复完成 → 验证回复
- 验证工具调用链路：AI 触发 web_fetch → ToolCallCard 出现 → 状态 Done → AI 引用结果
- 测试可重复运行（不依赖特定对话历史）
- 失败时提供有用的诊断信息

**Non-Goals:**
- 不验证 AI 回复的具体文本内容（非确定性）
- 不做截图比对（视觉回归已有 screenshot_test.dart）
- 不测试 on-device 模式（`-d windows`），先做 headless
- 不替换现有 mock 测试

## Decisions

### D1: 测试文件放在 `integration_test/real_api_test.dart`

与现有 `screenshot_test.dart` 并列。使用 `IntegrationTestWidgetsFlutterBinding`。

### D2: pump 完整 AppShell，不注入 sidecar

直接 pump `AppShell()`（不注入 sidecar），让它自然走完初始化流程：
- `ConfigService.load()` 从 `~/.aliasagent/config.json` 读取 API key
- `_populateRegistry()` 填充全局 `registry` 和 `resolver`
- `_initSearchAndTools()` 注册工具定义（包括 web_fetch，前提是 search providers 已配置）
- 创建 `SidecarBridge.instance`（加载真实 DLL）

**为什么不注入 sidecar**: 注入 sidecar 会跳过 `_initSearchAndTools()`，导致 web_fetch 工具不注册。pump 完整 AppShell 是唯一让工具注册正常执行的方式。

**前提**: `~/.aliasagent/config.json` 必须存在且包含有效 API key 和至少一个 search provider。如果 config 不存在，AppShell 会显示 SetupDialog 阻断测试——这属于环境配置问题，测试应在 setUp 中检查 config 存在性，不存在则 skip。

### D3: 等待策略 — 等待回复完成，不是首个字符

`_StreamingDots` 使用无限循环 `AnimationController`（1200ms），`pumpAndSettle()` 永远不会 settle。

**关键**: `ChatStreamingItem` 也渲染为 `MessageBubble(isStreaming: true)`。如果只查找"第二个 MessageBubble"，会在第一个流式字符到达时就匹配——此时回复还没完成，pipe 死锁等 bug 检测不到。

**正确做法**: 等待 `isStreaming == false` 的 assistant MessageBubble 出现。流式完成后，app 会移除 `ChatStreamingItem` 并插入最终的 `ChatMessageItem`。

```dart
// 等待已完成的 assistant 回复（非流式）
Finder completedAssistant = find.byWidgetPredicate(
  (w) => w is MessageBubble && w.role == 'assistant' && !w.isStreaming,
);
await pumpUntilFound(tester, completedAssistant, timeoutSec: 150);
```

**超时设为 150 秒**（大于 SidecarBridge 的 120s receivePort timeout），避免两层超时碰撞。

### D4: 断言策略 — 结构性断言，不断言具体文本

真实 API 每次回复不同。断言结构：
- 已完成的 assistant MessageBubble（`isStreaming == false`）存在
- 内容非空且不以 `"Error:"` 开头
- 工具调用场景：ToolCallCard 存在，状态文本为 "Done"

### D5: 测试场景

**场景 1：基本对话**
1. 检查 config 存在，不存在 → skip
2. pumpWidget(AppShell())
3. 等待 SetupDialog 不出现（config 有效时不会弹）
4. enterText(TextField, "你好，请简单介绍一下你自己")
5. tap(Send button)
6. pumpUntilFound(completedAssistant, 150s)
7. 检查内容：如果以 "Error:" 开头 → markTestSkipped；否则断言非空

**场景 2：web_fetch 工具调用**
1. 如果场景 1 被 skip → 也 skip
2. enterText(TextField, "请使用 web_fetch 工具抓取 https://example.com 的内容，告诉我页面标题")
3. tap(Send button)
4. pumpUntilFound(ToolCallCard, 150s)
5. pumpUntilFound(ToolCallCard 状态为 "Done", 60s)
6. pumpUntilFound(completedAssistant, 150s)
7. 断言：回复非空

**注意**: web_fetch 工具只在 search providers 已配置时注册（`if (hasProviders)` 门控）。config 中没有 search provider → web_fetch 不在 tools 列表 → AI 无法调用 → 场景 2 超时。setUp 应检查 providers 是否配置，未配置则 skip 场景 2。

### D6: Widget 选择器

当前无 Key，使用类型/谓词查找：
- `find.byType(TextField)` — 只有一个
- `find.byTooltip('Send')` — 发送按钮
- `find.byWidgetPredicate((w) => w is MessageBubble && w.role == 'assistant' && !w.isStreaming)` — 已完成的 assistant 回复
- `find.byType(ToolCallCard)` — 工具调用卡片

### D7: 错误分类与容错

**核心原则**: 外部不可用（API/网络）不阻断测试管线，内部 bug 必须 fail。

| 类别 | 示例 | 测试行为 |
|------|------|----------|
| 外部不可用 | API key 无效(401)、网络断(timeout)、服务器错误(500/503) | `markTestSkipped("API unavailable: ...")` |
| 内部 bug | pipe 死锁、FFI 崩溃、web_fetch 返回错误、ToolCallCard 状态 Error | `expect` 失败 → test FAIL |

**检测方式**: assistant 回复内容以 `"Error:"` 开头 → 外部不可用 → skip。

**场景间依赖**: 场景 1 skip → 场景 2 也 skip。场景 1 通过但场景 2 的 ToolCallCard 状态 Error → fail。

**测试管线隔离**: live UI 测试作为独立文件运行，全部 skip 不影响其他测试文件。

**超时**:
- pumpUntilFound: 150 秒（大于 SidecarBridge 的 120s，避免碰撞）
- 测试级 timeout: 300 秒（两个场景各 150s）
- 超时 → fail（可能是 pipe 死锁等内部 bug）

### D8: 测试数据隔离 — 临时数据库

使用 `DatabaseService.openAt(tempDir)` 将测试数据库重定向到系统临时目录。

**前提**: `DatabaseService` 当前没有 `close()` 方法。需要先添加：
```dart
static Future<void> close() async {
  await _db?.close();
  _db = null;
}
```

```dart
setUp(() async {
  tempDir = Directory.systemTemp.createTempSync('aliasagent_test_');
  await DatabaseService.openAt(tempDir.path);
});

tearDown(() async {
  await DatabaseService.close();  // 必须先关闭连接，否则 Windows 文件锁
  if (tempDir.existsSync()) tempDir.deleteSync(recursive: true);
});
```

### D9: 全局状态管理

`registry`（`AgentTypeRegistry`）和 `resolver`（`ProviderResolver?`）是 `main.dart` 中的顶层全局变量，无 reset 方法。

**方案**: pump 完整 AppShell 时，`_populateRegistry()` 会自然填充这两个全局变量。不需要手动 reset——每个 testWidgets 块 pump 新的 AppShell 即可覆盖。但需要在 tearDown 中将 `resolver` 设为 null 防止跨测试泄漏。

## Risks / Trade-offs

- [API 费用] 每次运行消耗真实 API token → 可接受，live test 不需要高频运行
- [非确定性] AI 可能不触发 web_fetch → 用明确的指令性 prompt（"请使用 web_fetch 工具"）降低风险
- [web_fetch 门控] web_fetch 只在 hasProviders 时注册 → setUp 检查 providers 配置，未配置则 skip 场景 2
- [网络依赖] 无网络时测试 skip → 不阻塞离线测试
- [运行时间] 真实 API 调用 + 工具执行约 10-30 秒/场景 → 可接受
- [全局状态] `registry`/`resolver` 是全局变量 → AppShell 自然填充，tearDown 清理
- [DatabaseService.close()] 需要新增 → 作为实现任务
