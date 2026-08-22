## Context

`integration_test/real_api_test.dart` 3.3 偶发失败。两种失败模式：

1. **模型空回复**（08-18 两次全量跑，间接证据）：DeepSeek 在 thinking 模式（`thinking_effort=max` + `thinking.display="summarized"`）下偶发返回仅 thinking 块、无 text 的最终回复。应用侧 `_callModel` 最终回合路径（lib/main.dart L905-926）的 `turnText.isNotEmpty` 守卫（07-22 归档 change `fix-tool-call-card-display` 为防 tool_use-only 空气泡而设）在 `turnText` 为空时跳过建气泡 → 回合"正常完成"（`isStreaming=false`）但 UI 无回复 → 测试 `completedAssistant` 等待 150s 超时，fail 信息 `possible pipe deadlock` 与实际原因不符。**未获 TRACE 直接复现**（08-22 三次 TRACE 跑未抓到；08-18 证据为：HTTP 200 正常完成、无 120s 超时打印、无气泡）。

2. **dump 滚动回归**（08-22 TRACE 实测确认）：`live_observability.dart` 的 `_scanToolCards`（`dumpToolCards`/`dumpNoTool` 共用）收集卡片时**无条件向上滚动聊天列表最多 12×400px**（不像 `_scanErrorCardsWithScroll` 找到即停），把最新的 assistant 气泡滚出视口被 ListView.builder 回收。调用点之后读取 `latestAssistantText`（3.1/3.2/3.3/3.4 断言前 dump 均在读取前）→ 返回 null → `expect(text, isNotNull)` 失败（08-22 实测 real_api line 321）。会话越长越易触发（3.3 卡片多先踩中）。**3 轮对抗审查未抓到**（只验 dump 就位、未验滚动副作用）。

**apply 前对抗审查（16 agents，10 findings 全部确认）揭示的关键约束**：
- 「流式开始前」窗口存在：`_sendMessage`（main.dart L584-611）在 `setState(_isStreaming=true)`（L610）之前有异步 DB 前奏（`_newChat`/insert/touch），此时 `isStreaming==false` + 无气泡，与"空回合完成"不可区分 → helper 必须**先观察到流式已开始**才可判"回合完成"。
- 「静默完成」不可区分空回复与内部异常：`_callModel` 的 catch（main.dart L625-635）对**任何异常**调 `_endStreaming()`（isStreaming=false）且**不建气泡、不写 Error**（DB insert 失败 / sendMessage 崩溃 / max-turns abort 均如此）。测试视角两者不可区分 → **统一 skip 会掩盖内部 bug**，违反 spec「Internal bugs SHALL fail」→ 采用**诚实归因策略：静默完成 → fail**。
- Error 路径竞态：API 错误时 `_endStreaming()`（同步置 false）先于 `_storeError`（异步插 Error 气泡）→ 判静默完成前需**宽限重检**气泡。

**工作区透明性（round-1 审查 finding 1）**：本 apply 叠加在未提交 sibling change `add-live-test-observability` 之上——该 change 创建了 `live_observability.dart`（未跟踪）并修改了 `real_api_test.dart`、`live_file_tools_test.dart`、`DEBUGGING.md`、`CLAUDE.md`，两个 change 共享 `real_api_test.dart` 与 `live_observability.dart`。因此工作区为混合未提交状态，仅凭 `git diff` 无法隔离本 change 的改动归属，归属需读 change artifacts；本 change 自身的任务范围（无 lib/、无 C++、断言不弱化）在文件层面已由 round-1 审查核实。

## Goals / Non-Goals

**Goals:**
- 测试侧：把 3.3 的失败从"误导性 deadlock"改为**诚实、可归因的失败**（区分挂起/静默完成/正常），且不误判流式前窗口
- 测试侧：3.3 指令硬化，降低空回复触发频率
- 修复 dump 滚动回归（08-22 实测抓到的真 bug）
- spec：修正 `live-ui-tests`「Test timeout」语义混淆

**Non-Goals:**
- **不改任何生产代码**（`lib/` 不动）——GUI 零改动；模型空回复时维持现状"工具卡片后无 AI 回复"（与 tool_use-only 静默回合一致，非 bug）
- **不加应用侧占位气泡**（用户确认：`（无文本回复）` 气泡观感像 bug，砍掉）
- **不让"静默完成"变成 skip**（用户选定方案①：fail + 诚实归因；因测试视角无法区分模型空回复与内部异常，skip 会掩盖内部 bug）
- 不改 C++ sidecar；不改 tool_use-only 中间回合守卫（L944）与 reload 路径
- 不弱化既有断言（4 个测试的"必须有气泡/非空回复"断言原样保留，静默完成仍 fail）（审查 finding F：断言不弱化）

## Decisions

### D1: 测试侧轮询等待 + 诚实归因分类（不依赖应用改动）

每个 `completedAssistant` 等待（3.1/3.2/3.3/3.4）替换为轮询 helper（定义在 real_api_test.dart，复用其 `completedAssistant` finder）：

```dart
/// Pump until the conversation resolves:
///  (a) a completed assistant bubble appears (normal or Error reply), OR
///  (b) the turn completes (streaming was observed true, then false) with no
///      bubble — "silent completion" (empty reply OR internal exception), OR
///  (c) 150s elapse while streaming never stopped (genuine hang).
/// Throws TimeoutException only for (c).
Future<void> pumpUntilReplyOrTurnDone(WidgetTester tester,
    {int timeoutSec = 150}) async {
  final end = DateTime.now().add(Duration(seconds: timeoutSec));
  var sawStreaming = false;
  while (DateTime.now().isBefore(end)) {
    await tester.pump(const Duration(seconds: 1));
    final areas = tester.widgetList<ChatArea>(find.byType(ChatArea));
    final stillStreaming = areas.isNotEmpty && areas.last.isStreaming;
    if (stillStreaming) sawStreaming = true;
    if (completedAssistant.evaluate().isNotEmpty) return;   // (a) normal / Error
    if (sawStreaming && !stillStreaming) {
      // (b) streaming stopped: grace period so a pending Error:/empty bubble
      // renders (the error path _endStreaming runs before _storeError's bubble).
      await tester.pump(const Duration(milliseconds: 500));
      if (completedAssistant.evaluate().isNotEmpty) return; // (a) error bubble arrived
      return;                                               // (b) silent completion
    }
    // !sawStreaming && !stillStreaming: still in the pre-stream DB preamble — poll on.
  }
  throw TimeoutException('Conversation still streaming after ${timeoutSec}s'); // (c)
}
```

调用点分类：

```dart
try {
  await pumpUntilReplyOrTurnDone(tester, timeoutSec: 150);
} on TimeoutException {
  await dumpToolCards(tester, phase: '3.x reply timeout');
  fail('Conversation still streaming after 150s — possible pipe deadlock or FFI crash');
}
if (completedAssistant.evaluate().isEmpty) {
  // 静默完成：模型空回复 或 内部异常（测试视角不可区分）→ fail 诚实归因。
  await dumpToolCards(tester, phase: '3.x silent completion');
  fail('Conversation completed without an assistant reply — model empty reply '
      'or internal exception (see [OBS] dump and sidecar log)');
}
final text = latestAssistantText(tester);          // 正常路径
expect(text, isNotNull);
if (text!.startsWith('Error:')) { /* 既有 API 错误 skip 逻辑保留 */ }
```

**关键设计点：**
- **流式守卫（审查 finding A）**：`sawStreaming` 确保只在流式确实开始过后才接受"回合完成"判定，消除 3.1 首个等待（Send 后无中间工具卡）在 DB 前奏窗口的 false-skip。
- **静默完成 → fail（审查 finding B，用户选方案①）**：因无法区分模型空回复与内部异常，统一 skip 会掩盖内部 bug（违反 spec「Internal bugs SHALL fail」），故 fail 并附 `[OBS]` dump + sidecar 日志证据供人工归因。诚实、不隐藏。
- **Error 宽限重检（审查 finding C）**：`isStreaming` 变 false 后 pump 500ms 再查气泡，避免把 API 错误误判为静默完成（`_endStreaming` 先于 Error 气泡插入）。
- **3.3 文件清理（审查 finding D）**：静默完成分支与 hang 分支在 fail 前删除 `_aliasagent_live_test.txt`（home 目录文件不在 tearDown 清理范围），匹配既有 ToolCallCard-timeout 分支的清理。

**替代方案**：静默完成 → skip → 拒绝（掩盖内部 bug，审查 finding B）；只等气泡不轮询 → 拒绝（静默完成要干等 150s 且无法区分）；应用侧占位气泡 → 拒绝（GUI 观感像 bug，用户确认砍掉）。

### D2: 3.3 指令硬化（降低空回复触发频率）

3.3 的指令「改完告诉我结果」偏软——对比 3.1「请用一句话介绍你自己」、3.4「逐步推导每一步」，3.3 是唯一一个没有强制要求"最终自然语言输出"的用例。改为显式要求:

```
请使用 edit_file 工具修改 _aliasagent_live_test.txt，把 "line two" 改成 "LINE TWO MODIFIED"。
修改完成后，必须用中文自然语言回复我：修改是否成功，以及修改后的文件内容。
```

**定位**：**缓解措施**（降低模型空回复概率），不替代 D1——模型仍可能无视指令，D1 的诚实归因是兜底。live_file_tools_test 的指令已含「When done, report which files you edited」等强制报告语，暂不动。

### D3: 修复 dump 滚动回归（08-22 实测确认）+ 防御 + 跨套件文档

**回归**：`_scanToolCards` 收集卡片时无条件向上滚动最多 12×400px，把最新 assistant 气泡回收出视口；其后 `latestAssistantText` 返回 null → `expect(text, isNotNull)` 失败（real_api line 321 实测）。

**修复**：`_scanToolCards` 在收集循环结束后**恢复视口到底部**。

**恢复机制（apply 5.1 实测修正，2026-08-22）**：**不能用反向 drag**。首版实现（相同次数反向 drag `Offset(0, -400)` 滚回）在 Test 1 内正常，但**破坏整个套件**：Test 2/3/4 全部 `did not complete [E]`（同时失败 = app 侧测试绑定被弃置），而基线（无恢复、仅收集 drag）4/4 通过。根因：对已钳制在 maxScrollExtent 的 ListView 做**手势驱动的反向 drag**，手势结束后残留 ballistic 滚动动画/弹簧回弹，存活到下一个 `testWidgets`，其 binding 被这些挂起动画破坏 → 全部剩余测试被弃置。**改用 `ScrollController.jumpTo(maxScrollExtent)`**（经 `tester.widget<ListView>(chatList).controller` 拿到 ChatArea 的 `_scrollCtrl`）：jumpTo 同步、无手势、无 ballistic、天然钳制，**零跨测试残留**。恢复为 best-effort（`controller != null && hasClients` + try/catch，teardown 中 controller 已 detach 时静默跳过）。收集循环保持 drag（基线证明收集 drag 安全，不加改动）。

**恢复循环防御（审查 finding E，随 jumpTo 修正）**：jumpTo 路径同样防御——`chatList.evaluate().isEmpty` 时跳过；controller null/detach/异常时 try/catch 静默放弃；不抛异常挂掉 dump 所在的测试。

**跨套件副作用（审查 finding G，需文档化）**：`live_file_tools_test` 也消费 `dumpToolCards`（L290/304/311/...）并在其 Error: skip 分支读 `latestAssistantText`（L291/380/485/504/617）。当前 bug 下这些分支是**死的**（latestAssistantText 返回 null → Error 检测失败 → 硬失败）；D3 修复后它们**复活**（Error: 回复 → 正确 skip）。这是 add-live-test-observability 的预期修复（其 design D2 声称 dump"不改变 expect/fail/markTestSkipped 行为"在 Error: skip 分支上被修正为真正生效），观测性保留（fail→skip 可归因）。

**替代方案**：各测试先捕获 `latestAssistantText` 再 dump → 拒绝，需改 4+ 调用点且失败路径 handler 也要改，易漏；helper 内恢复更稳健、一处生效。

### D4: spec 语义更新（`live-ui-tests` delta）（审查 finding F：spec 自洽性 + 断言不弱化）

- 修改「Test timeout」场景：`WHEN no completed assistant MessageBubble appears within 150 seconds AND (the conversation is still streaming (ChatArea.isStreaming == true) OR streaming was never observed during the wait)` 才 `THEN fail with TimeoutException`（内部 bug / 管道死锁 / DB 前奏挂起）。第二子句覆盖"从未观察到流式"的情形（`_sendMessage` 在 `_isStreaming=true` 前有异步 DB 前奏，若挂起则全程 isStreaming==false），与 D1 的 `TimeoutException` 行为对齐。
- 新增「Silent completion」场景：`WHEN the conversation stops streaming (ChatArea.isStreaming == false) without a completed assistant MessageBubble`（可能模型空回复或内部异常）→ 测试 SHALL `fail` 并附可归因信息（`[OBS]` dump），**不 skip**（因测试视角无法区分外部模型空回复与内部异常，skip 会掩盖内部 bug，保留「Internal bugs SHALL fail」）。GUI 无需渲染占位符。

## Risks / Trade-offs

- [静默完成仍算测试失败（模型空回复罕见时也失败）] → 这是用户选定的方案①：归因准确、不掩盖内部 bug，优先于"空回复不挡套件"；`[OBS]` dump + sidecar 日志使失败可人工归因
- [轮询 helper 匹配中间 assistant 气泡（工具回合有文本时）] → 与既有 `completedAssistant` 行为一致（本来就匹配中间气泡），非新问题；静默完成检测仅在"全程无气泡"时生效
- [流式守卫的宽限重检（500ms）仍可能错过极慢的 Error 气泡] → Error 气泡插入是 DB insert（~ms 级），500ms 足够；即便错过，静默完成的 fail 信息与 dump 仍可归因
- [D3 恢复（jumpTo 到 maxScrollExtent）在极端长会话下仍有上限（maxScrollExtent 即底）] → jumpTo 天然钳制到底部；最新气泡进入视口即可；jumpTo 同步无动画，无跨测试残留（首版反向 drag 的失败模式已消除）
- [指令硬化（D2）是概率性缓解，模型仍可能空回复] → 不依赖指令保证；D1 诚实归因是兜底

## Migration Plan

1. `integration_test/live_observability.dart`：D3 修复——`_scanToolCards` 收集后经 `tester.widget<ListView>(chatList).controller` 拿 ScrollController，`jumpTo(maxScrollExtent)` 恢复视口到底部（同步无手势、无 ballistic、零跨测试残留；首版反向 drag 方案实测破坏整个套件已弃用），恢复为 best-effort：`chatList.evaluate().isEmpty`/controller null/`hasClients` 检查 + try/catch
2. `integration_test/real_api_test.dart`：加 `ChatArea` import + `pumpUntilReplyOrTurnDone` helper（流式守卫 + 宽限重检）+ 4 个等待替换 + 分类逻辑（静默完成 → fail 诚实归因）+ 3.3 文件清理（D1）
3. `integration_test/real_api_test.dart`：3.3 指令硬化（D2）
4. `openspec/specs/live-ui-tests/spec.md` delta：改「Test timeout」+ 新增「Silent completion」（D4）
5. `flutter analyze` 通过
6. 运行验证：live_file_tools_test + real_api_test（真实模型），确认 3.3 失败可诚实归因（挂起/静默完成/正常三分）、D3 后 `latestAssistantText` 在 dump 后不再返回 null、live_file_tools Error: skip 分支恢复生效
7. 诚实性审查（Workflow 对抗验证）

## Open Questions

无（探索阶段收敛：用户确认砍掉应用侧占位气泡、选方案①静默完成 → fail 诚实归因；空回复根因仍为间接证据，但 D1 对空回复/挂起/内部异常三种状态均诚实归因，不依赖该假设成立）。
