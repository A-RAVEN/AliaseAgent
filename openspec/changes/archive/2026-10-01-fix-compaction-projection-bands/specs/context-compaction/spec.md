## MODIFIED Requirements

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

