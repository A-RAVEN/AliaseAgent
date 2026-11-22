## MODIFIED Requirements

### Requirement: Stable message ordering (seq)
Every message SHALL be assigned a monotonic `seq` at insert; the compaction tree SHALL key its spans by (session_id, member_id, start_seq, end_seq) and never by the non-sortable UUID id. `member_id` SHALL be empty (NULL) for a single-agent session — that session keys its spans by (session_id, start_seq, end_seq) exactly as before — and SHALL name the owning member when the session is a group session whose summaries are produced per member's projected view (see `agent-group-chat`).

#### Scenario: seq monotonic under same-millisecond inserts
- **WHEN** multiple messages are inserted in the same millisecond (tool loop)
- **THEN** each receives a strictly increasing seq

#### Scenario: Tree spans use seq
- **WHEN** a summary node records its coverage
- **THEN** it uses (start_seq, end_seq), not message UUIDs

#### Scenario: A group member's summary node carries its member scope
- **WHEN** a summary node is persisted for a group member's projected view
- **THEN** the row records that member's id alongside (start_seq, end_seq), and a lookup for one member never returns another member's node for the same span

#### Scenario: A single-agent session keeps the old key
- **WHEN** a summary node is persisted for a single-agent session
- **THEN** its member scope is empty and the existing (session_id, start_seq, end_seq) lookup path is unchanged

### Requirement: Summarizer reference context is bounded and kept apart from the text being summarized
A level-1 summarization request on the folding path SHALL carry a **reference context** assembled from **already-persisted summaries only**, at most **two** of them: the most recent level-1 summary available for older history, and the highest-level summary available for older history (typically a level-2 summary, but not necessarily). A summary SHALL be eligible only when its whole covered span ends strictly before the oldest message of the batch being summarized — a summary whose covered span overlaps that batch SHALL NOT be carried. Each carried summary SHALL be accompanied by the sequence range it covers, and the same span SHALL NOT be carried twice: when the finer summary's covered span lies wholly inside the coarser one's, only the coarser one is carried. The reference context SHALL NEVER grow with session length: it is a fixed count of summaries, never "all earlier summaries". When no eligible summary exists — the very first fold, or a session whose summary store is not open — the request SHALL be exactly what it is today: the folded messages, today's system text, and the existing summarize instruction, with nothing added and no extra headers.

**Member scope (group sessions).** For a group session the candidate set SHALL be limited to summaries persisted in the **summarizing member's own scope** (that member's `member_id`): the candidate query, the eligibility filter and the reference selection SHALL all be member-scoped. A summary belonging to another member SHALL NEVER be carried as reference context, even when its covered span would otherwise be eligible — the reference block is an input to that member's model and therefore follows the same privacy boundary as the member's projected view. For a single-agent session the scope is empty and the behavior is exactly as before.

The reference context and the text to be summarized SHALL be carried as **separate messages**, each with an explicit header naming which one it is ("reference context — do not summarize" versus "text to be summarized — summarize only this"). **When and only when** a reference context is carried, the system text SHALL keep today's two sentences (faithful and concise; same language as the transcript) **and** additionally state that the reference is there only to resolve references and to judge what has already been said, and SHALL forbid restating it inside the summary. The level-2 roll-up chain SHALL be unchanged: neither the level-1 summaries it merges nor the sub-span level-1 calls that produce them SHALL carry a reference context.

There SHALL be no text-similarity gate: a produced summary SHALL NOT be rejected, retried or rewritten because its wording resembles the reference context. This constrains similarity gates only — the existing structural rule that no span may be represented twice in the projection stays exactly as it is.

#### Scenario: The first fold carries no reference context
- **WHEN** the oldest batch is folded and no eligible earlier summary exists
- **THEN** the request carries only the folded messages plus today's system text and the existing summarize instruction — no reference block, no extra header, no behavior change from today

#### Scenario: A later fold carries the reference and the text as separate messages
- **WHEN** a batch is folded while eligible earlier summaries exist
- **THEN** the request carries the reference block and the text-to-be-summarized block as separate messages with their own headers, each carried summary accompanied by the sequence range it covers, and the system text keeps today's two sentences and adds the prohibition against restating the reference

#### Scenario: The reference context stays bounded no matter how long the session gets
- **WHEN** the session holds many more than two eligible earlier summaries
- **THEN** the request carries at most two of them (the most recent level-1 summary and the highest-level summary), never the whole summary history

#### Scenario: Only summaries that end before the batch are eligible
- **WHEN** a summary's covered span overlaps the batch being summarized (for example a level-2 produced later in the same pass)
- **THEN** it is not carried as reference context

#### Scenario: The same span is never carried twice
- **WHEN** the coarser summary's covered span wholly contains the finer summary's covered span
- **THEN** only the coarser one is carried, so those messages are never represented by two different texts in the same request

#### Scenario: The summary store being unavailable changes nothing
- **WHEN** a fold runs with the summary store not open, or with no persisted summary that ends before the batch
- **THEN** the request is identical to today's, with no reference block and today's system text

#### Scenario: A summary that echoes the reference is still accepted
- **WHEN** the model returns a summary whose wording repeats part of the reference context
- **THEN** that summary is accepted and persisted as it is — never retried, rejected or rewritten on account of its wording

#### Scenario: The level-2 roll-up chain input is unchanged
- **WHEN** level-1 summaries are rolled up into a level-2 summary, or the sub-span level-1 calls that feed that roll-up run
- **THEN** those requests still carry exactly the content they carry today, with no reference block added

#### Scenario: A group member's reference context is member-scoped
- **WHEN** member B folds a batch while member A has persisted summaries whose spans end before that batch
- **THEN** none of A's summaries is carried in B's reference context; only B's own persisted summaries are eligible

#### Scenario: Single-agent sessions keep today's reference behavior
- **WHEN** a single-agent session folds a batch with eligible earlier summaries
- **THEN** the reference block is assembled exactly as before (member scope empty changes nothing)

## ADDED Requirements

### Requirement: 压缩输入是各成员自己的投影视图

组会话的压缩对象 SHALL 是**每个成员自己的投影视图**（该成员看到的那份序列，见 `agent-group-chat` 的视图投影规则），SHALL NOT 是共享原文，也 SHALL NOT 是任何一份服务全组的共享摘要。摘要请求的输入整体（被折叠文本 + 参考上下文块）SHALL 只含该成员视图内的内容。

本要求只换输入与存储作用域，既有压缩规则 SHALL 原样适用于该视图：阈值仍只有 `CompactionEngine.thresholdTokens(maxContextTokens, percent)` 这一个计算点，`maxContextTokens` 取**该成员实例自己的**生效窗口；`T` 仍只由 token 派生，SHALL NOT 因视图而新增任何条数、轮次或层级门槛；档位边界仍由同一个 `T` 派生（`CompactionEngine.substitutesSpan` / `bandFloorTokens` 的 1T / 2T 规则不变）；确定性、工具轮原子性、近区超长 tool_result 裁剪、二级汇总、"取小者"等既有要求一条不推翻。

摘要区域 SHALL 锚定**原始 `seq`**（视图剔除中间行时不漂移），投影时 SHALL 按成员把被摘要覆盖区域内的可见项替换成该成员的摘要文本，每个 span 仍恰好一种表示。摘要节点 SHALL 按 (session_id, member_id, start_seq, end_seq) 作用域存储：同一段原文在两个成员的视图里可以各有一条摘要，两条互不覆盖。

摘要请求的系统文本 SHALL 追加"保留归属"纪律（他人的发言在摘要里仍是「Y 说」，不得改写成第一人称）；该纪律 SHALL NOT 包含面向公开回复的"自包含 + 文件指针"要求（摘要私有，跨成员不读）。

单 agent 会话的压缩输入 SHALL 保持今天的"会话原始行序列"，`member_id` 为空，行为不变。

#### Scenario: 同一段原文、两个视图、两套折叠结构

- **WHEN** 同一段组原文分别由两个窗口不同的成员视图压缩
- **THEN** 两份折叠结构由各自的 `T` 与各自的视图内容决定，互不影响；两个成员各拿到自己的摘要

#### Scenario: 阈值逐成员窗口派生

- **WHEN** 成员「甲」的模型窗口是 1M、成员「乙」的是 200k，两者用同一个配置百分比
- **THEN** 两者的 `T` 按各自窗口实时算出且成比例（不是一个共享阈值，也不是写死的数）

#### Scenario: 同一 span 两条摘要互不覆盖

- **WHEN** 「甲」「乙」的视图各自折叠了同一段原文
- **THEN** `summary_nodes` 里该 span 有两行、`member_id` 不同，写入其中一条不会删掉另一条

#### Scenario: 摘要锚定原始 seq

- **WHEN** 视图剔除了中间若干条他人私有行之后做压缩
- **THEN** 摘要节点记录的仍是原始 seq 区间，投影替换的是该区间内的可见项，不会把别的成员的行算进覆盖范围

#### Scenario: 摘要输入只含该成员视图

- **WHEN** 成员「乙」的视图触发一次折叠
- **THEN** 摘要请求实际收到的被折叠文本与参考块都只含乙视图里的内容（甲的私有行与甲的摘要都不在其中）

#### Scenario: 摘要请求带归属纪律

- **WHEN** 成员视图触发一次摘要
- **THEN** 摘要请求的系统文本含"保留他人归属（「Y 说」不改写）"的纪律常量，且不含"自包含 + 文件指针"这类公开回复纪律

#### Scenario: 单 agent 会话走原路径

- **WHEN** 一个普通单会话触发压缩
- **THEN** 输入的仍是会话原始行序列（与变更前逐字一致），摘要 `member_id` 为空

#### Scenario: 不引入共享摘要

- **WHEN** 一个组会话的任意成员触发压缩
- **THEN** 不会产生 `member_id` 为空的摘要行，也不会产生一份被多个视图共用的摘要文本
