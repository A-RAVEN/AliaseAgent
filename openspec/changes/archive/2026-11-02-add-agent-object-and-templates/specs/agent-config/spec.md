## MODIFIED Requirements

### Requirement: Agent Type registry

The system SHALL maintain an in-memory registry of all loaded Agent Types, accessible by name. The registry SHALL support lookup, listing, iteration, adding a new type, and updating an existing type without discarding other registered types. Runtime Agent instances SHALL be managed by a separate registry and SHALL NOT be stored as Agent Types. When creating or restoring an Agent, the system SHALL resolve the Agent Type named by that session's `agent_type`; it SHALL NOT always substitute `general`.

#### Scenario: Lookup existing type
- **WHEN** the registry is queried for "general"
- **THEN** the corresponding AgentTypeConfig is returned

#### Scenario: Lookup non-existent type
- **WHEN** the registry is queried for a name not registered
- **THEN** null/None is returned

#### Scenario: Add and update a type
- **WHEN** a new Agent Type is registered or an existing Agent Type is replaced through the template save path
- **THEN** lookup returns the new or updated definition and all other registered Agent Types remain available

#### Scenario: Resolve by owning session
- **WHEN** two sessions name different Agent Types and their Agents are created or restored
- **THEN** each Agent receives the template named by its own session rather than the `general` template

#### Scenario: Missing session template
- **WHEN** a session names an Agent Type that is not registered
- **THEN** Agent creation fails with an error naming that Agent Type and the system does not silently use `general`
