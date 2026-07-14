## ADDED Requirements

### Requirement: Valid config file
The system SHALL correctly parse a valid config.json and return an AppConfig with providers and agent types populated.

#### Scenario: Config with one provider and one agent type
- **WHEN** config.json contains valid JSON with version, one provider (api_key + base_url), and one agent type
- **THEN** ConfigService.load() returns ConfigStatus.ok with an AppConfig containing the provider and agent type

#### Scenario: Config with multiple providers
- **WHEN** config.json contains multiple providers and agent types
- **THEN** all providers and agent types are loaded into the AppConfig

### Requirement: Missing config file
The system SHALL return ConfigStatus.notFound when config.json does not exist.

#### Scenario: No config file
- **WHEN** the config file path does not exist
- **THEN** ConfigService.load() returns ConfigStatus.notFound

### Requirement: Malformed config file
The system SHALL return ConfigStatus.malformed with an error message when config.json contains invalid JSON or missing nested required fields.

#### Scenario: Invalid JSON syntax
- **WHEN** config.json contains text that is not valid JSON
- **THEN** ConfigService.load() returns ConfigStatus.malformed with error description

#### Scenario: Missing nested required fields
- **WHEN** config.json has valid JSON but a provider entry is missing its `api_key` field (e.g., `{"providers": {"a": {"base_url": "..."}}}`)
- **THEN** ConfigService.load() returns ConfigStatus.malformed with error description

### Requirement: ConfigService supports path injection for testing
The system SHALL accept an optional configPath parameter to enable test isolation.

#### Scenario: Injected config path used in tests
- **WHEN** ConfigService.load(configPath: '/tmp/test_config.json') is called
- **THEN** the specified path is used instead of the default configPath
- **AND** when configPath is omitted, the default `ConfigService.configPath` is used (backward compatible)
