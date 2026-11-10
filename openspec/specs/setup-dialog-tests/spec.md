## Purpose

约束首次配置对话框：字段校验、保存路径、错误提示。

## Requirements

### Requirement: Setup dialog renders

The system SHALL render the setup flow as a two-step wizard when no config exists. Step one collects provider name, gateway base URL and API key (first-run defaults: provider name `magpie`, base URL `http://127.0.0.1:3425`, API key `magpie` — all editable; user decisions 2026-11-04). Step two performs a provider catalog probe and, on success, shows a model dropdown defaulting to the **first catalog entry**; there is deliberately **no max-context-tokens field** (the window comes from the probed catalog at runtime — see `agent-config` 的「生效上下文窗口的解析顺序」). The model dropdown SHALL be backed by the probed catalog entries (`display_name` shown, model id saved). The flow SHALL not be closable before both steps submit successfully (`barrierDismissible: false` semantics preserved). Absence of `max_context_tokens` in an existing config is a legal state and SHALL NOT by itself make the dialog appear (change `model-truth-from-gateway`; there is no remaining auto re-ask entry in the product — the legacy follow-up ask path is removed by this change).

#### Scenario: Dialog shows on first launch

- **WHEN** the app has no config file and shows the SetupDialog
- **THEN** step one displays a provider name field, a base URL field, and a TextField for API key entry
- **AND** after step one submits, step two performs the catalog probe and then displays a model dropdown defaulting to the first catalog entry
- **AND** no context-window input exists anywhere in the wizard
- **AND** a "Start" button completes the wizard only after both steps are valid

#### Scenario: Probe failure blocks the wizard

- **WHEN** step two's probe fails or returns an empty catalog and the user taps Start
- **THEN** the wizard does not complete and names the probe failure; no config is written

### Requirement: Setup dialog validates input

The system SHALL not allow submission with an empty API key, and SHALL validate: the provider name is non-empty and unique in `providers`; the base URL parses as an absolute http(s) URL; and (step two) the provider probe succeeds and the returned model catalog is non-empty. A failed check SHALL name the offending field and preserve the user's other input. The context-window input step was removed by change `model-truth-from-gateway` — there is no window field to validate and absence of `max_context_tokens` in an existing config is a legal state that SHALL NOT trigger the setup dialog.

#### Scenario: Empty API key blocked

- **WHEN** the user taps Start with an empty API key field
- **THEN** the dialog does not dismiss
- **AND** a validation error ("Please enter an API key") is shown

#### Scenario: Empty or duplicate provider name blocked

- **WHEN** the user submits with an empty provider name, or a name that already exists in `providers`
- **THEN** submission is rejected with the offending field named and all entered values preserved

#### Scenario: Invalid base URL blocked

- **WHEN** the user submits a base URL that is not an absolute http(s) URL (e.g. `127.0.0.1:3425` without scheme, or `ftp://x`)
- **THEN** submission is rejected naming the base URL field, and no config is written

#### Scenario: Probe failure or empty catalog blocked

- **WHEN** the user taps Start and the provider probe fails or returns an empty model catalog
- **THEN** submission is rejected naming the probe failure, and no config is written

### Requirement: Setup dialog creates config on valid submit

The system SHALL call the onComplete callback when the wizard completes, saving a config whose `providers` contains an entry under the submitted name with the normalized base URL (trailing `/v1` and `/` stripped). The saved `general` template's `model` SHALL equal the selected catalog entry (defaulting to the first entry). The same save SHALL persist the probed catalog into `providers.<名>.models` (entries in `ModelCatalogEntry` shape, window key `context_window`) and set `discovered_at`, so runtime window resolution and stale-model detection have a catalog to read. The saved `general` SHALL NOT carry a `max_context_tokens` key — absence means "derive from the catalog". There is deliberately no hardcoded model id or window length anywhere in the product (change `model-truth-from-gateway`).

#### Scenario: Valid provider and probed catalog submitted

- **WHEN** user enters a non-empty provider name, a valid base URL, an API key, and the probe succeeds with a non-empty catalog, then taps Start
- **THEN** the onComplete callback is invoked
- **AND** ConfigService.save() is called with a config containing `providers.<name>` (entered key, normalized base URL, persisted `models` list and `discovered_at`) and `general.model` equal to the catalog's first entry, and no `max_context_tokens` key under `general`

### Requirement: Setup dialog is non-dismissible
The system SHALL prevent dismissing the setup dialog by tapping outside (barrierDismissible: false).

#### Scenario: Cannot dismiss by tapping outside
- **WHEN** the setup dialog is displayed via showDialog with barrierDismissible: false
- **THEN** tapping outside the dialog does not close it
