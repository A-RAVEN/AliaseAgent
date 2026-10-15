## MODIFIED Requirements

### Requirement: Level-2 roll-up is threshold-only and accumulates across folds

The system SHALL decide a level-2 "summary of summaries" roll-up by ONE token threshold and nothing else — the same uniform rule and the same `T` as the level-1 fold, applied one level up: starting from the OLDEST, accumulate the MEASURED token counts of the level-1 summaries that are not yet covered by a level-2, and roll that group up into a single level-2 as soon as the accumulated total exceeds `T` (= the model context window × the configured percentage — the same derived threshold, no second constant). **Reaching the threshold SHALL be sufficient: the roll-up SHALL NOT wait for the budget, and SHALL NOT depend on whether the current projection still fits — the trigger SHALL be independent of the budget.** The system SHALL NOT gate the roll-up on any count of segments. The level-2's content SHALL be the SMALLER of its two sides: if the produced level-2's measured token count is LESS than the summed measured tokens of the level-1 summaries it replaces, its content is the produced text; otherwise its content SHALL BE those level-1 summaries' own text concatenated in order — a roll-up SHALL NOT cause content to be dropped from the projection, and SHALL NOT delete data. Persisted level-1 summaries SHALL remain eligible roll-up inputs on later turns — they SHALL NOT be frozen out of the level-2 input set — so that the accumulated total can actually reach the threshold; their stored text SHALL be reused, never regenerated. A level-2 summary SHALL never be an input to another level-2 (exactly two levels).

#### Scenario: Accumulated level-1 tokens exceed the threshold

- **WHEN** the level-1 summaries not yet covered by a level-2 have measured tokens whose accumulated total first exceeds `T` (oldest-first)
- **THEN** that oldest group is rolled up into ONE level-2 summary, and the projection is re-measured after the roll-up

#### Scenario: The threshold is enough on its own

- **WHEN** the accumulated level-1 measured tokens exceed `T` while the conversation is still within budget (the projection would fit without any roll-up)
- **THEN** the roll-up still happens — reaching the threshold is sufficient, and the roll-up does not wait for the budget

#### Scenario: Level-2 actually reaches the request projection

- **WHEN** such a roll-up happens and its whole covered span has reached the farthest band
- **THEN** the request projection actually sent to the model contains the level-2 summary (the level-2 marker), and a `level = 2` row exists in `summary_nodes` whose covered span is the union of the rolled-up level-1 spans; the middle band's own level-1 summaries are projected for their own span, each span exactly once

#### Scenario: Rolled-up level-1s are not duplicated

- **WHEN** a level-2 covers a span and is projected
- **THEN** the level-1 summaries inside that span are not also sent as separate projection entries — every span is projected with exactly one representation

#### Scenario: A roll-up never removes a middle-band level-1 from the projection

- **WHEN** a roll-up runs while some level-1 summaries still lie in the middle band (distance `T`–`2T`)
- **THEN** the roll-up proceeds on the token rule as before, and those middle-band level-1 summaries are still projected (their distance, not the level-2's coverage, decides their representation)

#### Scenario: Accumulation spans folds

- **WHEN** a level-1 summary was persisted by an earlier fold, the accumulated total has not yet exceeded `T`, and a later fold runs
- **THEN** that earlier level-1 summary is still an eligible roll-up input (reused, not re-summarized, not frozen out), so the total can reach the threshold across turns

#### Scenario: Below the threshold nothing rolls up

- **WHEN** the accumulated measured tokens of the candidate level-1 summaries never exceed `T`
- **THEN** no level-2 is produced (the threshold, not a count, is what authorizes a roll-up); if the projection still does not fit the budget, the OLDEST level-2 summaries SHALL be left out of the request projection, one at a time (projection only — no data is ever deleted), and level-1 summaries and raw content SHALL NOT be left out; if even that does not fit, the projection SHALL be sent over budget

#### Scenario: No count gate blocks a single large level-1

- **WHEN** a single level-1 summary alone already exceeds `T`
- **THEN** the roll-up is attempted on the token rule alone (no "at least two" gate blocks it), and its content is whichever side has fewer tokens — the produced level-2 when that is smaller, otherwise that level-1 summary's own text

#### Scenario: Level-2 is never rolled up again

- **WHEN** a level-2 summary exists
- **THEN** it is never an input to another level-2 summary; level-2 summaries are the ONLY entries that may be left out of the request projection, oldest first, and only when the projection exceeds the budget (projection only — the data is never deleted); if leaving all of them out still does not fit, the projection is sent over budget

### Requirement: Send-time wait gate

Whether a user turn WAITS for compaction before its request goes out SHALL be decided by ONE quantity: the share of the model's context window that the request would occupy **if it were sent now** — the estimated total of what would actually be projected (raw messages kept verbatim + level-1 summaries projected + level-2 summaries projected, each summary counted at its persisted measured token cost), divided by `maxContextTokens`. The turn SHALL wait only when that share EXCEEDS a configurable wait percentage (`compaction_wait_threshold_percent`, per agent type, default `75`); the bound SHALL be derived as `maxContextTokens × W / 100` — never an absolute token constant, never a count of messages or summaries. The gate SHALL be evaluated from the deterministic local estimator BEFORE any summarization call, so deciding costs no model call.

When the share is at or BELOW the bound, the request SHALL be sent without waiting for compaction: no summarization request SHALL be issued for that turn, the projection SHALL use only summaries already persisted (content not yet summarized SHALL be projected as raw text), and folding SHALL be left to the background folding lifecycle.

When the share EXCEEDS the bound, the turn SHALL wait for the fold to finish before its request goes out, and the compaction status indicator SHALL be shown while it waits (see the chat-ui capability).

The gate SHALL NOT change WHEN content is folded (crossing `T` still folds it, and the fold still happens on the background lifecycle) and SHALL NOT change the budget bound: if the request still exceeds the wait bound after folding and roll-up, the turn SHALL NOT be blocked waiting for a bound it cannot reach — the existing oldest-first omission of level-2 summaries (data kept on disk) and the existing "summarization failed, send verbatim" fallback SHALL apply.

**Relationship to the existing trigger rules (stated explicitly, because this gate defers work rather than skipping it):** the threshold rules are unchanged — crossing `T` still folds level-1 batches, and accumulated level-1 measured tokens above `T` still roll up to level 2, exactly as "Level-2 roll-up is threshold-only and accumulates across folds" requires. What changes is only WHEN that work runs: a turn below the wait bound does not run it, so the work moves to the background folding lifecycle (which starts ~2s after the turn ends and yields to the user's next send). Consequence, stated honestly: if the user keeps sending without ever going idle, folding and roll-up are deferred until the projection crosses the wait bound — that turn then waits and folds a larger batch. This deferral is the intended behaviour change requested on 2026-10-02; it SHALL NOT be read as the threshold rules waiting for the budget.

#### Scenario: Below the wait bound sends without waiting and without any summarization call

- **WHEN** the accumulated raw total exceeds `T`, but the projection at send time stays at or below `W%` of the model's context window
- **THEN** the request is sent without waiting; no summarization request is issued for that turn; the projection carries only already-persisted summaries, with content not yet summarized sent as raw text

#### Scenario: Above the wait bound the turn waits

- **WHEN** the projection at send time exceeds `W%` of the model's context window
- **THEN** the turn waits for the fold to finish before its request goes out, and the compaction status indicator is shown while it waits

#### Scenario: The wait bound scales with the window

- **WHEN** the same history is sent with the same configured percentages against a model whose context window is twice as large
- **THEN** the wait bound is twice as large (derived, not hard-coded)

#### Scenario: Wait percentage is configurable, with a default

- **WHEN** `compaction_wait_threshold_percent` is absent from the agent config
- **THEN** the default percentage (75) applies; when present, that percentage applies instead — no other value in the mechanism changes

#### Scenario: Invalid wait percentage falls back to the default

- **WHEN** `compaction_wait_threshold_percent` is set to `0`, a negative number, a value above `100`, a fractional number, or a string
- **THEN** it is treated as absent (the default 75 applies) and the app logs one line saying so — the same rule the batch-threshold percentage already follows

#### Scenario: No indefinite wait

- **WHEN** the request still exceeds `maxContextTokens` after folding and roll-up
- **THEN** the OLDEST level-2 summaries are left out of this request's projection, one at a time — they are the oldest content at its coarsest representation, so this IS the existing "oldest-first omission" (data kept on disk, exactly as the budget rule already requires); level-1 summaries and raw content SHALL NOT be left out, and a summarization failure falls back to sending verbatim — the turn is never blocked waiting for a bound it cannot reach. Exceeding the WAIT bound alone SHALL NOT cause any content to be left out: the wait bound decides only whether the turn waits, and it is always below `maxContextTokens`

#### Scenario: The gate never issues a summary call to decide

- **WHEN** a turn's projection share is computed
- **THEN** it is computed from the deterministic local estimator without any model call, so deciding whether to wait costs nothing

## ADDED Requirements

### Requirement: 压缩取值：取小者，绝不因压不短而丢内容

一级与二级 SHALL 用同一条取值规则：把「压缩前」和「压缩后」的 token 数比一下，取**较小**的那一侧作为**下一级**的内容。原文⇒一级比较「那一批原文的估算 token（仓库既有估算器）」与「模型给的一级摘要的实测 token」；一级⇒二级比较「那几条一级的实测 token 之和」与「模型给的二级摘要的实测 token」。

两边 token 数**相等**时 SHALL 取压缩前那一侧 —— 压缩既然一点没变小，就没有理由引入一条摘要。（用户原话只说了"取较小的那一个"、没提相等；这一条是本变更自行定的口径，实现上写成严格小于 `afterTokens < beforeTokens`。）

压缩 SHALL NOT 因为"结果不比压缩前短"而从投影里丢掉任何内容，SHALL NOT 因此删除任何数据。原来那条"折半重试、切到原子就把那一条丢掉"的路径 SHALL 被删除。

当**压缩前**一侧胜出时：

- 原文⇒一级：这一级的内容就是那段原文；发出去时 SHALL 走原文渲染路径（保留 tool_use / tool_result / 思考块），SHALL NOT 把它拼成一段纯文本当摘要发出 —— `Compressed output is plain text` 要求摘要不带这些块，文本化等于把它们换成一段文字。
- 一级⇒二级：这一级的正文 SHALL 是那几条一级的文本按原顺序拼接。

超容量时 SHALL **只**把最旧的二级摘要从这次请求里拿掉（一次一条、每拿一条重新量一次总量），一级摘要与原文 SHALL NOT 被拿掉。这一步只影响这次请求：原文与摘要 SHALL NOT 从库里删除（`Original conversation retained on disk (immutable)`）。把所有二级摘要都拿掉之后仍然装不下，投影 SHALL 超预算发出去，并在日志里写明超了多少 token。

这一条与既有规范里那两处「最旧的内容会被从投影里拿掉」的措辞是对齐的、不是推翻它们：被拿掉的正是**最旧的那一层**（二级摘要代表的就是最旧的内容）。本要求只把可拿掉的范围从"一级摘要与这一趟新产出的段"收紧成"二级摘要"。

#### Scenario: 一级压不短时按原文发、不丢

- **WHEN** 某一批原文的摘要实测 token 不比这批原文的估算 token 少
- **THEN** 这一级的内容 SHALL 是这批原文本身，投影里 SHALL 出现这批原文（工具块与思考块完整），SHALL NOT 出现那条更长的摘要，SHALL NOT 有任何内容被丢掉

#### Scenario: 二级压不短时取那几条一级

- **WHEN** 二级摘要的实测 token 不比它要替换的那几条一级之和少
- **THEN** 这一级的正文 SHALL 是那几条一级文本的拼接，SHALL NOT 有任何内容被丢掉

#### Scenario: 压缩后更短时按今天的行为走

- **WHEN** 压缩后的实测 token 比压缩前少
- **THEN** 取压缩后的摘要（那一侧胜出），投影里出现的是模型写的那条摘要，SHALL NOT 出现压缩前的那一段

#### Scenario: 超容量时从最旧的二级摘要开始拿掉

- **WHEN** 投影超出模型容量，而这一趟还有二级摘要
- **THEN** SHALL 从最旧的那条二级摘要开始把它们从这次请求里拿掉，一次一条、每拿一条重新量一次总量；原文与一级摘要 SHALL NOT 被拿掉

#### Scenario: 一级摘要与原文不许丢

- **WHEN** 投影超出模型容量，而这一趟只剩一级摘要与原文
- **THEN** 它们一条 SHALL NOT 被拿掉

#### Scenario: 拿掉二级只是这次不发

- **WHEN** 一条二级摘要因为超容量没有被发出去
- **THEN** `summary_nodes` 里那一行 SHALL 原样还在，它盖住的原文 SHALL 原样还在 `messages` 表里，SHALL NOT 删除任何数据

#### Scenario: 丢光二级还不够就超预算发

- **WHEN** 所有二级摘要都已经不发了，投影仍然超出容量
- **THEN** 投影 SHALL 超预算发出去，日志里 SHALL 写明超了多少 token

#### Scenario: 投影里没有洞

- **WHEN** 一趟压缩里既有"取小者"选到原文的段，也有正常摘要的段
- **THEN** 历史里每一段内容 SHALL 仍恰好有一种表示，SHALL NOT 出现谁也不管的空档

#### Scenario: 两级用的是同一条规则

- **WHEN** 分别核对"原文⇒一级"与"一级⇒二级"两处取值
- **THEN** 两处的判据 SHALL 都是"取较小的一侧"，SHALL NOT 存在只对其中一级生效的特殊分支
