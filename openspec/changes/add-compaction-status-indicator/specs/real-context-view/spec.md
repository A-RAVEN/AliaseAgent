## ADDED Requirements

### Requirement: What the real context view shows while compaction runs

While compaction is running, the real context view SHALL show the compaction status indicator pinned at the top of the view (not scrolling with the message list), and that indicator SHALL state that the content below is the previously sent request and that the compacted result appears only on the next send. The view SHALL NOT display content that has not been sent: summaries being generated during compaction SHALL NOT appear here, which keeps the existing fidelity boundary (this view shows the main-conversation request only, never the seam-selector or summarizer requests). When no snapshot has been captured yet, the indicator SHALL appear together with the existing no-snapshot placeholder. The indicator SHALL disappear from this view when compaction ends.

#### Scenario: Compaction running while this view is shown
- **WHEN** a compaction is running and the user is on (or switches to) the real context view
- **THEN** the top of the view shows the compaction status indicator, stating that the content below is the previously sent request and that the compacted result appears on the next send

#### Scenario: In-progress summaries are not shown
- **WHEN** compaction is generating a summary for some span
- **THEN** the view does not show that summary text, and the content below is still the previously sent request

#### Scenario: No snapshot captured yet
- **WHEN** no request has been sent since the app started, and a compaction is running for the first send
- **THEN** the indicator appears together with the existing no-snapshot placeholder

#### Scenario: Indicator clears with compaction
- **WHEN** compaction ends
- **THEN** the indicator disappears from this view as well
