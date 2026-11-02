## MODIFIED Requirements

### Requirement: File edit tools always available

The `write_file` and `edit_file` tools SHALL be available independently of search-provider configuration. They SHALL be registered for an Agent when that Agent's resolved configuration includes them, alongside the other file tools allowed by that configuration; they SHALL NOT be sent to an Agent whose resolved configuration excludes them.

#### Scenario: Tools available without search providers
- **WHEN** no search providers are configured and an Agent's resolved configuration includes `write_file` and `edit_file`
- **THEN** `write_file` and `edit_file` SHALL still appear in the tool definitions sent to the AI

#### Scenario: Tools excluded by an Agent template
- **WHEN** an Agent's resolved configuration excludes `write_file` or `edit_file`
- **THEN** the excluded tool SHALL NOT appear in that Agent's tool definitions, without affecting other Agents that allow it
