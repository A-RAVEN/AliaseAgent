## ADDED Requirements

### Requirement: Compaction-in-progress status indicator

The conversation view SHALL show a status indicator while context compaction is running — both when a send compacts the history before its request goes out, and when an idle background compaction runs — and SHALL remove it when compaction ends. The indicator SHALL be driven by the compaction code itself, set at the points where it is about to issue a compaction-related model request; it SHALL NOT be inferred from the in-flight-send flag (`_isStreaming`) or from the streaming indicator, and a send that does not trigger compaction SHALL NOT show it. The indicator SHALL name the current stage (seam selection, level-1 summary generation, or level-2 roll-up) and its progress: when the stage's total is known it SHALL show "segment k of n", and when the total is not known it SHALL show only how many segments are done. While a background compaction runs, the indicator SHALL state that sending a message makes compaction yield. The indicator SHALL disappear when compaction ends for any reason — success, failure, exception, or being preempted by the user's next send — and that removal SHALL repaint the view. When no compaction is running the indicator SHALL render nothing and SHALL NOT occupy layout space. The compaction status SHALL be readable from `ChatScreenState` so tests can assert the idle and in-progress states.

#### Scenario: A send that triggers compaction
- **WHEN** the user sends a message and this send must produce new summaries before its request goes out
- **THEN** the conversation view shows the compaction indicator naming the stage and progress, and keeps showing it (updated as segments complete) until compaction ends

#### Scenario: A send that does not trigger compaction
- **WHEN** the user sends a message and the accumulated history has not crossed the threshold, so no compaction work runs
- **THEN** the indicator never appears for that send

#### Scenario: Background compaction is visible and announced as yielding
- **WHEN** a background compaction starts in the idle gap after a turn and is about to issue its first compaction-related model request
- **THEN** the indicator appears in the conversation view, states that sending a message makes compaction yield, and stays until that background compaction ends

#### Scenario: Indicator clears when compaction ends
- **WHEN** compaction ends by succeeding, failing, throwing, or being preempted by the user's next send
- **THEN** the indicator is removed and the view is repainted

#### Scenario: Idle renders nothing
- **WHEN** no compaction is running
- **THEN** the indicator renders no content and occupies no layout space, leaving the existing layout unchanged

#### Scenario: Status readable by tests
- **WHEN** a test drives a send that triggers compaction
- **THEN** it reads a non-idle compaction status from `ChatScreenState` while compaction runs, and an idle status after compaction ends
