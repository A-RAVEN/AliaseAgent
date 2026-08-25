# Context Compaction — Spec

## ADDED Requirements

### Requirement: Context budget trigger
The system SHALL keep the API request's total context within a configurable budget. `maxContextTokens` SHALL be a required per-agent-type config (set like apiKey); the system SHALL project the next request's input token count using a deterministic local estimator (sum of per-message proxy tokens) and SHALL compact the conversation before sending when that projection reaches `maxContextTokens`. The measured-usage source SHALL be parsed defensively from the `/v1/messages` usage block (Anthropic-format `input_tokens`/`output_tokens`; the exact DeepSeek field naming is [UNVERIFIED] and must be verified before finalizing).

#### Scenario: Under budget sends as-is
- **WHEN** the projected request size is below `maxContextTokens`
- **THEN** the full conversation history is sent without compression

#### Scenario: Reaches budget compacts
- **WHEN** the projected request size reaches `maxContextTokens`
- **THEN** older segments are folded into summaries before the request is sent, keeping the total at or below the budget

#### Scenario: Required config
- **WHEN** `maxContextTokens` is not set in the agent config
- **THEN** the app surfaces a setup prompt (like a missing apiKey); this is a one-time configuration, not per-turn management

### Requirement: Recency-gradient hierarchical compaction
The system SHALL compress the conversation as a hierarchy: recent turns kept verbatim, medium-distance turns replaced by per-segment summaries, and farthest turns by summaries of summaries. The recency gradient SHALL be a deterministic function of history + config.

#### Scenario: Recent verbatim
- **WHEN** the conversation exceeds the budget
- **THEN** the most recent N turns are kept verbatim (their round structure replayed unchanged; an oversized tool_result BODY may be elided per the near-zone elision requirement), older turns are replaced by summaries

#### Scenario: Summary of summaries
- **WHEN** there are multiple level-1 segments to fold
- **THEN** the furthest segments are folded into a level-2 summary of the level-1 summaries

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
The system SHALL place segment boundaries only at safe cut points: a real user text message, or a terminal assistant message with no tool_use, and never on an assistant message carrying tool_calls.

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

### Requirement: Original conversation retained on disk
The system SHALL keep the full original conversation in SQLite; the compaction tree SHALL be a derived index, and no original message SHALL be deleted or overwritten by compaction.

#### Scenario: Originals preserved
- **WHEN** compaction folds a segment
- **THEN** the original messages remain in the messages table, unchanged

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

### Requirement: Near-zone oversized tool_result body elision
For a recently-kept (verbatim) tool round whose tool_result content is extremely large, the system SHALL be permitted to elide the oversized BODY to a truncation marker plus a refetch record (path/byte/line range) while preserving the tool_use block, the tool_result placement, and the tool round structure. This is a documented near-zone exception to full-body replay; it never folds or splits the round, nor does it break tool_use/tool_result pairing.

#### Scenario: Oversized near tool_result body elided
- **WHEN** a kept (verbatim) near tool round has a tool_result body exceeding a size threshold
- **THEN** its body is replaced by a truncation marker + refetch record, while the tool_use block and the round structure remain intact and unchanged

#### Scenario: Round structure preserved on elision
- **WHEN** an oversized near tool_result body is elided
- **THEN** no tool_use/tool_result pair is folded or split, and the message remains valid alternation

### Requirement: Deterministic fold plan
The system SHALL deterministically determine WHICH segments are eligible to fold, the budget, and the cover topology, as a pure function of history + config + proxy token sizes. LLM output SHALL only fill the content of already-chosen leaves; it SHALL NOT change which segments fold or the cover topology. (The singular LLM-assisted exception — selecting the seam within a chosen fold — is constrained to memoization, see Semantic boundary selection.)

#### Scenario: Deterministic which-segments-fold
- **WHEN** the same history and config are provided twice
- **THEN** both produce the same fold plan (same eligible segments, budget, cover topology)

#### Scenario: LLM only fills chosen leaves
- **WHEN** a fold is executed
- **THEN** LLM output populates the summary content of an already-chosen leaf and does not add or remove segments

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
