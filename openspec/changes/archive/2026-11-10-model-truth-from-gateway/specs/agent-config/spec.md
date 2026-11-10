# agent-config 能力（delta）

## MODIFIED Requirements

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

## ADDED Requirements

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
