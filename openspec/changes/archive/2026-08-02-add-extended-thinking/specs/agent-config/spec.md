## ADDED Requirements

### Requirement: Thinking effort in Agent Type config
Each Agent Type entry in the configuration MAY include an optional `thinking_effort` field (string). When set to one of `"low"`, `"medium"`, `"high"`, `"xhigh"`, or `"max"`, adaptive extended thinking SHALL be enabled for that agent type. When absent or set to any other value, extended thinking SHALL be disabled.

#### Scenario: Thinking enabled with effort level
- **WHEN** the "general" Agent Type is defined with `thinking_effort: "high"`
- **THEN** adaptive thinking is enabled for conversations using that agent type with high effort

#### Scenario: Thinking disabled (absent)
- **WHEN** an Agent Type does not include `thinking_effort`
- **THEN** extended thinking is disabled for conversations using that agent type

#### Scenario: Thinking disabled (unrecognized value)
- **WHEN** an Agent Type has `thinking_effort: "unknown"` or any non-standard value
- **THEN** extended thinking is disabled (same as absent)
