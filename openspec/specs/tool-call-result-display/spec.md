## Requirements

### Requirement: Structured result model
The system SHALL provide a `ResultSection` / `ResultItem` model in `ToolCallActivity` that stores search results as a structured list, enabling per-item rendering in the UI.

#### Scenario: web_search populates resultSections
- **WHEN** a web_search tool call completes successfully with multi-provider results
- **THEN** `ToolCallActivity.resultSections` SHALL contain one `ResultSection` per provider, each with a label (provider name), and `ResultItem` entries for each search result with title, url, and content fields

#### Scenario: resultSections is null for non-structured tools
- **WHEN** a tool call that is NOT web_search or web_fetch completes (e.g., read_file, list_dir, get_current_time)
- **THEN** `ToolCallActivity.resultSections` SHALL be null, and UI SHALL fall back to the existing string-based display

#### Scenario: Serialization round-trip preserves structured data
- **WHEN** a `ToolCallActivity` with `resultSections` is serialized to JSON and deserialized back
- **THEN** all `ResultSection` labels, item titles, URLs, and content SHALL be preserved

#### Scenario: Backward compatible deserialization — missing resultSections
- **WHEN** a `ToolCallActivity` JSON without `resultSections` field is deserialized
- **THEN** `resultSections` SHALL be null without error

#### Scenario: Backward compatible deserialization — name key fallback
- **WHEN** a `ToolCallActivity` JSON uses `name` (legacy API key) instead of `toolName` (canonical key)
- **THEN** `fromJson` SHALL accept `name` as fallback, setting `toolName` to `json['toolName'] ?? json['name'] ?? 'unknown'`

#### Scenario: Empty search results
- **WHEN** a web_search tool call completes successfully but returns zero results (empty results map or all providers returned no items)
- **THEN** `ToolCallActivity.resultSections` SHALL be an empty list `[]`, and the UI SHALL display "No results found"

#### Scenario: Provider-level error
- **WHEN** a web_search tool call completes with one provider returning an error (e.g., timeout) and another returning results
- **THEN** the failed provider's `ResultSection` SHALL have `error` set and `items` empty; the successful provider's `ResultSection` SHALL have `items` populated

### Requirement: Executing state display
The system SHALL show a spinner and "Executing..." label while a tool call is in progress, and SHALL hide the result area entirely during execution.

#### Scenario: Card shows spinner during execution
- **WHEN** a tool call has status `ToolCallStatus.executing`
- **THEN** the card SHALL render a circular progress indicator and "Executing..." label in the header, and SHALL NOT render any result content (collapsed or expanded)

#### Scenario: Executing state transitions to done
- **WHEN** a tool call transitions from executing to done
- **THEN** the spinner SHALL be replaced by a check icon and "Done" label, and the result area SHALL appear in collapsed state

### Requirement: Collapsed state shows minimal summary
The system SHALL display a one-line summary when the tool call card is collapsed, showing the result count without revealing individual search results.

#### Scenario: Collapsed card for multi-provider search
- **WHEN** a web_search card has structured results with 3 providers totaling 15 items, and the card is in collapsed state
- **THEN** the collapsed body SHALL display a single line like "3 providers, 15 results" without any result titles, URLs, or content

#### Scenario: Collapsed card for single-provider search
- **WHEN** a web_search card has results from 1 provider with 5 items, and the card is in collapsed state
- **THEN** the collapsed body SHALL display "5 results" or equivalent succinct summary without per-item details

#### Scenario: Collapsed card for empty results
- **WHEN** a web_search card has an empty `resultSections` list `[]`
- **THEN** the collapsed body SHALL display "No results found"

#### Scenario: Collapsed card for fallback (no structured data)
- **WHEN** a tool call card has null `resultSections` and is collapsed
- **THEN** the card SHALL display the existing `resultPreview` string behavior (truncated to 300 chars)

### Requirement: Expanded state shows all results
The system SHALL render all search results as individual items when the tool call card is expanded, with each item displaying its title, URL, and content snippet.

#### Scenario: Expanded card renders all result items
- **WHEN** a web_search card with 15 result items across providers is expanded
- **THEN** all 15 result items SHALL be rendered, each showing title, URL, and a content preview (max 200 characters)

#### Scenario: Expanded card shows provider grouping
- **WHEN** a web_search card with results from multiple providers is expanded
- **THEN** results SHALL be visually grouped by provider with section headers showing the provider name and item count

#### Scenario: Expanded card shows provider error
- **WHEN** a provider's `ResultSection` has a non-null `error` field
- **THEN** the section header SHALL display the provider name with an error indicator (e.g., "search-prime — ERROR"), and the error message SHALL be shown in place of result items

#### Scenario: Expanded card for web_fetch
- **WHEN** a web_fetch card is expanded
- **THEN** the fetched page URL and content SHALL be displayed, with the URL rendered as a clickable link

### Requirement: URL click interaction
The system SHALL render result URLs as clickable elements that open the link in the system's default web browser.

#### Scenario: Click a search result URL
- **WHEN** user clicks/taps a result URL in the expanded tool call card
- **THEN** the system SHALL open that URL in the default external browser via url_launcher

#### Scenario: URL visually indicates clickability
- **WHEN** a result URL is displayed in the expanded card
- **THEN** the URL SHALL be visually distinct from plain text (e.g., color accent, underline, or link icon)
