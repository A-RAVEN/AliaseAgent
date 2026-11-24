# Agent Config — Spec

## Purpose

规定「每个 Agent Type 能收什么模态」。`input_modalities` 是"这个模型能不能收图"的唯一真相来源：缺省按只有 `text` 处理（宁可少发图，也不让模型悄悄看不见），非法值回落成 `["text"]` 并打一行日志点名原始值，保存时要原样写回。

同一份配置文件还承载两类可选字段：模板的**头像覆盖**（`agent_types.<名字>.avatar_path`，决定界面画上传图还是身份图案）与**本机用户资料**（顶层 `profile` 块：用户头像路径、用户标识，以及读取期派生的身份图案种子 `identitySeed`）。两者都只在有值时写回、缺省不新增键；配置读取侧的空串一律读作"没有覆盖"并留一行日志，不当作清除指令。

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

### Requirement: Agent Type 头像字段（`avatar_path`）

Agent Type 条目 MAY 带一个可选的 `avatar_path` 字段（字符串，指向附件目录内一张图片的绝对路径），作为该模板的**头像上传覆盖**。字段缺席时 SHALL 静默读作"没有覆盖"（不打印日志——没有头像的模板是正常状态，不是配置错误）；字段存在但不是字符串、或去掉空白后为空串时 SHALL 读作"没有覆盖"并打印一行日志点名原始值（与 `input_modalities` 的回落风格一致，手误不被静默吞掉）。`toJson` SHALL 只在该字段有值时写回（缺席的模板 MUST NOT 被补上一个空键）。

**这是"读取侧"口径**：配置里的空串一律读作"没有覆盖"，MUST NOT 被当成"清除指令"或写回值。写入侧（`template.save` 的 `avatarPath` 参数）的三态语义见 `agent-template-management` 的「模板菜单支持列表、添加与修改」，两侧终态一致但入口规则不同。

该字段 SHALL NOT 影响模型的请求装配：它只决定界面画哪个头像，MUST NOT 进入系统提示词、工具定义或消息内容。

#### Scenario: 读取带头像的模板

- **WHEN** `agent_types.甲.avatar_path` 是附件目录内一个存在的图片路径
- **THEN** 运行时配置报告该模板有头像覆盖，界面的模板头像、该模板成员与会话头像都用这张图

#### Scenario: 模板没有头像字段

- **WHEN** `agent_types.甲` 没有 `avatar_path` 键
- **THEN** 运行时配置报告该模板没有头像覆盖，界面按实体 id 画身份图案，日志里没有因此产生的告警

#### Scenario: 非法头像值回落并留痕

- **WHEN** `agent_types.甲.avatar_path` 是数字、对象、或空串
- **THEN** 运行时配置报告该模板没有头像覆盖，并有一行日志点名 `avatar_path` 与原始值

#### Scenario: 写回只在有值时

- **WHEN** 分别保存一个有头像与一个没有头像的模板
- **THEN** 有头像的写回带 `avatar_path`，没有头像的写回不带该键（不写空值、不写 `null`）

### Requirement: 用户资料与头像（`profile` 块）

配置文件的顶层 MAY 有一个可选的 `profile` 对象，装**本机用户的资料**：`avatar_path`（用户头像的上传覆盖路径）与 `user_id`（用户标识，用作身份图案的哈希种子）。两者 SHALL 都是字符串；**字段缺席时 SHALL 静默读作"没有该值"（不打印日志——没有资料是正常状态）**；字段存在但不是字符串、或去掉空白后为空串时 SHALL 读作"没有该值"并打印一行日志点名该字段与原始值。与 `avatar_path` 一样，这里的空串是"读取侧"的回落值，不是清除指令；写入侧见 `web-management-ui` 的「用户头像（侧栏入口与 `profile.save`）」。

`profile` 块本身缺席、或不是对象时 SHALL 读作"没有用户资料"（缺席静默、类型不对打一行日志），界面按缺省的常量种子画身份图案。`user_id` 缺席时身份图案的种子 SHALL 取产品的具名常量缺省值——常量 `kDefaultUserSeed = 'local-user'` 定义在 `lib/models/user_profile.dart`；系统 MUST NOT 自动生成、MUST NOT 在保存时凭空写回一个 `user_id`（只有用户显式在配置里写了才有）。

`config.get` 返回的 `profile` SHALL 同时给出**实际生效**的身份图案种子 `identitySeed`（= `user_id` 若存在，否则等于常量缺省值），使客户端不必各自复制这个常量；`identitySeed` 是读取期派生值，MUST NOT 被写进配置文件。

`toJson` SHALL 只在 `avatar_path` 与 `user_id` 至少一项有值时写回 `profile` 块；两者都没有时 MUST NOT 写出该块（旧配置不因升级产生无意义差异）。

保存路径 SHALL 保护该块：只提交 provider 表的 `config.save` MUST NOT 抹掉已存在的 `profile`；写用户头像的 `profile.save` SHALL 整份写回配置，providers / agent_types / search / spill / tool 一律原样保留。

#### Scenario: 读取用户资料

- **WHEN** 配置里 `profile` 为 `{"avatar_path": "<附件目录内一张图>", "user_id": "alice"}`
- **THEN** `config.get` 返回该头像路径、该用户标识与实际生效种子 `alice`，界面上用户消息旁显示这张图

#### Scenario: 没有 profile 块

- **WHEN** 配置里没有 `profile` 键
- **THEN** 用户头像按常量种子画身份图案，`config.get` 返回空的头像路径、空的用户标识与 `identitySeed = "local-user"`，日志没有因此产生的告警

#### Scenario: 非法 profile 或字段回落并留痕

- **WHEN** `profile` 是字符串/数组，或 `profile.avatar_path` 是数字、`profile.user_id` 是空串
- **THEN** 相应值读作"没有该值"，有一行日志点名字段与原始值，其余字段照常解析；`identitySeed` 回落到常量缺省值

#### Scenario: 保存时只写有值的块

- **WHEN** 用户从未设置头像与标识，或清除了头像且没有手写 `user_id`
- **THEN** 写回的配置里没有 `profile` 块（不写空对象、不写空字符串键），也没有凭空写出的 `identitySeed` 键

#### Scenario: 只提交 provider 的保存不抹掉用户资料

- **WHEN** 配置里已有 `profile`，用户在 Provider 页保存一次（该保存只提交 provider 表）
- **THEN** 写回后 `profile` 仍在，头像路径与用户标识逐字不变

#### Scenario: 恢复默认头像清掉键

- **WHEN** 用户对已有头像点「恢复默认」
- **THEN** 写回的配置里 `profile.avatar_path` 不存在，界面回到身份图案；若 `profile` 已无其它值，整个块也不写出
