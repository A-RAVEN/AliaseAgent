## Context

live 测试判断"模型是否回复"用一次性 widget 扫描:
```dart
Finder get completedAssistant => find.byWidgetPredicate(
    (w) => w is MessageBubble && w.role == 'assistant' && !w.isStreaming);
String? latestAssistantText(WidgetTester tester) =>
    tester.widgetList<MessageBubble>(completedAssistant).lastOrNull?.content;
```
这只在 `MessageBubble` 已被 `ListView.builder`(chat_area.dart:93-116,懒建)建出时命中。已实证(real_api 3.3,2026-08-23,trace + 截图):
- 模型返回完整答复(`stop_reason=end_turn`),app 存了(`main.dart:906` insert 于 `_endStreaming():924` 前)且渲染了(`3.3_edit_file.png` 可见完整 Assistant 气泡)。
- 测试仍假 fail:naive finder 在检查那一刻未命中(气泡没被列表 build / off-viewport / 回收)。

根因是**检测绑定渲染**,不是模型、不是 app 存储/渲染。修法:**读 app 状态**(存了就是回复),而非渲染 widget。

## Goals / Non-Goals

**Goals:**
- live 测试的回复判定改为**读 app 状态**——app 暴露只读的最终回复 `finalAssistantReply`(仅标记 `isFinalReply`),测试经 `tester.state<ChatScreenState>(find.byType(ChatScreen))` 读它。零渲染依赖、零 widget 扫描。
- `completedAssistant`/`latestAssistantText` 及 silent-completion 判定改用状态读;按前缀分类(Error: → skip;非空非 Error: → 正常;null → fail)。

**Non-Goals:**
- 不改 app 对话/存储/渲染行为;仅加**标识位** `isFinalReply` + 只读 getter(observability/标识性)。
- 不改变 C++ sidecar、模型、工具执行。
- 不做视觉回归/像素比对。

## Decisions

### D1: 根因 = 检测绑定渲染,修法 = 读状态

app 可靠地存储 + 渲染回复(截图证明)。错在测试一次性 `find` 未命中尚未 build 的 bubble。修法:不再扫 widget,而是读 app 已存的消息状态(app 存了就是回复)。

### D2: 读 app 状态(最小 lib 标识 + 暴露)—— 用户选 B

候选(A = 库状态 getter + 公开 State;B = 读 tempDir 消息 DB;C = 测试侧鲁棒 widget 扫描)。**弃 C**(widget 扫描 pump+scroll 仍脆弱,且无法区分「最终回复」与「中间轮文本」——中间文本气泡被 `.add` 到尾部,可在空最终回复时成终止项);**弃 B**(脆)。采用 A:

- **app 改动(标识 + 暴露,不改对话/存储/渲染行为)**:
  1. `ChatMessageItem` 加 `bool isFinalReply`(默认 false);`main.dart` 存**最终回复**(无工具调用分支,~:910-920)传 `isFinalReply: true`,存中间轮文本(~:946)保持 false。区分最终回复与**中间文本**——二者是同型消息(role=assistant、非流式、content 非空),纯测试侧无法区分,这是**唯一可靠信号**。
  2. `main.dart` 的 `_storeError`(~:1448-1462 存 "Error: <msg>" 回复)也传 `isFinalReply: true`——外部失败(无效 key/网络)的 Error 回复也是该轮最终消息,暴露给测试据 "Error:" 前缀判 skip。
  3. `_ChatScreenState` 改公开 `ChatScreenState`,加只读 getter `String? get finalAssistantReply`(从 `_chatItems` **末位**向前扫,返回**最后一个** `isFinalReply == true && content.trim().isNotEmpty` 的 `message.content`,无则 null)。**为何取最末**:`_chatItems` 是会话内按时间追加的列表(main.dart:158),一轮 turn 内中间文本(isFinalReply==false)先追加、最终回复(isFinalReply==true)后追加,取最末即真正的"本轮最终回复";多轮会话时可能并存多个 isFinalReply(历轮最终回复 + 本轮最终回复/Error),取最末=本轮,避免旧轮返回掩盖本轮的**空回复**或 **Error**。**边界**:`isFinalReply` 不持久化,仅 live 内存 `_chatItems` 标记;DB 重载(main.dart:~520 `ChatMessageItem(msg)` 默认 false)时 getter 返回 null——live 测试用全新临时库读 live list 不受影响,该 null 属可接受边界。**测试经 `tester.state<ChatScreenState>(find.byType(ChatScreen))` 读该 State**——测试已 pump 全树,无需 GlobalKey 穿过 AppShell/MyApp(避免过度工程)。
- **测试判定**(读 `state.finalAssistantReply`):以 "Error:" 开头 → `markTestSkipped`(外部失败);非空非 Error: → 正常继续;null → 诚实 `fail`(空回复/内部异常)+ 出 [OBS] dump。**无 widget 扫描、无 pump+scroll、零渲染依赖**。
- `live_observability.dart` 提供 `String? readFinalAssistantReply(WidgetTester)`(经 `tester.state<ChatScreenState>(find.byType(ChatScreen))` 读 getter)。

### D3: 渲染 / 验收 与 正确性 分离

- 正确性(是否回复):状态读(D2)。
- 视觉验收:截图 + 主循环读图(change add-live-test-visual-acceptance)看渲染产物。二者分离。

### D4: silent-completion / Error 分类判定

- **正常(模型回答了,含中间轮有/无文本)**:`finalAssistantReply` 非 null 且非空(且非 "Error:")→ 正常继续。
- **外部失败(无效 key/网络)**:`finalAssistantReply` 以 "Error:" 开头 → `markTestSkipped`。
- **空最终回复**:`finalAssistantReply` 为 null → `fail`(空回复)+ 出 [OBS] dump。
- **错误路径顺序竞态**:错误路径上 `_endStreaming()`(置 `_isStreaming=false`,main.dart:850)先于 `await _storeError(...)`(:856,且 `_storeError` 内有 async `_msgRepo.insert` 空隙 :1449)。因此 isStreaming 首次读到 false 的瞬间,`finalAssistantReply` 仍可能为 null(Error 项尚未插入)。**streaming 停后判 "getter null → silent-completion" 前必须先等一个有限宽限期(如 500ms,沿用现 real_api_test.dart:74 的 grace period)**——否则外部错误会被误判为内部 fail 而非 skip(D4 改进,写进 tasks 3.1)。
- **中间轮文本**:`isFinalReply == false`,不混入 `finalAssistantReply`。
- **honest-fail 的关闭范围(诚实边界)**:本 change 的 honest-fail 关闭**仅限**空最终回复(streaming 停且 getter null)与**中间文本掩盖**(isFinalReply=false 不冒充最终)——这两点在本 change 的 live 测试下成立(每个 testWidgets 都 pump 全新单 turn app)。**"Error:" 前缀的回复(含经 `_storeError` 的_内部_错误:doneCode!=0 含 sidecar 崩 :856、No agent type :649、Provider not found :656)仍走 skip**(原测试同)——这是**既有**行为,本 change **不引入、不恶化、也不宣称修复**。D4 不把 `finalAssistantReply` 当作"区分内部/外部错误"的工具(见 Risks / Open Question 1)。

## Risks / Trade-offs

- [`isFinalReply` 需与 app 存最终回复处同步] → 三个插入点:最终回复 true、中间文本 false、`_storeError` Error 回复 true;写进 tasks 验证;若未来插入点改变需同步。
- [error 分类内部 vs 外部] → `_storeError` 对 `doneCode != 0`(可能含内部 sidecar 错误)也打 "Error:",本文按 "Error:" → skip(与**原测试一致**);区分内部应 fail vs 外部应 skip 是**既有**问题,out-of-scope(需单独改动)。本 change 不引入、不恶化,**也不宣称修复**(其 honest-fail 仅限空最终回复与中间文本掩盖,见 D4)。
- [getter 须取"最后_m_个 isFinalReply"] → 多轮会话时 `_chatItems` 可能并存多个 isFinalReply;须取末位匹配(=本轮最终回复),否则旧轮回复会掩盖本轮空回复/Error。写进 tasks 1.2 验证。跨多轮的边界面(multi-send 单实例旧轮掩盖)→ live 测试均单 turn,不触发,可接受。
- [错误路径顺序竞态] → streaming 停时 Error 项可能尚未插入,getter 短暂为 null;判定须保留宽限期(500ms),否则外部错误误判为内部 fail。写进 tasks 3.1 验证。
- [状态与渲染不一致] → 以状态为准是设计意图;若真出现"状态有最终回复但 UI 不渲染",是独立 app bug,截图视觉验收会暴露,应另报。

## Migration Plan

1. `lib/models/chat_item.dart`:`ChatMessageItem` 加 `final bool isFinalReply`(默认 false)。
2. `lib/main.dart`:`_ChatScreenState` 改名公开 `ChatScreenState`;加只读 getter `String? get finalAssistantReply`(**取最后一个** `isFinalReply==true && content.trim().isNotEmpty` 的 `message.content`,无则 null);三个插入点赋 `isFinalReply`(最终回复 true ~:910-920、中间文本 false ~:946、`_storeError` Error 回复 true ~:1448-1462)。
3. `live_observability.dart`:新增 `String? readFinalAssistantReply(WidgetTester)`(经 `tester.state<ChatScreenState>(find.byType(ChatScreen))` 读 getter)。**不引入 pump+scroll widget 扫描**。
4. `real_api_test.dart` / `live_file_tools_test.dart`:把"是否已回复""取回复文本"改读 `readFinalAssistantReply`;`pumpUntilReplyOrTurnDone` 空回复分支按 D4(读状态判 fail / Error:判 skip),**并保留 streaming 停后的宽限期**(等 pending Error 插入,避免外部错误被误判为内部 fail)。
5. 重跑 `flutter test --tags live ... real_api_test.dart -d windows`:3.3 不再假 fail;其余通过路径不回归。
6. `flutter analyze` 通过。

## Open Questions

1. **error 分类(内部 vs 外部)**:是否应同时修 `_storeError` 区分"内部 sidecar 错误(应 fail)"与"外部错误(应 skip)"?—— 属**既有**问题,本 change 不处理;若用户要求,可另开 change。
