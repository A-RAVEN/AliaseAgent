## ADDED Requirements

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
