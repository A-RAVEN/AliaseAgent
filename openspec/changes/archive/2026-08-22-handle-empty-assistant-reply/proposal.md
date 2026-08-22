## Why

`integration_test/real_api_test.dart` 3.3 偶发失败。两种失败模式：
1. **模型空回复**（08-18 两次全量跑，间接证据）：DeepSeek 在 thinking 模式下偶发返回仅 thinking 块、无 text 的最终回复 → 应用侧 `turnText.isNotEmpty` 守卫（main.dart:906）跳过建气泡 → 测试 `completedAssistant` 等待 150s 超时，误报为内部 bug（"possible pipe deadlock"）。
2. **dump 滚动回归**（08-22 TRACE 实测确认）：`live_observability.dart` 的 `_scanToolCards` 收集卡片时无条件向上滚动 12×400px，把最新 assistant 气泡回收出视口 → 其后 `latestAssistantText` 返回 null → `expect(text, isNotNull)` 失败（real_api line 321）。

spec `live-ui-tests`「Test timeout」场景把"150s 无 completed 气泡"一律定义为内部 bug（spec.md:42-44），**混淆了「模型空回复」（外部/模型行为）与「应用挂起」（内部 bug）**。

**对抗审查（apply 前 Workflow，16 agents，10 findings 全部确认）发现设计缺陷**：若仅凭"回合完成但无气泡"判空回复并 skip，会 (a) 在流式开始前的 DB 前奏窗口误判（false-skip 未调用模型的测试）；(b) 把内部异常（`_callModel` catch 对任何异常调 `_endStreaming` 且不建气泡）静默跳过，违反"Internal bugs SHALL fail"。故采用**诚实归因策略：静默完成（空回复或内部异常不可区分）→ fail 并附可归因信息**。

## What Changes

- **测试侧（`real_api_test.dart`）**：4 个 `completedAssistant` 等待（3.1/3.2/3.3/3.4）替换为轮询 helper `pumpUntilReplyOrTurnDone`：
  - **流式已开始守卫**：必须观察到 `ChatArea.isStreaming==true` 至少一次，才接受"回合完成"判定（消除流式前 DB 前奏窗口的 false-skip）；
  - **分类**：有气泡 → 正常路径；回合完成但无气泡（**静默完成**，模型空回复与内部异常不可区分）→ **`fail` 诚实归因**（信息：可能模型空回复或内部异常，附 `[OBS]` dump）；150s 仍在流式 → `fail` TimeoutException（真挂起）；
  - **Error 宽限重检**：`isStreaming` 变 false 后先 pump 短暂宽限再查气泡（Error 路径 `_endStreaming` 先于 `_storeError` 插气泡，避免把 API 错误误判为静默完成）；
  - **3.3 清理**：静默完成分支与 hang 分支删除 `_aliasagent_live_test.txt`（home 目录文件不在 tearDown 清理范围）。
- **指令硬化（缓解，设计 D2）**：3.3 指令改为显式要求「修改完成后，必须用中文自然语言回复我：修改是否成功，以及修改后的文件内容」——降低模型空回复触发频率（概率性缓解）。
- **修复 dump 滚动回归（设计 D3，08-22 实测确认）**：`live_observability.dart` 的 `_scanToolCards` 收集后恢复视口到底部（dump 非破坏性）。**恢复用 `ScrollController.jumpTo(maxScrollExtent)` 而非反向 drag**——apply 5.1 实测首版反向 drag 在 Test 1 内正常但破坏整个套件（Test 2/3/4 全部 `did not complete [E]`，基线 4/4 通过；残留 ballistic 动画跨测试存活），jumpTo 同步无手势无残留。防御：空 finder/controller 缺失时 best-effort 跳过。副作用（预期、需文档化）：使 `live_file_tools_test` 的 Error: skip 分支从死恢复活（此前被滚动 bug 废掉，硬失败→现在正确 skip）。
- **spec**：`live-ui-tests`「Error classification and resilience」更新——「Test timeout」场景区分"仍在流式（fail 死锁）"与"静默完成（fail 诚实归因）"，新增「Silent completion」场景说明该路径因不可区分空回复/内部异常而 **fail 而非 skip**（保留 "Internal bugs SHALL fail"）。

## Capabilities

### New Capabilities

（无）

### Modified Capabilities

- `live-ui-tests`: 「Error classification and resilience」需求的「Test timeout」场景语义更新——"150s 无 completed 气泡"不再一律视为死锁：仍在流式 → fail TimeoutException（挂起）；回合已完成但无气泡（静默完成）→ fail 诚实归因（模型空回复或内部异常，附证据）。新增「Silent completion」场景：静默完成 SHALL fail（不 skip），因测试视角无法区分外部模型空回复与内部异常，skip 会掩盖内部 bug。

## Impact

- `integration_test/live_observability.dart` — 修复 `_scanToolCards` 滚动回归（收集后恢复视口 + 防御）。
- `integration_test/real_api_test.dart` — 加 `ChatArea` import + `pumpUntilReplyOrTurnDone` helper + 4 个等待替换与分类逻辑 + 3.3 文件清理；3.3 指令硬化。
- `openspec/specs/live-ui-tests/spec.md` — 「Test timeout」场景语义更新 + 新增「Silent completion」场景（delta spec）。
- `openspec/changes/handle-empty-assistant-reply/` — 全套 artifacts。
- **不改任何生产代码**（`lib/` 不动）；**不改 C++ sidecar**；GUI 零改动。
- **断言不弱化（诚实范围）**：4 个测试的"必须有 completed 气泡/非空回复"断言原样保留（静默完成仍 fail）；D3 修复使 `live_file_tools_test` 的 Error: skip 分支恢复生效（该套件特定路径 fail→skip，属预期修复、已文档化）。
