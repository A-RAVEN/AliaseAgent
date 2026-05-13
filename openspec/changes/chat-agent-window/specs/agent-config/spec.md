# Agent Config — Spec

## ADDED Requirements

### Requirement: Provider configuration file
The system SHALL read provider and agent type configuration from `~/.aliasagent/config.json` at startup. The file SHALL use JSON format with `version`, `providers`, and `agent_types` sections.

#### Scenario: Config file exists and valid
- **WHEN** the app starts and `config.json` exists with valid structure
- **THEN** providers and agent types are loaded into the runtime registry

#### Scenario: Config file does not exist
- **WHEN** the app starts and `config.json` does not exist
- **THEN** the app prompts the user to enter an API key via a setup dialog, then creates the config file

#### Scenario: Config file malformed
- **WHEN** the app starts and `config.json` contains invalid JSON
- **THEN** the app displays an error with the file path and problem description

### Requirement: Provider definition
Each provider entry in the configuration SHALL include `api_key` (required) and `base_url` (optional, defaults to provider's standard API endpoint).

#### Scenario: Read provider config
- **WHEN** the Anthropic provider is defined with `api_key` and `base_url`
- **THEN** the runtime resolves that provider's API key and endpoint for any Agent Type referencing it

#### Scenario: Missing API key
- **WHEN** an Agent Type references a provider that has no `api_key`
- **THEN** the system SHALL display an error at startup indicating which provider is missing credentials

### Requirement: Agent Type definition
Each Agent Type entry in the configuration SHALL include `provider` (reference to a defined provider), `model` (string), `system_prompt` (string), and `tools` (list of tool name strings).

#### Scenario: Agent Type loaded
- **WHEN** the "general" Agent Type is defined with provider "anthropic", model "claude-sonnet-4-6", system prompt, and tools ["read_file", "list_dir"]
- **THEN** the General Agent Type is available for use in conversations

#### Scenario: Agent Type references unknown provider
- **WHEN** an Agent Type references a provider name not defined in `providers`
- **THEN** the system SHALL display a configuration error at startup

### Requirement: Agent Type registry
The system SHALL maintain an in-memory registry of all loaded Agent Types, accessible by name. The registry SHALL support lookup, listing, and iteration.

#### Scenario: Lookup existing type
- **WHEN** the registry is queried for "general"
- **THEN** the corresponding AgentTypeConfig is returned

#### Scenario: Lookup non-existent type
- **WHEN** the registry is queried for a name not registered
- **THEN** null/None is returned

### Requirement: Provider extensibility
The configuration file structure SHALL support adding new providers by adding entries under `providers`, without code changes.

#### Scenario: Adding a new provider
- **WHEN** user adds an "openai" entry with api_key in the config file
- **THEN** the provider is available for Agent Types to reference (even if runtime adapter not yet implemented for API calls)