## MODIFIED Requirements

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

## ADDED Requirements

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
