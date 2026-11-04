## Purpose

约束首次配置对话框：字段校验、保存路径、错误提示。

## Requirements

### Requirement: Setup dialog renders

The system SHALL render the setup flow as a two-step wizard when no config exists, and SHALL keep the existing follow-up ask (补问) path working: step one collects provider name, gateway base URL and API key (first-run defaults: provider name `magpie`, base URL `http://127.0.0.1:3425`, API key `magpie` — all editable; user decisions 2026-11-04, replacing the old hardcoded `anthropic` default; the magpie gateway convention is that the key literal is `magpie`); step two keeps the existing mandatory max-context-tokens input (positive integer) for the `general` template — its absence previously made the dialog re-appear, and that behavior SHALL NOT be dropped. The flow SHALL not be closable before both steps submit successfully (`barrierDismissible: false` semantics preserved), and existing widget assertions on the window field SHALL keep passing.

#### Scenario: Dialog shows on first launch

- **WHEN** the app has no config file and shows the SetupDialog
- **THEN** step one displays a provider name field, a base URL field, and a TextField for API key entry
- **AND** after step one submits, step two displays the max context tokens field
- **AND** a "Start" button completes the wizard only after both steps are valid

#### Scenario: Follow-up ask keeps step one minimal

- **WHEN** an existing config lacks `general.max_context_tokens` and the wizard opens
- **THEN** step one writes the key back to the provider the `general` template actually uses (existing merge behavior), and step two collects the window; all other config sections are merged, not overwritten

### Requirement: Setup dialog validates input

The system SHALL not allow submission with an empty API key, and SHALL validate: the provider name is non-empty and unique in `providers`; the base URL parses as an absolute http(s) URL; and (step two) the max context tokens is a positive integer. A failed check SHALL name the offending field and preserve the user's other input.

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

### Requirement: Setup dialog creates config on valid submit

The system SHALL call the onComplete callback when the wizard completes, saving a config whose `providers` contains an entry under the submitted name with the normalized base URL (trailing `/v1` and `/` stripped) and whose `general` template carries the step-two `max_context_tokens`.

#### Scenario: Valid provider and window submitted

- **WHEN** user enters a non-empty provider name, a valid base URL, an API key, and a positive integer window, then taps Start
- **THEN** the onComplete callback is invoked
- **AND** ConfigService.save() is called with a config containing `providers.<name>` (entered key, normalized base URL) and `general.max_context_tokens` equal to the entered window

### Requirement: Setup dialog is non-dismissible
The system SHALL prevent dismissing the setup dialog by tapping outside (barrierDismissible: false).

#### Scenario: Cannot dismiss by tapping outside
- **WHEN** the setup dialog is displayed via showDialog with barrierDismissible: false
- **THEN** tapping outside the dialog does not close it
