## MODIFIED Requirements

### Requirement: Provider definition

Each provider entry in the configuration SHALL include `api_key` (required) and `base_url` (optional, defaults to provider's standard API endpoint; stored value SHALL be the normalized form produced by the Providers management page). Each provider entry MAY include `models` (array of model catalog entries written by model discovery) and `discovered_at` (UTC ISO 8601 timestamp of the last successful discovery). When `models` or `discovered_at` is absent the provider SHALL read as an empty catalog never discovered. When `models` is present but not an array, the whole field SHALL fall back to the empty catalog with one log line naming the raw value (a non-array has no entries to fall back per entry); when it is an array, entries without a string `id` SHALL be dropped per item with one log line each, consistent with the `input_modalities` fallback style, and `toJson` SHALL write both keys back so they are discoverable in `~/.aliasagent/config.json`.

#### Scenario: Read provider config

- **WHEN** the Anthropic provider is defined with `api_key` and `base_url`
- **THEN** the runtime resolves that provider's API key and endpoint for any Agent Type referencing it

#### Scenario: Missing API key

- **WHEN** an Agent Type references a provider that has no `api_key`
- **THEN** the system SHALL display an error at startup indicating which provider is missing credentials

#### Scenario: Legacy provider entry without catalog keys

- **WHEN** a provider entry has only `api_key` and `base_url` (written by an older version)
- **THEN** it loads with an empty model catalog and `discovered_at` absent, and all existing behavior is unchanged

#### Scenario: Malformed catalog entry falls back per item

- **WHEN** a provider's `models` array contains an entry without a string `id`
- **THEN** that entry is dropped with one log line naming the raw value, the remaining entries load, and serialization writes the surviving catalog back
