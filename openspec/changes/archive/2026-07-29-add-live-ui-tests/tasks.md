## 1. 前置修改

- [x] 1.1 Add `DatabaseService.close()`: 在 `database_service.dart` 中添加 `static Future<void> close() async { await _db?.close(); _db = null; }`（D8 前提）

## 2. 测试基础设施

- [x] 2.1 Create `integration_test/real_api_test.dart`: setup with `IntegrationTestWidgetsFlutterBinding`, temp DB via `DatabaseService.openAt(tempDir)`, tearDown close + delete temp dir
- [x] 2.2 Implement `pumpUntilFound` helper: 手动 pump 循环（1s interval），默认 150s timeout（大于 SidecarBridge 的 120s）
- [x] 2.3 Implement setUp: 检查 `~/.aliasagent/config.json` 存在性（不存在 → skip all）；pump AppShell()（不注入 sidecar，让 _initSearchAndTools 自然执行）
- [x] 2.4 Implement completed-assistant finder: `find.byWidgetPredicate((w) => w is MessageBubble && w.role == 'assistant' && !w.isStreaming)`，等待流式完成后才匹配

## 3. 测试场景

- [x] 3.1 基本对话: enterText → tap Send → pumpUntilFound(completedAssistant, 150s) → 检查 "Error:" 前缀 → skip 或 assert 非空
- [x] 3.2 web_fetch 工具调用: 检查 providers 配置（未配置 → skip）→ enterText "请使用 web_fetch 工具抓取..." → pumpUntilFound(ToolCallCard) → 等待 Done → pumpUntilFound(completedAssistant) → assert 非空
- [x] 3.3 Error classification: "Error:" 前缀 → markTestSkipped（外部）；ToolCallCard Error → fail（内部）；150s 无回复 → TimeoutException fail

## 4. 验证

- [x] 4.1 Run `flutter test integration_test/real_api_test.dart` headless — 两个场景通过（或 API 不可用时全部 skip）
- [x] 4.2 Verify temp DB cleanup: 测试后无残留临时目录，用户真实 aliasagent.db 无测试数据
- [x] 4.3 Verify test isolation: 运行两次，第二次不受第一次影响
