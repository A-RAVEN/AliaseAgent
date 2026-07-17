## Context

AliasAgent 现有唯一测试文件 `test/widget_test.dart` 是 Flutter 模板自带的 Counter 假测试，与实际应用完全无关。`add-smoke-tests` 提供编译/分析/启停/截图的系统级验证，但无法覆盖应用内的 UI 交互——输入文字、发送消息、切换会话、渲染 tool card / 错误气泡等核心用户路径。

Flutter 的 `flutter_test` + `WidgetTester` 能在没有真实设备的情况下，在内存中构建 Widget tree、模拟点击和输入、验证文本和 Widget 存在性。配合 `mockito` 可 mock 数据层，实现完整交互链测试。

**约束**：
- 不改动 SidecarBridge（C++ FFI），测试覆盖到 Repository 层为止
- `ChatScreen` 目前硬依赖 `SessionRepository` / `MessageRepository` 的构造函数，需轻度改造支持注入

## Goals / Non-Goals

**Goals:**
- 替换空的 counter 测试为实际 Widget 测试
- 覆盖叶子组件渲染：空状态、消息列表、tool card、错误气泡
- 覆盖交互流程：输入消息→发送→列表更新、切换会话
- 用 Mockito mock 数据层，不依赖真实 sidecar 或数据库
- 改动量控制在 ~20 行以内（ChatScreen 加两个可选参数）

**Non-Goals:**
- 不改动 SidecarBridge 或引入 Fake Sidecar（留给 tier 3）
- 不做 Flutter `integration_test`（需真实设备或桌面窗口）
- 不改变现有功能行为
- 不修改 smoke test 脚本

## Decisions

### D1: 测试工具选 flutter_test + 手写 Fake Repo

**选择**: Flutter 内置 `flutter_test` + 手写 `FakeSessionRepository` / `FakeMessageRepository`。
**原因**: `SessionRepository` 和 `MessageRepository` 是 concrete class，mockito 5.x + Dart 3.x 的 null safety 对 concrete class mock 有限制（`any` 参数类型冲突）。手写 fake 更简单，无代码生成依赖。
**替代方案**:
- `mockito` + `build_runner` — 需要 code generation，concrete class 兼容性问题
- `bloc_test` / `provider_test` — 项目未使用 Bloc/Provider 状态管理，引入成本过高

### D2: ChatScreen DI 方案

**选择**: 添加可选命名参数，默认行为不变：

```dart
class ChatScreen extends StatefulWidget {
  final AppConfig config;
  final SessionRepository? sessionRepo;   // 新增
  final MessageRepository? msgRepo;       // 新增
}
```

在 `_ChatScreenState` 中：`_sessionRepo = widget.sessionRepo ?? SessionRepository()`。

**替代方案**:
- 全局 `Provider` / `InheritedWidget` — 引入新的依赖层，改动面太大
- 保持硬编码 + 改 static 方法 — 测试时需要 mock 全局状态，更脆弱

### D3: 测试文件结构

```
test/
├── widget_test.dart          ← 替换为入口，导入各测试
└── widget/
    ├── chat_area_test.dart    ← Tier 1: 纯 UI
    ├── session_sidebar_test.dart
    ├── message_bubble_test.dart
    ├── tool_call_card_test.dart
    ├── chat_screen_test.dart  ← Tier 2: mock 交互
    └── helpers/
        └── test_utils.dart    ← 共享 test data factory
```

## Risks / Trade-offs

- **[R] Fake repo 与真实 repo 行为偏差** → Mitigation: fake 方法签名完全匹配 `implements` 接口，编译期保证契约一致
- **[R] Widget 结构变化时测试需同步更新** → Mitigation: 测试验证行为（文本/交互），不验证实现细节（内部状态）
- **[R] ChatScreen 构造函数签名变化** → 向后兼容，新增参数均为可选，默认行为不变
