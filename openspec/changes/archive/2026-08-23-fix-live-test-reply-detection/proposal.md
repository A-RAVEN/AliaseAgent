## Why

Live UI 测试用 `completedAssistant`/`latestAssistantText`——对 widget 树的一次性 `find.byWidgetPredicate((w) => w is MessageBubble && w.role=='assistant' && !w.isStreaming)` 扫描。它只在 `MessageBubble` 已被 `ListView.builder`(chat_area.dart:93-116)建出时命中;若回复气泡尚未 build / 已回收 / 在视口外,finder 返回空 → 测试误判"无回复"。

`real_api_test` 3.3 实录(2026-08-23,`-d windows` + `ALIASAGENT_LOG_LEVEL=trace`):模型返回完整正确答复(`stop_reason=end_turn`),app **已存储**(`main.dart:906 turnText.isNotEmpty` → `_msgRepo.insert`)且**已渲染**(截图 `3.3_edit_file.png` 清晰显示完整 Assistant 答复气泡),但测试报 silent-completion 假 fail——因为检查那一刻该气泡还没被列表 build 出来。

根因:**测试把回复检测绑定在 widget 渲染上**。**不是**模型空回复、**不是** app 未存储/未渲染(二者都已证实正常)。正确做法是**读 app 状态**(存了就是回复),而非渲染 widget。

## What Changes

- **测试改读 app 状态**:app 暴露只读的**最终回复** `finalAssistantReply`(仅标记最终回复 `isFinalReply`,区分于中间工具轮文本),测试经 `tester.state<ChatScreenState>(find.byType(ChatScreen))` 读它。**零 widget 扫描、零 pump+scroll、零渲染依赖**——app 存了就是最终回复,天然鲁棒(修复 3.3 假 fail)。
- **最小 app 侧改动(标识 + 暴露,不改对话/存储/渲染行为)**:
  1. `ChatMessageItem` 加 `bool isFinalReply`(默认 false);`main.dart` 存**最终回复**(无工具调用分支)置 true,存中间轮文本置 false。区分最终回复与中间文本——二者是同型消息,纯测试侧无法区分,这是**唯一可靠信号**。
  2. `main.dart` 的 `_storeError`(存 "Error: <msg>" 回复)也置 `isFinalReply: true`,使外部失败(无效 key/网络)的 Error 回复暴露给测试,测试据 "Error:" 前缀判 **skip**(与原测试一致)。
  3. `_ChatScreenState` 改公开 `ChatScreenState`,加只读 getter `String? get finalAssistantReply`(**返回最后一个** `isFinalReply==true && content.trim().isNotEmpty` 的 `message.content`,无则 null;取最末= 定位本轮最终回复,避免多轮会话旧轮回复掩盖本轮)。测试经 `tester.state` 读它,**无需 GlobalKey 穿过 AppShell/MyApp**。
- `completedAssistant`/`latestAssistantText` 及基于它们的所有断言、silent-completion 判定改用**读 `finalAssistantReply`(状态)**并按前缀分类:"Error:" → skip;非空非 Error: → 正常;null → 诚实 fail。**错误路径上 streaming 停可能先于 Error 项插入,故判定"空回复"前须保留宽限期**(见 design D4)。
- 渲染产物仍由**截图/视觉验收**(change add-live-test-visual-acceptance)承担 observability;它读渲染,正确性由状态判定,两者分离。
- `live-ui-tests` spec 的回复检测 + silent-completion + Error 分类场景改为"app 暴露最终回复,测试从状态读并分类"。

## Capabilities

### New Capabilities
- 无。

### Modified Capabilities
- `live-ui-tests`:回复检测从"一次性 widget 扫描(渲染依赖)"改为"读 app 暴露的最终回复状态(finalAssistantReply)"。silent-completion 场景改为"状态无最终回复→诚实 fail";Error 分类场景改为"状态最终回复以 Error: 开头→skip"。不弱化诚实-fail(真空回复/内部异常:状态无最终回复→仍 fail);不削弱外部失败→skip。

## Impact

- 测试侧:`integration_test/live_observability.dart`(改/加状态读 `readFinalAssistantReply`)、`integration_test/real_api_test.dart`、`integration_test/live_file_tools_test.dart`(判定改走状态读)。
- app 侧(标识/暴露):`lib/models/chat_item.dart` 加 `isFinalReply`;`lib/main.dart` 三个插入点(最终回复 true、中间文本 false、`_storeError` Error 回复 true)+ 公开 `ChatScreenState` + getter `finalAssistantReply`。
- **不涉及** C++ sidecar、新依赖、对话/存储/渲染行为改变。

## 诚实边界

- app 已正确存储+渲染(实证)。本 change 只改"测试如何判定回复",不改 app 行为。
- **error 分类(内部 vs 外部)**:`_storeError` 对 `doneCode != 0`(可能含内部 sidecar 错误)也打 "Error:"。当前设计把 "Error:" → skip,与**原测试一致**(原测试同样对所有 "Error:" skip)。区分"内部错误应 fail vs 外部错误应 skip"是**既有**问题,不属本 change(需单独的 app 侧错误分类改动)。本 change **不引入、不恶化**该既有行为,但也不宣称修复它。
- **honest-fail 关闭范围(不夸大)**:本 change 关闭的 honest-fail **仅限空最终回复**(streaming 停且 getter null)与**中间文本掩盖**(isFinalReply=false 不冒充最终)——这两点在本 change 的 live 测试下成立(单 turn)。**"Error:" 前缀(含经 `_storeError` 的_内部_错误)仍走 skip**,属既有行为,本 change **不宣称修复**。spec 的 "Internal bug detected" 场景据此补充了诚实说明(见 spec).
