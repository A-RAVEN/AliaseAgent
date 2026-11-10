# Agent Config — Spec

## Purpose

规定「每个 Agent Type 能收什么模态」。`input_modalities` 是"这个模型能不能收图"的唯一真相来源：缺省按只有 `text` 处理（宁可少发图，也不让模型悄悄看不见），非法值回落成 `["text"]` 并打一行日志点名原始值，保存时要原样写回。

## Requirements

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

Each provider entry in the configuration SHALL include `api_key` (required) and `base_url` (optional, defaults to provider's standard API endpoint; stored value SHALL be the normalized form produced by the Providers management page). Each provider entry MAY include `models` (array of model catalog entries written by model discovery) and `discovered_at` (UTC ISO 8601 timestamp of the last successful discovery). When `models` or `discovered_at` is absent the provider SHALL read as an empty catalog never discovered. When `models` is present but not an array, the whole field SHALL fall back to the empty catalog with one log line naming the raw value (a non-array has no entries to fall back per entry); when it is an array, entries without a string `id` SHALL be dropped per item with one log line each, consistent with the `input_modalities` fallback style, and `toJson` SHALL write both keys back so they are discoverable in `~/.aliasagent/config.json`.

#### Scenario: Read provider config

- **WHEN** the Anthropic provider is defined with `api_key` and `base_url`
- **THEN** the runtime resolves that provider's API key and endpoint for any Agent Type referencing it

#### Scenario: Missing API key

- **WHEN** an Agent Type references a provider that has no `api_key`
- **THEN** the system SHALL display an error at startup indicating which provider is missing credentials

#### Scenario: Legacy provider entry without catalog keys

- **WHEN** a provider entry has only `api_key` and `base_url` (written by an older version)
- **THEN** it loads with an empty model catalog and `discovered_at` absent, and all existing behavior is unchanged

#### Scenario: Malformed catalog entry falls back per item

- **WHEN** a provider's `models` array contains an entry without a string `id`
- **THEN** that entry is dropped with one log line naming the raw value, the remaining entries load, and serialization writes the surviving catalog back

### Requirement: Agent Type definition
Each Agent Type entry in the configuration SHALL include `provider` (reference to a defined provider), `model` (string), `system_prompt` (string), and `tools` (list of tool name strings).

#### Scenario: Agent Type loaded
- **WHEN** the "general" Agent Type is defined with provider "anthropic", model "claude-sonnet-4-6", system prompt, and tools ["read_file", "list_dir"]
- **THEN** the General Agent Type is available for use in conversations

#### Scenario: Agent Type references unknown provider
- **WHEN** an Agent Type references a provider name not defined in `providers`
- **THEN** the system SHALL display a configuration error at startup

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

### Requirement: Provider extensibility
The configuration file structure SHALL support adding new providers by adding entries under `providers`, without code changes.

#### Scenario: Adding a new provider
- **WHEN** user adds an "openai" entry with api_key in the config file
- **THEN** the provider is available for Agent Types to reference (even if runtime adapter not yet implemented for API calls)

### Requirement: Thinking effort in Agent Type config

Each Agent Type entry in the configuration MAY include an optional `thinking_effort` field (string). When set to one of the whitelist efforts defined by `AgentConfigResolver.kThinkingEfforts` (`"low"`, `"medium"`, `"high"`, `"xhigh"`, `"max"` — the list lives in code and this spec references it, never re-enumerates a second copy), adaptive extended thinking SHALL be enabled for that agent type with exactly that effort, and the explicit value SHALL take priority over any catalog-derived default. When absent, the default effort SHALL be derived from the provider catalog per the 「缺省思考强度的推导」 requirement below. When set to any non-whitelist value, extended thinking SHALL be disabled (unchanged legacy behavior).

#### Scenario: Thinking enabled with explicit effort level
- **WHEN** the "general" Agent Type is defined with `thinking_effort: "high"`
- **THEN** adaptive thinking is enabled with high effort, regardless of catalog defaults

#### Scenario: Thinking derived when absent
- **WHEN** an Agent Type does not include `thinking_effort` and its model's catalog entry lists reasoning efforts
- **THEN** the default effort is the middle entry of the catalog's non-`none` whitelist efforts ordered by `kThinkingEfforts` (e.g. flash's low/high/max → high; qwen's low/medium/xhigh → medium)

#### Scenario: Thinking disabled (catalog without reasoning)
- **WHEN** an Agent Type does not include `thinking_effort` and its model's catalog entry has no reasoning efforts (or the provider was never probed)
- **THEN** extended thinking is disabled

#### Scenario: Thinking disabled (unrecognized value)
- **WHEN** an Agent Type has `thinking_effort: "unknown"` or any non-whitelist value
- **THEN** extended thinking is disabled (same as absent-without-catalog)
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

### Requirement: 生效上下文窗口的解析顺序

Agent 的生效上下文窗口 SHALL 只有一个事实来源：所属 Provider 当前目录里该模型条目的 `context_window`（持久化目录键名，网关响应里的 `context_length` 只在探测入库时映射到它）。解析规则（单点收拢，全部消费方读解析结果）：目录值存在且为正 ⇒ **一律以目录为准**；目录缺失（Provider 未探测 / 目录无此模型 / 值非正）⇒ 用配置键 `agent_types.<名字>.max_context_tokens` 的正整数覆盖值；两者都没有 ⇒ **显式失败**——创建 Agent 时报错，消息点名模板名并给出两条出路（去 Providers 页探测该 Provider 的目录；或在配置里写正整数覆盖），**SHALL NOT 回落到任何写死的窗口数字**。覆盖值与目录值不一致时 SHALL 打一行日志点名被忽略的覆盖值。压缩阈值与等待上界只消费解析结果，公式（百分比派生）SHALL NOT 改动；窗口在 Agent 实例创建时解析一次，运行实例 SHALL NOT 随目录刷新改变窗口。

#### Scenario: 目录有正数窗口时以目录为准
- **WHEN** 模型在所属 Provider 当前目录里且 `context_window` 为正整数，无论配置是否带 `max_context_tokens`
- **THEN** 生效窗口等于目录值，覆盖值（若有）被忽略并打一行日志

#### Scenario: 目录缺失时用覆盖值
- **WHEN** 该 Provider 尚未探测、或目录里没有该模型、或目录窗口非正，且配置带正整数 `max_context_tokens`
- **THEN** 生效窗口等于覆盖值，创建正常

#### Scenario: 双缺显式失败
- **WHEN** 目录无可用值且配置没有合法覆盖（缺键、非正数）
- **THEN** 创建 Agent 失败，错误消息点名模板名并写明两条出路，不发生任何数字回落

### Requirement: 缺省思考强度的推导

配置缺 `thinking_effort` 键时，思考模式 SHALL 按"显式键 > 目录推导 > `disabled`"解析。目录推导的谓词（可判定、无布尔字段）：该模型目录条目的 `reasoningEfforts` 非空且含 `none` 之外的 `kThinkingEfforts` 白名单档。谓词成立 ⇒ 缺省强度 = 这些档按 `kThinkingEfforts` 顺序取**中间档**（2026-11-09 用户拍板「缺省值给中间档」；取目录中间档而非字面 `medium`，因为部分模型目录不含 `medium`，硬发会被上游映射成其它档、造成双重口径）。谓词不成立（`reasoningEfforts` 为空 / 全 `none` / 目录缺失）⇒ `disabled`。显式白名单档永远优先。产品代码 SHALL NOT 把任何固定档位写死为唯一缺省。

#### Scenario: 支持推理的模型取目录中间档
- **WHEN** 配置没有 `thinking_effort` 键，目录条目 `reasoningEfforts` 为 [low, high, max]（flash）
- **THEN** 生效强度为 high（三档中间档），思考模式 adaptive

#### Scenario: 声明 medium 的模型真的取 medium
- **WHEN** 目录条目 `reasoningEfforts` 为 [low, medium, xhigh]（qwen）
- **THEN** 缺省强度为 medium

#### Scenario: 无推理能力或目录缺失保持关闭
- **WHEN** 配置没有该键，且 `reasoningEfforts` 为空、全 `none`，或该 Provider 尚未探测
- **THEN** 生效思考模式为 disabled

#### Scenario: 显式档位永远优先
- **WHEN** 配置写着 `"thinking_effort": "xhigh"`，目录声明支持推理
- **THEN** 生效强度为 xhigh（显式优先于目录中间档）
