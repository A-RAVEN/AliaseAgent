## 1. 基础设施

- [x] 1.1 创建 `test/widget/` 目录结构，删除 `test/widget_test.dart`（counter 模板测试）
- [x] 1.2 创建 `test/widget/helpers/test_utils.dart`：共享 test data factory（创建测试用的 Session、Message、ToolCallActivity 实例）
- [x] 1.3 创建 `test/widget/helpers/fakes.dart`：手写 `FakeSessionRepository` / `FakeMessageRepository`（mockito 对 concrete class 兼容性问题，改为手写 fake）

## 2. Tier 1 — 叶子 Widget 纯 UI 测试

- [x] 2.1 `test/widget/session_sidebar_test.dart`：空列表渲染、"New Chat" 按钮存在、多 session 渲染、当前 session 高亮
- [x] 2.2 `test/widget/chat_area_test.dart`：空消息列表 + "Type a message..." 占位、user/assistant 消息渲染、streaming 状态、空消息防发送
- [x] 2.3 `test/widget/tool_call_card_test.dart`：tool card 渲染 tool name + input、status states (executing/done/error)

## 3. Tier 2 — Fake repo 交互流程测试

- [x] 3.1 `lib/main.dart`：`ChatScreen` 新增可选参数 `sessionRepo` / `msgRepo`，默认行为不变
- ~~3.2 `flutter pub run build_runner build` 生成 mock 类~~ → 改用 `test/widget/helpers/fakes.dart`（手写 fake repo，无需 code generation）
- [x] 3.3 `test/widget/chat_screen_test.dart`：fake repo 注入 → 渲染 ChatScreen → 测试 session 列表加载、DI 构造函数验证

### 4. Checkpoint: 验收

| # | 验收项 | 通过标准 |
|---|--------|----------|
| A | 测试可运行 | `flutter test test/widget/` 全部通过 |
| B | Tier 1 覆盖 | sidebar/chat/tool card 三个叶子组件每种状态至少一个 test case |
| C | Tier 2 覆盖 | ChatScreen 交互测试 mock 注入成功，至少 3 个 scenario |
| D | 无副作用 | 生产代码改动仅限 ChatScreen 构造函数签名（默认行为不变） |
