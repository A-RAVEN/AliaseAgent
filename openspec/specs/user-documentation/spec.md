# user-documentation Specification

## Purpose
Give a reader who has not read the code a way to use every feature the application exposes: what the feature is, where it lives in the UI, how to operate it, what it costs or requires, what the user sees when it fails, and what it cannot do. Two rules keep those documents from rotting: `README.md` indexes every usage document under `Docs/user-guide/` (and the index and the directory agree in both directions), and the names the documents use — configuration keys of `~/.aliasagent/config.json`, tool names — must exist in the product code. Both directions are checked by `test/unit/user_docs_test.dart`; whether a sentence describes the behaviour accurately is not machine-checkable and stays a review duty.
## Requirements
### Requirement: User-facing documentation exists for every user-facing feature

The repository SHALL provide, for every feature a user of the application can reach (the conversation UI, the real-context view, context compaction, the file tools, the web tools, the browser tools, the command tool, configuration, and common trouble symptoms), a usage document under `Docs/user-guide/<feature>.md` written in Chinese for someone who has not read the code. Each such document SHALL cover: what the feature is, where it is used, how to operate it, the parameters or configuration it takes, what the user sees when it fails, and its known limits. No usage document SHALL describe behaviour the code does not have.

#### Scenario: Every user-facing feature has a usage document

- **WHEN** the set of features reachable in the application is compared against the documents under `Docs/user-guide/`
- **THEN** each feature SHALL have exactly one document, and the document SHALL cover the six items listed above (what it is, where, how, parameters, failure symptoms, limits)

#### Scenario: Tools are documented as model-invoked, not user-clicked

- **WHEN** a usage document describes a tool the model calls (`read_file`, `write_file`, `edit_file`, `list_dir`, `glob_file`, `grep_file`, `get_current_time`, `web_search`, `web_fetch`, `browser_navigate`, `browser_click`, `browser_type`, `browser_snapshot`, `run_command`)
- **THEN** the document SHALL state, before describing the tool, that the model invokes it on the user's behalf and the user does not call it directly

#### Scenario: The file tools' workspace boundary is stated

- **WHEN** a usage document describes a file tool
- **THEN** it SHALL state that paths are resolved inside the workspace, that the workspace is the user's home directory, and that a path outside it is refused with an error rather than silently accepted

#### Scenario: The command tool's real effects are stated

- **WHEN** a usage document describes `run_command`
- **THEN** it SHALL state that the command really runs on this machine with the user's own permissions, that it can modify files under the workspace, that it is not sandboxed, and that a running command cannot be approved or undone after the fact

### Requirement: The README indexes the usage documents

`README.md` SHALL contain a section that lists every usage document with a one-line description of what its feature does and a link to it, so that a reader can reach any feature's documentation from the repository entry point.

#### Scenario: The index and the directory agree in both directions

- **WHEN** `README.md` and the contents of `Docs/user-guide/` are compared
- **THEN** every document file SHALL be linked from the README index, and every file linked from the README index SHALL exist — a document present in the directory but absent from the index, or an index entry pointing at a missing file, SHALL be a failure

### Requirement: Names used in the documentation are checkable against the code

Configuration keys and tool names that appear in the usage documents SHALL be verifiable against the product code, so that a document cannot describe a key or a tool that does not exist.

#### Scenario: Configuration keys exist in the parsing path

- **WHEN** a usage document mentions a key of `~/.aliasagent/config.json` (for example `api_key`, `base_url`, `provider`, `model`, `system_prompt`, `tools`, `max_context_tokens`, `thinking_effort`, `standing_requirements`, `compaction_threshold_percent`, `command_timeout_ms`, `command_max_timeout_ms`, `command_max_output_chars`, `command_output_full_chars`)
- **THEN** that key SHALL be found in the product code's configuration parsing path (`AgentTypeConfig` / `ProviderConfig` / `ConfigService`), and a key that cannot be found there SHALL be a failure

#### Scenario: Tool names exist in the registered tool list

- **WHEN** a usage document names a tool
- **THEN** that name SHALL be found in the tool definitions the application registers, and a name that cannot be found there SHALL be a failure

