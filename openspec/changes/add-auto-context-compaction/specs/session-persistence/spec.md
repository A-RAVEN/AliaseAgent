# Session Persistence — Spec (delta)

## ADDED Requirements

### Requirement: Stable seq column
The messages table SHALL include a monotonic `seq` integer column (autoincrement) with a (session_id, seq) index, providing a stable total order even for messages inserted in the same millisecond. `seq` is used as the stable ordering key for compaction tree spans and for reconstructing the message sequence; the existing UI list load continues to order by `created_at` for display.

#### Scenario: seq present
- **WHEN** a message is inserted
- **THEN** it receives a strictly increasing seq

#### Scenario: seq indexed for spans
- **WHEN** the compaction tree records a node span
- **THEN** it uses (session_id, start_seq, end_seq), and the (session_id, seq) index supports span queries

### Requirement: Summary nodes table
The system SHALL persist the compaction tree in a `summary_nodes` table keyed by (session_id, level, start_seq, end_seq), storing summary_json (role blocks), token_cost, summary_prompt_version, model, parent_id, and covered_min/max_seq, with a leaf_owner index and a dense non-overlap constraint.

#### Scenario: Summary node persisted
- **WHEN** a fold completes
- **THEN** a row is inserted into summary_nodes with its seq span and metadata

#### Scenario: Non-overlapping coverage
- **WHEN** multiple nodes cover a session
- **THEN** their covered_seq ranges are dense and non-overlapping

### Requirement: token_count write
The `token_count` column SHALL be written with the measured provider usage at message persist time, rather than remaining unwritten.

#### Scenario: token_count populated
- **WHEN** a message is persisted after a completed request
- **THEN** its token_count equals the measured usage from the provider

### Requirement: Schema migration v3 to v4
The system SHALL migrate schema version 3 to 4 by adding the `seq` column (backfilled best-effort by created_at, rowid), creating the `summary_nodes` table, and adding a per-session `tree_version`; it SHALL NOT pre-build rollup rows for legacy data (legacy messages remain uncompressed leaves, built lazily forward). The schema SHALL be mirrored in both `_init` and `openAt`.

#### Scenario: v3 to v4 migration
- **WHEN** the database is opened at schema version 3 and the app expects version 4
- **THEN** seq + summary_nodes + tree_version are added, no legacy rollups are pre-built, and existing data is preserved

#### Scenario: openAt mirrors schema
- **WHEN** tests use openAt
- **THEN** the resulting schema includes seq + summary_nodes, matching _init
