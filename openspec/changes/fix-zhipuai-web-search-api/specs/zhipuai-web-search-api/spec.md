## ADDED Requirements

### Requirement: Web Search API returns structured results
The ZhipuAI provider SHALL call the standalone Web Search API (`POST /api/paas/v4/tools/web_search`) and return structured search results.

#### Scenario: Basic search returns results
- **WHEN** `ZhipuAISearch::search("test query", "basic", 5)` is called with a valid API key
- **THEN** the function SHALL POST to the Web Search API endpoint
- **AND** parse `search_result[]` from the JSON response
- **AND** map each item's `title`, `link`, `content` to `SearchResult{title, url, content}`

#### Scenario: Empty results
- **WHEN** the Web Search API returns `{"search_result":[]}`
- **THEN** `ProviderResult.results` SHALL be empty
- **AND** `ProviderResult.error.message` SHALL be empty (success, no error)

#### Scenario: HTTP error response
- **WHEN** the Web Search API returns HTTP 401
- **THEN** `ProviderResult.error` SHALL contain the HTTP status code and error message

#### Scenario: Connection timeout
- **WHEN** the Web Search API does not respond within 30 seconds
- **THEN** `ProviderResult.error.is_transient` SHALL be true

### Requirement: Web Search API request format
The ZhipuAI provider SHALL send the correct request format to the Web Search API.

#### Scenario: Request body contains required fields
- **WHEN** `ZhipuAISearch::search("test", "basic", 5)` is called
- **THEN** the POST body SHALL contain `search_query` set to the query
- **AND** `count` SHALL equal `max_results`
- **AND** `search_engine` SHALL be `"search_pro"` (default)
