## ADDED Requirements

### Requirement: Image input modality in Agent Type config

Each Agent Type entry MAY include an optional `input_modalities` field: an array of strings whose allowed values are `text` and `image`. When absent, illegal (not an array), or containing any value other than `text` / `image`, the whole field SHALL fall back to `["text"]` and one log line SHALL be printed so a typo is not silently ignored. Duplicate values SHALL be ignored.

`input_modalities` SHALL be resolved into the runtime `AgentTypeConfig` and SHALL be the single source of truth for "may this model receive images". `toJson` SHALL always write it back so the knob is discoverable in `~/.aliasagent/config.json`. The setup dialog's generated default config SHALL carry the key.

#### Scenario: Declared with image support
- **WHEN** an Agent Type is configured with `input_modalities: ["text","image"]`
- **THEN** the runtime config reports both modalities and image blocks are allowed into requests for that type

#### Scenario: Absent means text only
- **WHEN** an Agent Type has no `input_modalities` key
- **THEN** the runtime config reports exactly `["text"]`, and no `image` block is ever put into a request for that type

#### Scenario: Illegal value falls back with one log line
- **WHEN** an Agent Type has `input_modalities: "image"` (a string, not an array) or `["text","audio"]`
- **THEN** the runtime config reports `["text"]`, and one line naming `input_modalities` with the raw value is printed

#### Scenario: Written back on save
- **WHEN** an Agent Type is serialized with `toJson`
- **THEN** the output contains the `input_modalities` key with the resolved values
