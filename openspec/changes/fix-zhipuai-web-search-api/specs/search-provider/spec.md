## MODIFIED Requirements

### Requirement: ZhipuAI search provider
The ZhipuAI search provider SHALL use the standalone Web Search API (`POST /api/paas/v4/tools/web_search`) to perform searches, not the Chat Completions web_search tool.

#### Scenario: Search via Web Search API
- **WHEN** `ZhipuAISearch::search(query, depth, max_results)` is called
- **THEN** the provider SHALL send a single HTTP POST to the Web Search API endpoint
- **AND** parse the `search_result[]` array from the JSON response into `SearchResult[]`
- **AND** depth parameter SHALL be ignored (Web Search API does not support depth)
