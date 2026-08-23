## 1. app 侧:isFinalReply 标记 + 公开 State + 只读 getter(标识/暴露,不改对话行为)

- [x] 1.1 `lib/models/chat_item.dart`:`ChatMessageItem` 加 `final bool isFinalReply`(默认 false)。
- [x] 1.2 `lib/main.dart`:`_ChatScreenState` 改名公开 `ChatScreenState`;加只读 getter `String? get finalAssistantReply`(返回 `_chatItems` 中**最后一个** `isFinalReply == true && content.trim().isNotEmpty` 的 `message.content`,无则 null;取最末= 定位本轮最终回复,避免多轮会话旧轮回复掩盖本轮)。
- [x] 1.3 `lib/main.dart`:存**最终回复**(无工具调用分支,~:910-920)传 `isFinalReply: true`;存**中间轮文本**(~:946)保持 false(默认);**`_storeError`(~:1448-1462 存 "Error: <msg>")同样传 `isFinalReply: true`**(外部失败的 Error 回复也是该轮最终消息,须暴露给测试判 skip)。
  - 测试侧**无需**给 `ChatScreen`/`AppShell` 穿 `GlobalKey`——测试已 pump 全树,用 `tester.state<ChatScreenState>(find.byType(ChatScreen))` 直接读 State(避免过度工程)。

## 2. 测试侧:状态读最终回复(替代脆弱 widget 扫描)

- [x] 2.1 `integration_test/live_observability.dart`:新增 `String? readFinalAssistantReply(WidgetTester tester)`(经 `tester.state<ChatScreenState>(find.byType(ChatScreen))` 读 `state.finalAssistantReply`,替代 `completedAssistant`/`latestAssistantText` 的一次性 widget finder);**不引入 pump+scroll widget 扫描**。
- [x] 2.2 `integration_test/real_api_test.dart`(3.1-3.4)与 `integration_test/live_file_tools_test.dart`(t1-t4):把"是否已回复""取回复文本"改读 `readFinalAssistantReply`,并按前缀分类:以 "Error:" 开头 → `markTestSkipped`(外部失败);非空非 Error: → 正常继续;null → 诚实 fail(spec「User sends message...SHALL be detected」+「API key invalid...markTestSkipped」)。

## 3. silent-completion 判定更新(spec D4)

- [x] 3.1 `pumpUntilReplyOrTurnDone` 及"空回复 fail"分支:按状态 `finalAssistantReply` 判定——非 null 且非空 → 正常继续;null → 判 silent-completion,`fail`(空回复/内部异常)+ 出 [OBS] 证据 dump。**streaming 停后可先等一个有限宽限期(如 500ms,沿用现 real_api_test.dart:74 的 grace period;错误路径 `_endStreaming` 先于 `_storeError` 插入,空档期 getter 仍为 null)——宽限期后再判 null → silent-completion,避免外部错误被误判为内部 fail。** 修复 3.3 假 fail(app 已存已渲染,仅 naive widget finder 漏检),且区分最终回复与中间文本(isFinalReply)。

## 4. 验证

- [x] 4.1 `flutter analyze` 通过(`lib/models/chat_item.dart`、`lib/main.dart`、`integration_test/*` 4 个文件)——本 change 涉及的 5 个文件无新增 issue(项目既有的 150 处,w 含 main.dart:1307 `nsCount` 预存 warning,非本 change 引入)。
- [x] 4.2 重跑 `flutter test --tags live --run-skipped integration_test/real_api_test.dart -d windows`:确认 3.3(及此前同因假 fail 的用例)不再因"气泡未 build"假 fail;其余通过路径不回归。—— `+4: All tests passed!`;3.3 由状态读命中(模型回 "✅ 修改成功！"),文件 edit 验证通过。
- [x] 4.3 重跑 `integration_test/live_file_tools_test.dart -d windows`:t1-t4 不回归。—— `+4: All tests passed!`;Test 3 countA DONE/countB preserved + Test 4 glob_file 返回两路径,均有 [OBS] 文件 dump。
- [x] 4.4 用 Read 读至少一张通过/失败截图,确认视觉验收(渲染)未受影响。—— Read `test/live_visual/3.3_edit_file.png`(58KB):完整渲染 Assistant 回复气泡("✅ 修改成功！我已使用 edit_file 工具将 _aliasagent_live_test.txt 中的 "line two" 替换为 "LINE TWO MODIFIED"...")+ Done 的 edit_file/read_file 卡片;渲染未受影响。

## 5. 诚实性审查

- [x] 5.1 开 Workflow 对抗验证:确认状态读**真实生效**(实测 3.3 由 `finalAssistantReply` 命中)、`isFinalReply` 正确标记(最终= true / 中间文本 = false)、getter 真正取"最后_一个_ isFinalReply"(多轮会话不误取旧轮)、"错误路径 streaming 停后 getter 暂时为 null 的宽限期处理"存在、无对话/存储/渲染行为改动、无"空最终回复"被旧轮回复或中间文本掩盖、Error: 前缀(含内部 `_storeError`)仍走 skip 的既有行为被**如实记录**(不宣称修复)、spec 未被弱化、无越界(不碰 C++/不新增依赖)。—— 12 怀疑者 4 主张全部多数通过(A1-A4 各 1 refute<2);唯一 refuting lens 是 evidence-honesty,因 3.3_edit_file.png 被后续 live_file_tools 的 clearLiveVisualDir 删除而判"证据缺"——属预期 stale-cleanup,非缺陷(测试 exit 0 + "All tests passed!" + bff7m253z output 显示该截图 58KB 已捕获,已 Read 确认渲染)。其余 code-fidelity/honesty-not-weakening lens 全部无可确证。另修 1 处 rename 后遗留注释(live_file_tools_test.dart:18 `_ChatScreenState`→`ChatScreenState`,纯注释零影响)。
