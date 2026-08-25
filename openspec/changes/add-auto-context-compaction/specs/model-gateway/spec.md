# Model Gateway — Spec (delta)

## ADDED Requirements

### Requirement: Usage telemetry
The C++ Sidecar SHALL parse usage from the SSE `message_start` and `message_delta` events on the Anthropic-format `/v1/messages` endpoint and surface the measured input/output token counts to Dart. Field names follow the Anthropic `/v1/messages` usage format: `input_tokens` (message_start) and `output_tokens` (message_delta); the exact DeepSeek field naming is **[UNVERIFIED]** and must be verified from official DeepSeek Anthropic-compat docs before finalizing, so the sidecar SHALL parse the usage block defensively (read whichever token-count field the endpoint returns). (`prompt_tokens`/`completion_tokens` are the DeepSeek chat/completions fields and do NOT apply to the `/v1/messages` endpoint.) The scenarios below use the Anthropic-format names `input_tokens`/`output_tokens` illustratively, subject to this [UNVERIFIED] note.

#### Scenario: Input usage surfaced
- **WHEN** the SSE stream contains `message_start` with a usage block
- **THEN** the sidecar parses and forwards the measured input token count (`input_tokens`) to Dart

#### Scenario: Output usage surfaced
- **WHEN** the SSE stream contains `message_delta` with a usage block
- **THEN** the sidecar forwards the measured output token count (`output_tokens`) to Dart

## MODIFIED Requirements

### Requirement: Adaptive thinking parameter in request body
The C++ Sidecar SHALL conditionally include adaptive thinking configuration in the API request body based on the `thinking_mode` and `thinking_effort` parameters. When `thinking_mode` is `"adaptive"`, the body SHALL contain `"thinking":{"type":"adaptive","display":"summarized"}` and `"output_config":{"effort":"<level>"}`, and `max_tokens` SHALL be set to 16000. When `thinking_mode` is not `"adaptive"` or is empty, no thinking or output_config fields SHALL be included and `max_tokens` SHALL remain at 4096. **Modified: when a summary-profile request is used (thinking disabled for summarization), `max_tokens` SHALL be 512-1024 instead of 4096.**

**External validation (official docs, verified 2026-08-02 via MCP webReader)**:
- DeepSeek Anthropic-compatible endpoint (https://api-docs.deepseek.com/guides/anthropic_api/): "thinking | Supported (`budget_tokens` is ignored)" and "output_config | Only `effort` is supported" — the ONLY effective thinking control is `output_config.effort`; `budgetTokens`/`budget_tokens` is ignored by the API.
- Anthropic extended thinking (https://platform.claude.com/docs/en/build-with-claude/extended-thinking): `thinking.type="adaptive"` with `display` and `output_config.effort`.
- `display:"summarized"` ensures visible thinking text on models where the default is `"omitted"` (empty thinking field).

#### Scenario: Adaptive thinking enabled
- **WHEN** `send_message` receives `thinking_mode = "adaptive"` and `thinking_effort = "high"`
- **THEN** the request JSON body includes `"thinking":{"type":"adaptive","display":"summarized"}`, `"output_config":{"effort":"high"}`, and `"max_tokens":16000`

#### Scenario: Thinking disabled (normal request)
- **WHEN** `send_message` receives `thinking_mode = "disabled"` or empty string (non-summary request)
- **THEN** the request JSON body does NOT contain `thinking` or `output_config` keys, and `"max_tokens":4096`

#### Scenario: Summary profile caps max_tokens
- **WHEN** a summary-profile request is made (thinking disabled for summarization)
- **THEN** `max_tokens` is 512-1024, overriding the 4096 non-adaptive default

#### Scenario: display summarized always set
- **WHEN** adaptive thinking is enabled
- **THEN** `"display":"summarized"` is always included to ensure visible thinking content on Opus 4.7+ models
