# Context Compaction — Spec

## Purpose

Keep each API request within the model's context window by replacing older conversation with
summaries, while never deleting anything from disk and never splitting a tool round.
## Requirements
### Requirement: Context budget trigger
The system SHALL keep the API request's total context within a configurable budget. `maxContextTokens` SHALL be a required per-agent-type config (set like apiKey); the system SHALL project the next request's input token count using a deterministic local estimator (sum of per-message proxy tokens) — the RAW conversation size, which requires **no compression-ratio assumption** — and SHALL fold content one level up **as soon as the accumulated token total exceeds the batch threshold `T`**, WITHOUT waiting for that projection to reach `maxContextTokens`: crossing `T` is sufficient, so content is folded even while the request would still fit inside the budget (the budget remains the stop/omit bound, it is NOT the switch that decides when folding starts). **Folding and waiting are two different decisions:** crossing `T` SHALL still fold the batch (WHEN folding runs is unchanged — see "Background folding lifecycle"), but whether a user turn WAITS before its request goes out SHALL be decided by the send-time wait gate alone (see "Send-time wait gate") — a share of the window, never `T`. The wait applies to the SEND-TIME fold (the fold that turn itself needs before its request can go out); it SHALL NOT be read as waiting for the background fold, which the user's send preempts by design. Two token quantities SHALL be kept apart when reading this requirement: the RAW conversation size (sum of per-message proxy tokens) is what `T` is compared against, while the send-time wait gate and the budget bound compare the PROJECTION's estimated total (projected summaries at their persisted measured cost, everything else estimated as raw text). The system SHALL **NOT** estimate a summary's token size via any assumed compression ratio; instead it SHALL measure each summary's real token count at runtime from the actual `/v1/messages` usage block (`input_tokens`/`output_tokens`, Anthropic-format; DeepSeek field naming live-verified 2026-08-26) of the summarization call. Compression SHALL be a uniform batched rule: starting from the OLDEST, accumulate original content (L1) or content (L1→L2) until the accumulated raw token total exceeds a batch threshold `T`, then summarize that batch one level up. **`T` SHALL be derived from the model's context window — never a fixed constant: `T = maxContextTokens × P / 100`, where `P` is a per-agent-type configured percentage (`compaction_threshold_percent`, default `25`, i.e. the window × 25%).** **No threshold in this mechanism SHALL be a count**: every trigger, group boundary, and stop condition SHALL be expressed as a token amount (`T` or a value derived from it) — no "at least N summaries", no "N consecutive segments". A compression is **valid only if** the produced summary's measured token count is LESS than the batch it replaced; the NEWEST content SHALL be kept verbatim (原文); the system SHALL fold only while the accumulated total exceeds `T` (the threshold is what triggers a fold, NOT the budget), and SHALL keep the projection within `maxContextTokens` by leaving the OLDEST content out of the projection (data never deleted) when folding and roll-up are not enough. The system SHALL NOT impose a design-side absolute cap on a summary's output length (no fixed `max_tokens` constant in the compaction design): the summarization request's output length SHALL be governed by the model/provider profile, and the "smaller than what it replaced" check SHALL be the only size guarantee.

#### Scenario: Below the threshold sends as-is
- **WHEN** the accumulated token total is at or below the batch threshold `T`
- **THEN** the full conversation history is sent without compression

#### Scenario: Crossing the threshold folds, even with room to spare
- **WHEN** the accumulated raw token total exceeds the batch threshold `T` (even though the projected request would still fit inside `maxContextTokens`)
- **THEN** the oldest accumulated batch is folded one level up — on the background folding lifecycle when the app is idle, or before the request goes out when the send-time projection exceeds the wait gate; and a turn whose send-time projection stays at or below the wait gate SHALL be sent WITHOUT waiting for that fold (no summarization request for that turn, see "Send-time wait gate")

#### Scenario: The budget stays the stop and omit bound
- **WHEN** after folding and roll-up the request still exceeds `maxContextTokens`
- **THEN** the OLDEST content is left out of the projection (data never deleted) — the budget bounds the projection, it does not decide when folding starts

#### Scenario: Required config
- **WHEN** `maxContextTokens` is not set in the agent config
- **THEN** the app surfaces a setup prompt (like a missing apiKey); this is a one-time configuration, not per-turn management

#### Scenario: Threshold scales with the model window
- **WHEN** the same history is compacted with the same configured percentage under a model whose context window is twice as large
- **THEN** the batch threshold `T` is twice as large (derived, not hard-coded), and the number of level-1 batches does not increase

#### Scenario: Percentage is configurable per agent type
- **WHEN** `compaction_threshold_percent` is absent from the agent config
- **THEN** the default percentage (25) applies; when it is present, that percentage applies instead — with no other value anywhere in the mechanism needing to change

#### Scenario: Summary output length is model-governed
- **WHEN** a summarization request is sent on the summary profile
- **THEN** its output length is not capped by a compaction-design constant, and the "summary must be measured smaller than the batch it replaced" rule is what rejects a bloated summary

### Requirement: Recency-gradient hierarchical compaction
The system SHALL compress the conversation as a hierarchy: recent turns kept verbatim, medium-distance turns replaced by per-segment summaries, and farthest turns by summaries of summaries. The recency gradient SHALL be a deterministic function of history + config, where the set of already-closed segments (delimited boundaries) is a fixed input that is never re-derived or re-shaped (progressive closure — see Segment closure and summary immutability). **The gradient SHALL be driven by the same derived threshold `T` and by token amounts only: the verbatim (recent) span is the bounded newest content whose accumulated raw tokens stay under `T`, and content is folded one level up as soon as the accumulated total exceeds `T` — no count of turns and no count of segments SHALL gate either the fold or the roll-up.** **The PROJECTION SHALL be graded by distance from the newest message, and every band boundary SHALL be a multiple of the same derived `T` (no absolute token constant is introduced anywhere). The distance of a segment SHALL be measured at its OLDEST covered message, as the accumulated RAW (estimated) tokens of everything newer than it — never a summary's measured size (this keeps the gradient a pure function of history + config + the closed segmentation): the newest content whose distance stays under `T` is projected verbatim; content at distance `T`–`2T` is projected as its level-1 summaries; content farther back than `2T` is projected as level-2 summaries. A summary SHALL substitute for finer content in the projection only once that content has reached the band that summary belongs to — generating a summary earlier SHALL NOT substitute it earlier. The unit of that choice SHALL be the summary's whole covered span, and every span of history SHALL be projected with EXACTLY ONE representation (a raw message, a level-1 summary, or a level-2 summary) — never two at once, so no span may appear both as level-1 and as level-2 text. A level-2 summary SHALL be projected only once its WHOLE covered span has reached the farthest band (both edges beyond `2T`); until then that span SHALL be represented by its level-1 summaries (finer than the band would require — that cost is accepted so that nothing is sent twice and nothing is substituted earlier than its position allows). When a span has no summary yet (nothing folded for it yet), the FINER representation SHALL be projected instead (raw text, or its level-1 summaries where those exist) rather than an empty span.**

#### Scenario: Recent verbatim
- **WHEN** the accumulated raw token total exceeds `T`
- **THEN** the newest content whose accumulated raw tokens stay under `T` is kept verbatim (its round structure replayed unchanged; an oversized tool_result BODY may be elided per the near-zone elision requirement), and older content is folded one level up

#### Scenario: Summary of summaries
- **WHEN** the level-1 summaries not yet covered by a level-2 have measured tokens whose accumulated total (oldest-first) first exceeds `T`
- **THEN** those level-1 summaries are folded into a level-2 summary of summaries — the threshold alone authorizes it, with no minimum count of segments

#### Scenario: A level-2 that is not far enough back yet stays out of the projection
- **WHEN** a level-2 summary exists but part of its covered span is still nearer than `2T` (its span has not wholly reached the farthest band)
- **THEN** the projection represents that span by its level-1 summaries and does NOT contain the level-2 summary — the same request SHALL NOT contain both the level-1 and the level-2 text of the same span

#### Scenario: Once the whole span is far enough, the level-2 replaces it and the middle band keeps its own level-1s
- **WHEN** a level-2 summary's whole covered span has reached the farthest band, and separately some level-1 summaries lie in the middle band (`T`–`2T`)
- **THEN** the projection contains the level-2 summary for that far span AND the middle band's level-1 summaries for their own span — each span exactly once

#### Scenario: A band with no summary yet falls back to the finer representation
- **WHEN** the middle band contains content that has not been folded into a level-1 summary yet
- **THEN** that content is projected as raw text (never as an empty span and never as a summary that does not exist yet)

### Requirement: Non-compressible anchor (guard)
The system SHALL never collapse user goals, acceptance criteria, or explicit "don't touch X" invariants, regardless of their age. These anchors SHALL be re-injected on every turn and SHALL be sourced from an explicit standing-requirements mechanism (not LLM-extracted from prose). The anchor set SHALL be bounded, deduplicated, and support staleness/revocation.

#### Scenario: Invariant never collapsed
- **WHEN** a far-old turn carries a hard invariant ("don't touch X")
- **THEN** that invariant is preserved (re-injected) and never folded into a summary

#### Scenario: Anchor re-injected each turn
- **WHEN** a turn is sent
- **THEN** the preserved anchors are injected each turn

### Requirement: Segments never split a tool round
The system SHALL treat an assistant message carrying tool_calls plus its immediately following synthetic user(tool_result) message as a single atomic fold unit, and SHALL never split that unit when segmenting.

#### Scenario: Tool round atomic
- **WHEN** a segment boundary is chosen
- **THEN** it never falls between an assistant tool_use message and its synthetic tool_result user message

#### Scenario: Tool round survives compaction
- **WHEN** a segment containing a tool round is compacted
- **THEN** the whole tool round is folded together (or kept verbatim, structure replayed), never partially — an oversized tool_result BODY may be elided to a marker only per the Near-zone elision requirement, never the round structure

### Requirement: Safe segment boundary choice
The system SHALL place segment boundaries only at safe cut points: a real user text message, or a terminal assistant message with no tool_use, and never on an assistant message carrying tool_calls. **Exemption (the fold's FIRST message, far[0])**: a boundary at the fold region's very first message is permitted even if that message is an assistant carrying tool_calls — there is no foldable message before it to split a tool round WITH, and its synthetic user(tool_result) is emitted from that same assistant Message (never a separate persisted row), so no tool_use/tool_result pairing is divided. This matches the whole-conversation index-0 exemption and does not "cut mid-tool".

#### Scenario: Cut on real user text
- **WHEN** the history reaches a real user text message
- **THEN** a segment boundary may be placed there

#### Scenario: Never cut mid-tool
- **WHEN** the history has an assistant message with unresolved tool_calls
- **THEN** no segment boundary is placed there

### Requirement: Compressed output is plain text
The compressed summary SHALL be a plain role:user text message, clearly marked as non-user speech, and SHALL NOT synthesize thinking/tool_use/tool_result content blocks.

#### Scenario: Summary is user-role text
- **WHEN** a segment is folded
- **THEN** the summary is a role:user text message with a marker (e.g., "## 更早上下文(压缩xN,非用户发言)")

#### Scenario: No synthesized blocks
- **WHEN** a fold produces a summary
- **THEN** it contains no fabricated tool_use, tool_result, or thinking blocks

### Requirement: Original conversation retained on disk (immutable)
The system SHALL keep the full original conversation in SQLite, and SHALL persist BOTH the level-1 per-segment summaries AND the level-2 "summary of summaries" as immutable derived data in `summary_nodes` (keyed by level). The compaction tree SHALL be a derived index; no original message and no persisted summary SHALL be deleted or overwritten by compaction. Omitting a segment from the API PROJECTION (not sending it to the model) is a projection decision ONLY and SHALL NEVER delete the underlying data: originals and summaries remain persisted and re-expandable.

#### Scenario: Originals preserved
- **WHEN** compaction folds a segment
- **THEN** the original messages remain in the messages table, unchanged

#### Scenario: Summaries persisted (level-1 and level-2)
- **WHEN** a segment is folded to a level-1 summary, or level-1 summaries are rolled up to a level-2 summary
- **THEN** the summary is stored in summary_nodes with its level, unchanged, and is never deleted by later compaction

#### Scenario: Omitting from projection never deletes data
- **WHEN** the coarsest (level-2) summary alone still exceeds the budget and the oldest content is omitted from the request projection
- **THEN** that content is simply not sent to the model; the original messages and all summaries remain persisted on disk and can be re-expanded on demand

#### Scenario: Re-expand path
- **WHEN** a summary is not detailed enough
- **THEN** the harness can re-expand the original segment from disk on demand

### Requirement: Background folding lifecycle
The system SHALL fold segments in the background, idle-gated and preemptible: folding SHALL run only when the model slot is free and the user is idle, SHALL be preempted (with request-id targeted cancel) and checkpointed when the user sends a new message, and SHALL persist the summary node to the summary_nodes table in a transaction.

#### Scenario: Fold runs when idle
- **WHEN** a user turn completes, a segment is ready to fold, and the app is idle
- **THEN** a background fold is triggered on the summary profile

#### Scenario: User send preempts fold
- **WHEN** the user sends a new message while a fold is in flight
- **THEN** the fold is cancelled (request-id targeted) and checkpointed, and never delays the user's request

#### Scenario: Fold persists transactionally
- **WHEN** a fold completes
- **THEN** the summary node is written to summary_nodes and tree_version is bumped in a single transaction

### Requirement: Segment closure and summary immutability
The system SHALL treat a conversation segment delimited by two cut markers as a fixed, immutable unit of history. A closed segment's summary SHALL be computed once, persisted, and reused on every subsequent turn — never re-summarized. Segment closure SHALL be progressive: as the conversation grows, the system closes new segments only from the not-yet-closed tail; previously-closed segments are never re-opened or re-shaped, even if the budget would otherwise prefer a different partition. **Closure freezes a segment's summary against re-derivation from its original messages; it SHALL NOT bar a persisted level-1 summary from being reused as an INPUT to a single level-2 roll-up (see "Level-2 roll-up is threshold-only and accumulates across folds"). A persisted summary's own stored text SHALL never be regenerated by that roll-up.**

#### Scenario: Closed segment is frozen
- **WHEN** a segment is delimited by two cut markers
- **THEN** its content and its summary never change and are reused verbatim from the persisted node on all later turns

#### Scenario: Progressive closure at the tail
- **WHEN** new messages are appended to a growing conversation
- **THEN** the system folds only the not-yet-closed tail into new closed segments; existing closed segments and their summaries remain untouched

#### Scenario: Summary persisted once and reused
- **WHEN** a segment is first closed
- **THEN** its summary is materialized to summary_nodes exactly once and is reused (not regenerated) on every later turn

#### Scenario: Closure does not bar a level-2 roll-up
- **WHEN** a persisted level-1 summary is one of the accumulated inputs to a level-2 roll-up on a later turn
- **THEN** its stored text is reused unchanged as roll-up input (no re-summarization of its original messages), and the level-2 node is persisted alongside it — the level-1 node is neither rewritten nor deleted

### Requirement: Near-zone oversized tool_result body elision
For a recently-kept (verbatim) tool round whose tool_result content is extremely large, the system SHALL be permitted to elide the oversized BODY to a truncation marker plus a refetch record (path/byte/line range) while preserving the tool_use block, the tool_result placement, and the tool round structure. This is a documented near-zone exception to full-body replay; it never folds or splits the round, nor does it break tool_use/tool_result pairing.

#### Scenario: Oversized near tool_result body elided
- **WHEN** a kept (verbatim) near tool round has a tool_result body exceeding a size threshold
- **THEN** its body is replaced by a truncation marker + refetch record, while the tool_use block and the round structure remain intact and unchanged

#### Scenario: Round structure preserved on elision
- **WHEN** an oversized near tool_result body is elided
- **THEN** no tool_use/tool_result pair is folded or split, and the message remains valid alternation

### Requirement: Deterministic fold plan
The system SHALL deterministically determine the **STRUCTURE** of the fold — the batch boundaries (by accumulated raw token > threshold `T` = the model context window × the configured percentage, oldest-first) and which newest content stays verbatim — as a pure function of history + config + the set of the already-closed segments (the persisted closed segmentation). Determinism means the same (history, config, closed-segmentation) yields the same fold structure; closed segments are fixed inputs, never re-derived or re-shaped (progressive closure). The system SHALL **NOT** fold a summary's token size into this pure function via any assumed compression ratio — a summary size is only known after the summarization call, so it SHALL be **measured at runtime** from the real `/v1/messages` usage (`output_tokens`), and the roll-up/reject decision SHALL be driven by that measured size (fold→measure→adjust) — the budget decides only the oldest-content omission, never when folding starts. LLM output SHALL only fill the content of already-chosen leaves; it SHALL NOT change which segments fold or the cover topology. (The singular LLM-assisted exception — the AI topic seam within a batch, constrained to memoization — see Semantic boundary selection.)

#### Scenario: Deterministic which-segments-fold
- **WHEN** the same history, config, and closed-segmentation are provided twice
- **THEN** both produce the same fold plan (same eligible segments, budget, cover topology)

#### Scenario: LLM only fills chosen leaves
- **WHEN** a fold is executed
- **THEN** LLM output populates the summary content of an already-chosen leaf and does not add or remove segments

#### Scenario: One threshold value, derived once
- **WHEN** any batch boundary, group boundary, or stop condition is computed
- **THEN** it uses `T` derived from `maxContextTokens` × the configured percentage — no independently hard-coded token constant (such as a fixed floor or a fixed summary length) participates

### Requirement: Semantic boundary selection (topic seams)
The system SHALL, among the safe candidate cut points for a chosen fold, select the one that best preserves topic coherence (LLM-assisted), and SHALL memoize this selection (content-hash keyed) so a rebuild reproduces the same selection. This is the ONLY point where LLM output affects the tree shape, and memoization constrains it to be reproducible.

#### Scenario: Boundary at topic seam
- **WHEN** multiple safe cut points exist for a fold
- **THEN** the system picks the one that avoids splitting a topic cluster

#### Scenario: Memoized boundary
- **WHEN** the same content is rebuilt
- **THEN** the same boundary selection is reused from cache

### Requirement: Stable message ordering (seq)
Every message SHALL be assigned a monotonic `seq` at insert; the compaction tree SHALL key its spans by (session_id, start_seq, end_seq) and never by the non-sortable UUID id.

#### Scenario: seq monotonic under same-millisecond inserts
- **WHEN** multiple messages are inserted in the same millisecond (tool loop)
- **THEN** each receives a strictly increasing seq

#### Scenario: Tree spans use seq
- **WHEN** a summary node records its coverage
- **THEN** it uses (start_seq, end_seq), not message UUIDs

### Requirement: Level-2 roll-up is threshold-only and accumulates across folds
The system SHALL decide a level-2 "summary of summaries" roll-up by ONE token threshold and nothing else — the same uniform rule and the same `T` as the level-1 fold, applied one level up: starting from the OLDEST, accumulate the MEASURED token counts of the level-1 summaries that are not yet covered by a level-2, and roll that group up into a single level-2 as soon as the accumulated total exceeds `T` (= the model context window × the configured percentage — the same derived threshold, no second constant). **Reaching the threshold SHALL be sufficient: the roll-up SHALL NOT wait for the budget, and SHALL NOT depend on whether the current projection still fits — the trigger SHALL be independent of the budget.** The system SHALL NOT gate the roll-up on any count of segments. A roll-up SHALL be accepted only if the produced level-2's measured token count is LESS than the summed measured tokens of the level-1 summaries it replaces; otherwise it SHALL be rejected (and the oldest content omitted from the projection instead, data never deleted). Persisted level-1 summaries SHALL remain eligible roll-up inputs on later turns — they SHALL NOT be frozen out of the level-2 input set — so that the accumulated total can actually reach the threshold; their stored text SHALL be reused, never regenerated. A level-2 summary SHALL never be an input to another level-2 (exactly two levels).

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
- **THEN** no level-2 is produced (the threshold, not a count, is what authorizes a roll-up); if the projection must still shrink, the oldest content is omitted from the projection instead, with the data kept on disk

#### Scenario: No count gate blocks a single large level-1
- **WHEN** a single level-1 summary alone already exceeds `T`
- **THEN** the roll-up is attempted on the token rule alone (no "at least two" gate blocks it) and is accepted only if the produced level-2 is measured smaller than that level-1 summary

#### Scenario: Level-2 is never rolled up again
- **WHEN** a level-2 summary exists
- **THEN** it is never an input to another level-2 summary; if it alone still exceeds the budget it is only omitted from the projection (data never deleted)

### Requirement: Send-time wait gate
Whether a user turn WAITS for compaction before its request goes out SHALL be decided by ONE quantity: the share of the model's context window that the request would occupy **if it were sent now** — the estimated total of what would actually be projected (raw messages kept verbatim + level-1 summaries projected + level-2 summaries projected, each summary counted at its persisted measured token cost), divided by `maxContextTokens`. The turn SHALL wait only when that share EXCEEDS a configurable wait percentage (`compaction_wait_threshold_percent`, per agent type, default `75`); the bound SHALL be derived as `maxContextTokens × W / 100` — never an absolute token constant, never a count of messages or summaries. The gate SHALL be evaluated from the deterministic local estimator BEFORE any summarization call, so deciding costs no model call.

When the share is at or BELOW the bound, the request SHALL be sent without waiting for compaction: no summarization request SHALL be issued for that turn, the projection SHALL use only summaries already persisted (content not yet summarized SHALL be projected as raw text), and folding SHALL be left to the background folding lifecycle.

When the share EXCEEDS the bound, the turn SHALL wait for the fold to finish before its request goes out, and the compaction status indicator SHALL be shown while it waits (see the chat-ui capability).

The gate SHALL NOT change WHEN content is folded (crossing `T` still folds it, and the fold still happens on the background lifecycle) and SHALL NOT change the budget bound: if the request still exceeds the wait bound after folding and roll-up, the turn SHALL NOT be blocked waiting for a bound it cannot reach — the existing oldest-first omission (data kept on disk) and the existing "summarization failed, send verbatim" fallback SHALL apply.

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
- **THEN** the OLDEST adjustable content is left out of this request's projection (data kept on disk, exactly as the budget rule already requires), and a summarization failure falls back to sending verbatim — the turn is never blocked waiting for a bound it cannot reach. Exceeding the WAIT bound alone SHALL NOT cause any content to be left out: the wait bound decides only whether the turn waits, and it is always below `maxContextTokens`

#### Scenario: The gate never issues a summary call to decide
- **WHEN** a turn's projection share is computed
- **THEN** it is computed from the deterministic local estimator without any model call, so deciding whether to wait costs nothing

### Requirement: Summarizer reference context is bounded and kept apart from the text being summarized
A level-1 summarization request on the folding path SHALL carry a **reference context** assembled from **already-persisted summaries only**, at most **two** of them: the most recent level-1 summary available for older history, and the highest-level summary available for older history (typically a level-2 summary, but not necessarily). A summary SHALL be eligible only when its whole covered span ends strictly before the oldest message of the batch being summarized — a summary whose covered span overlaps that batch SHALL NOT be carried. Each carried summary SHALL be accompanied by the sequence range it covers, and the same span SHALL NOT be carried twice: when the finer summary's covered span lies wholly inside the coarser one's, only the coarser one is carried. The reference context SHALL NEVER grow with session length: it is a fixed count of summaries, never "all earlier summaries". When no eligible summary exists — the very first fold, or a session whose summary store is not open — the request SHALL be exactly what it is today: the folded messages, today's system text, and the existing summarize instruction, with nothing added and no extra headers.

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

### Requirement: Summarization cost is observable per call
Each summarization call's measured **input** token count (read from the same `/v1/messages` usage block that already supplies the output count) SHALL be recorded on that call's observability channel — a diagnostic line, never the model-visible content — together with the output count, for every summarization call the system makes. This is observation only: the existing rule that a summary's measured **output** size decides whether that summary is valid (see "Deterministic fold plan" and "Level-2 roll-up is threshold-only and accumulates across folds") SHALL stay exactly as it is, and input tokens SHALL NOT enter the fold or roll-up decision.

#### Scenario: The input token count is recorded for every call
- **WHEN** a level-1 fold or a level-2 roll-up completes
- **THEN** that call's measured input token count appears on the observability channel next to its output count

#### Scenario: The input token count never reaches the model
- **WHEN** a summarization call completes
- **THEN** its input token count appears only on the observability channel, never in the content sent to a model

#### Scenario: Input tokens never decide whether a summary is kept
- **WHEN** a summarization call reports large input tokens but the produced summary is smaller than the content it replaces
- **THEN** that summary is accepted — validity is still decided by the measured output size alone

