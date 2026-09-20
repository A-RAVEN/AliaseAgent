## MODIFIED Requirements

### Requirement: Context budget trigger
The system SHALL keep the API request's total context within a configurable budget. `maxContextTokens` SHALL be a required per-agent-type config (set like apiKey); the system SHALL project the next request's input token count using a deterministic local estimator (sum of per-message proxy tokens) — the RAW conversation size, which requires **no compression-ratio assumption** — and SHALL fold content one level up **as soon as the accumulated token total exceeds the batch threshold `T`**, WITHOUT waiting for that projection to reach `maxContextTokens`: crossing `T` is sufficient, so content is folded even while the request would still fit inside the budget (the budget remains the stop/omit bound, it is NOT the switch that decides when folding starts). The system SHALL **NOT** estimate a summary's token size via any assumed compression ratio; instead it SHALL measure each summary's real token count at runtime from the actual `/v1/messages` usage block (`input_tokens`/`output_tokens`, Anthropic-format; DeepSeek field naming live-verified 2026-08-26) of the summarization call. Compression SHALL be a uniform batched rule: starting from the OLDEST, accumulate original content (L1) or content (L1→L2) until the accumulated raw token total exceeds a batch threshold `T`, then summarize that batch one level up. **`T` SHALL be derived from the model's context window — never a fixed constant: `T = maxContextTokens × P / 100`, where `P` is a per-agent-type configured percentage (`compaction_threshold_percent`, default `25`, i.e. the window × 25%).** **No threshold in this mechanism SHALL be a count**: every trigger, group boundary, and stop condition SHALL be expressed as a token amount (`T` or a value derived from it) — no "at least N summaries", no "N consecutive segments". A compression is **valid only if** the produced summary's measured token count is LESS than the batch it replaced; the NEWEST content SHALL be kept verbatim (原文); the system SHALL fold only while the accumulated total exceeds `T` (the threshold is what triggers a fold, NOT the budget), and SHALL keep the projection within `maxContextTokens` by leaving the OLDEST content out of the projection (data never deleted) when folding and roll-up are not enough. The system SHALL NOT impose a design-side absolute cap on a summary's output length (no fixed `max_tokens` constant in the compaction design): the summarization request's output length SHALL be governed by the model/provider profile, and the "smaller than what it replaced" check SHALL be the only size guarantee.

#### Scenario: Below the threshold sends as-is
- **WHEN** the accumulated token total is at or below the batch threshold `T`
- **THEN** the full conversation history is sent without compression

#### Scenario: Crossing the threshold folds, even with room to spare
- **WHEN** the accumulated raw token total exceeds the batch threshold `T` (even though the projected request would still fit inside `maxContextTokens`)
- **THEN** the oldest accumulated batch is folded one level up before the request is sent

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
The system SHALL compress the conversation as a hierarchy: recent turns kept verbatim, medium-distance turns replaced by per-segment summaries, and farthest turns by summaries of summaries. The recency gradient SHALL be a deterministic function of history + config, where the set of already-closed segments (delimited boundaries) is a fixed input that is never re-derived or re-shaped (progressive closure — see Segment closure and summary immutability). **The gradient SHALL be driven by the same derived threshold `T` and by token amounts only: the verbatim (recent) span is the bounded newest content whose accumulated raw tokens stay under `T`, and content is folded one level up as soon as the accumulated total exceeds `T` — no count of turns and no count of segments SHALL gate either the fold or the roll-up.**

#### Scenario: Recent verbatim
- **WHEN** the accumulated raw token total exceeds `T`
- **THEN** the newest content whose accumulated raw tokens stay under `T` is kept verbatim (its round structure replayed unchanged; an oversized tool_result BODY may be elided per the near-zone elision requirement), and older content is folded one level up

#### Scenario: Summary of summaries
- **WHEN** the level-1 summaries not yet covered by a level-2 have measured tokens whose accumulated total (oldest-first) first exceeds `T`
- **THEN** those level-1 summaries are folded into a level-2 summary of summaries — the threshold alone authorizes it, with no minimum count of segments

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

## ADDED Requirements

### Requirement: Level-2 roll-up is threshold-only and accumulates across folds
The system SHALL decide a level-2 "summary of summaries" roll-up by ONE token threshold and nothing else — the same uniform rule and the same `T` as the level-1 fold, applied one level up: starting from the OLDEST, accumulate the MEASURED token counts of the level-1 summaries that are not yet covered by a level-2, and roll that group up into a single level-2 as soon as the accumulated total exceeds `T` (= the model context window × the configured percentage — the same derived threshold, no second constant). **Reaching the threshold SHALL be sufficient: the roll-up SHALL NOT wait for the budget, and SHALL NOT depend on whether the current projection still fits — the trigger SHALL be independent of the budget.** The system SHALL NOT gate the roll-up on any count of segments. A roll-up SHALL be accepted only if the produced level-2's measured token count is LESS than the summed measured tokens of the level-1 summaries it replaces; otherwise it SHALL be rejected (and the oldest content omitted from the projection instead, data never deleted). Persisted level-1 summaries SHALL remain eligible roll-up inputs on later turns — they SHALL NOT be frozen out of the level-2 input set — so that the accumulated total can actually reach the threshold; their stored text SHALL be reused, never regenerated. A level-2 summary SHALL never be an input to another level-2 (exactly two levels).

#### Scenario: Accumulated level-1 tokens exceed the threshold
- **WHEN** the level-1 summaries not yet covered by a level-2 have measured tokens whose accumulated total first exceeds `T` (oldest-first)
- **THEN** that oldest group is rolled up into ONE level-2 summary, and the projection is re-measured after the roll-up

#### Scenario: The threshold is enough on its own
- **WHEN** the accumulated level-1 measured tokens exceed `T` while the conversation is still within budget (the projection would fit without any roll-up)
- **THEN** the roll-up still happens — reaching the threshold is sufficient, and the roll-up does not wait for the budget

#### Scenario: Level-2 actually reaches the request projection
- **WHEN** such a roll-up happens
- **THEN** the request projection actually sent to the model contains the level-2 summary (the level-2 marker), and a `level = 2` row exists in `summary_nodes` whose covered span is the union of the rolled-up level-1 spans

#### Scenario: Rolled-up level-1s are not duplicated
- **WHEN** a level-2 covers a span
- **THEN** the level-1 summaries inside that span are not also sent as separate projection entries

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
