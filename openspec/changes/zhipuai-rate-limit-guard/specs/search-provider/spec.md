## MODIFIED Requirements

### Requirement: ZhipuAI search provider
The ZhipuAI search provider SHALL serialize all outgoing requests via a static mutex lock, enforce a 500ms minimum cooldown between HTTP requests (only after actual HTTP was sent, not on early-return errors), and apply exponential backoff on consecutive content moderation (HTTP 400) errors to recover from escalated rate-limit states.

#### Scenario: Rate limit guard prevents request bursts
- **WHEN** multiple `ZhipuAISearch::search()` calls are made in rapid succession from multiple tool invocations
- **THEN** the provider SHALL serialize the requests (mutex lock)
- **AND** enforce a 500ms minimum interval between each HTTP request (cooldown, skipped for 0ms error paths)

#### Scenario: Exponential backoff on content moderation escalation
- **WHEN** ZhipuAI returns HTTP 400 with content moderation error body
- **THEN** the cooldown SHALL double per consecutive such error (500ms → 1s → 2s → 4s)
- **AND** the counter SHALL reset to 0 on any non-moderation response (200, 429, 500)
