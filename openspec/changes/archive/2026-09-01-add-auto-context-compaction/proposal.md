## Why

AliasAgent 目前把会话**全量**发给模型,且**零 token 度量**:`token_count` 列从未被写入(无 writer),`OnDoneCallback` 不回传 usage,SSE 只在日志里 LOG_TRACE。长会话会撞模型上下文长度限制,导致请求失败或助手"失忆"。需要一个**持续、自动、无手动指令**的上下文压缩机制,把上下文始终维持在安全范围,同时**原始对话无损留盘**。

## What Changes

- **新能力**:上下文自动压缩——层级化摘要树(近端原文、中端段总结、远端总结之总结),原本是派生索引,原始对话不删。
- **请求组装**:`_buildApiMessages` 按压缩树投影(`[system][摘要][近段原文][当前]`),而非全量历史。
- **usage 遥测**:从 `/v1/messages`(Anthropic 格式)SSE `message_start`/`message_delta` 的 usage(`input_tokens`/`output_tokens`,**[UNVERIFIED]**)回传 Dart,写入 `token_count` 列,作触发与校准信号。
- **摘要请求**:复用 `model_gateway` 的摘要 profile(关 thinking、`max_tokens` 512-1024、更便宜模型);同一 `/v1/messages` 端点。
- **配置**:per-agent-type **必填** `maxContextTokens`(一次性设置,同 apiKey);`stop_reason: length` 不作触发信号(语义含糊)。
- **不变量守卫**:用户目标 / 验收标准 / "don't touch X" 不变量**永不塌缩**(pin + 每轮重注入,来源为显式 standing-requirements)。
- **后台折卷**:idle-gated + 可抢占(request-id 定向 cancel)+ 断点续;折卷与用户请求共享单槽、用户优先。
- **不设手动 `/compact` 指令**;用户界面滚动记录不减少。

## Capabilities

### New Capabilities
- `context-compaction`: 层级化自动上下文压缩——分段、折叠(含语义边界 A:LLM 在安全候选点挑话题缝 + memo 化)、预算触发、摘要树、派生索引、后台折卷生命周期、原始对话无损留盘、不可压缩锚点守卫。

### Modified Capabilities
- `model-gateway`: 请求支持压缩后的消息输入;新增"摘要请求 profile"(关 thinking、`max_tokens` 512-1024);`/v1/messages` usage 遥测(`input_tokens`/`output_tokens`,**[UNVERIFIED]**)。
- `ffi-bridge`: 新增 usage(输入/输出 token)FFI 回调(或扩展 `on_done`)回传 Dart。
- `session-persistence`: `messages` 加 `seq`(稳定全序);新 `summary_nodes` 摘要树表;`token_count` 列为真实写入。

## Impact

- `lib/main.dart`: `_buildApiMessages`(按树投影)、`_callModel`(触发预算 + 折卷调度)。
- `lib/services/`: `database_service`(schema v3→v4:seq + summary_nodes + 迁移)、`message_repository`(seq + token_count 写入)、`sidecar_bridge`(usage 回调)。
- `lib/models/`: `message`(seq)、`agent_type_config`(`maxContextTokens` 必填字段)。
- `sidecar/`: `model_gateway`(usage 解析 + summarize profile)、`sidecar_api.h/.cpp`(usage FFI 回调)。
- `Docs/`: `DeepSeekAPIDoc.md`(核实 `/v1/messages` usage 字段)与 `context-compression-reference.md`(设计依据)。
- 测试:新增按 `Docs/TESTING.md` 分层,覆盖 P0-P5(详见 design)。
