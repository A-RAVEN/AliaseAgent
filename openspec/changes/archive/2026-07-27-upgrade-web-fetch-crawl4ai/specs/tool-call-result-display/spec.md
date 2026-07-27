## MODIFIED Requirements

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
- **THEN** the fetched page title (if available) SHALL be displayed as the result item title, the URL SHALL be displayed as a clickable link, and the markdown content SHALL be displayed as the result body
