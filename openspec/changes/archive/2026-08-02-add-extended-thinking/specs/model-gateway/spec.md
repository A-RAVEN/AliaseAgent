## ADDED Requirements

### Requirement: Adaptive thinking parameter in request body
The C++ Sidecar SHALL conditionally include adaptive thinking configuration in the API request body based on the `thinking_mode` and `thinking_effort` parameters. When `thinking_mode` is `"adaptive"`, the body SHALL contain `"thinking":{"type":"adaptive","display":"summarized"}` and `"output_config":{"effort":"<level>"}`, and `max_tokens` SHALL be set to 16000. When `thinking_mode` is not `"adaptive"` or is empty, no thinking or output_config fields SHALL be included and `max_tokens` SHALL remain at 4096.

**External validation (official docs, verified 2026-08-02 via MCP webReader)**:
- DeepSeek Anthropic-compatible endpoint (https://api-docs.deepseek.com/guides/anthropic_api/): "thinking | Supported (`budget_tokens` is ignored)" and "output_config | Only `effort` is supported" — the ONLY effective thinking control is `output_config.effort`; `budgetTokens`/`budget_tokens` is ignored by the API.
- Anthropic extended thinking (https://platform.claude.com/docs/en/build-with-claude/extended-thinking): `thinking.type="adaptive"` with `display` and `output_config.effort`.
- `display:"summarized"` ensures visible thinking text on models where the default is `"omitted"` (empty thinking field).

#### Scenario: Adaptive thinking enabled
- **WHEN** `send_message` receives `thinking_mode = "adaptive"` and `thinking_effort = "high"`
- **THEN** the request JSON body includes `"thinking":{"type":"adaptive","display":"summarized"}`, `"output_config":{"effort":"high"}`, and `"max_tokens":16000`

#### Scenario: Thinking disabled
- **WHEN** `send_message` receives `thinking_mode = "disabled"` or empty string
- **THEN** the request JSON body does NOT contain `thinking` or `output_config` keys, and `"max_tokens":4096`

#### Scenario: display summarized always set
- **WHEN** adaptive thinking is enabled
- **THEN** `"display":"summarized"` is always included to ensure visible thinking content on Opus 4.7+ models
