## ADDED Requirements

### Requirement: ZhipuAI requests are serialized with cooldown
The ZhipuAI provider SHALL serialize all outgoing HTTP requests so that only one request is in flight at any time, and SHALL enforce a minimum cooldown between the completion of one request and the start of the next.

#### Scenario: Single request proceeds normally
- **WHEN** `ZhipuAISearch::search()` is called while no other request is in flight
- **THEN** the request SHALL proceed immediately without blocking

#### Scenario: Concurrent requests are serialized
- **WHEN** two worker isolates call `ZhipuAISearch::search()` concurrently
- **THEN** the second call SHALL block until the first call completes and the cooldown expires
- **AND** both calls SHALL eventually complete and return results

#### Scenario: Cooldown enforced between sequential requests
- **WHEN** `ZhipuAISearch::search()` completes a request
- **AND** another call is made less than 500ms after the previous request completed
- **THEN** the new call SHALL sleep until at least 500ms have elapsed since the previous request completed

#### Scenario: No cooldown when no HTTP request was sent
- **WHEN** `ZhipuAISearch::search()` returns early without performing an HTTP request (empty key, empty query, curl_easy_init failure)
- **THEN** no cooldown delay SHALL be applied and the mutex SHALL be released immediately

#### Scenario: No cooldown for first request
- **WHEN** `ZhipuAISearch::search()` is called for the first time
- **THEN** no cooldown delay SHALL be applied

#### Scenario: Exponential backoff on consecutive content moderation errors
- **WHEN** `ZhipuAISearch::search()` receives HTTP 400 with content moderation error ("不安全" / "敏感") in the response body
- **THEN** the cooldown duration SHALL double for each consecutive such error (500ms → 1s → 2s → 4s max)
- **AND** the cooldown SHALL reset to base 500ms on the first successful request (HTTP 200) or non-moderation error (HTTP 429, 500)
