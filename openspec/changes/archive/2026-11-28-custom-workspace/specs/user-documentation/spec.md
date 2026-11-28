## MODIFIED Requirements

### Requirement: User-facing documentation exists for every user-facing feature

The repository SHALL provide, for every feature a user of the application can reach (the conversation UI, the real-context view, context compaction, the file tools, the web tools, the browser tools, the command tool, per-session / per-group workspaces, configuration, and common trouble symptoms), a usage document under `Docs/user-guide/<feature>.md` written in Chinese for someone who has not read the code. Each such document SHALL cover: what the feature is, where it is used, how to operate it, the parameters or configuration it takes, what the user sees when it fails, and its known limits. No usage document SHALL describe behaviour the code does not have.

#### Scenario: Every user-facing feature has a usage document

- **WHEN** the set of features reachable in the application is compared against the documents under `Docs/user-guide/`
- **THEN** each feature SHALL have exactly one document, and the document SHALL cover the six items listed above (what it is, where, how, parameters, failure symptoms, limits)

#### Scenario: Tools are documented as model-invoked, not user-clicked

- **WHEN** a usage document describes a tool the model calls (`read_file`, `write_file`, `edit_file`, `list_dir`, `glob_file`, `grep_file`, `get_current_time`, `web_search`, `web_fetch`, `browser_navigate`, `browser_click`, `browser_type`, `browser_snapshot`, `run_command`)
- **THEN** the document SHALL state, before describing the tool, that the model invokes it on the user's behalf and the user does not call it directly

#### Scenario: The file tools' workspace boundary is stated

- **WHEN** a usage document describes a file tool
- **THEN** it SHALL state that paths are resolved inside the workspace, that the workspace is **the user's home directory by default**, that a single chat or a group may switch its workspace to another existing directory, and that a path outside the current workspace is refused with an error rather than silently accepted. It MUST NOT state that the workspace is always the home directory (that is no longer true once a session or group has switched).

#### Scenario: The workspace switch and its browser limit are documented

- **WHEN** a usage document describes how to see or switch the workspace
- **THEN** it SHALL state where the control is for a single chat (near the session title) and for a group (the top of the group's right column / member drawer), that the switch opens an **in-app folder picker** (subfolder list, up / breadcrumb, "select this folder", cancel) backed by the core's `workspace.listDirs`; the user browses and **picks** a directory, and the picker also has an editable path address bar that stays in sync with the shown folder (a typed path is validated by `workspace.listDirs`; an invalid one is reported in place and does not navigate), what error appears when the chosen directory is refused (inside the picker, which stays open), that the picker height is fixed at about 70% of the viewport so it does not jump when navigating, and that this is not the OS folder dialog because the browser cannot hand a local absolute path to the page

#### Scenario: The command tool's real effects are stated

- **WHEN** a usage document describes `run_command`
- **THEN** it SHALL state that the command really runs on this machine with the user's own permissions, that it can modify files under the workspace, that it is not sandboxed, and that a running command cannot be approved or undone after the fact; the workspace MUST NOT be described as a sandbox or a permission boundary for commands
