## Context

AliasAgent(Flutter 桌面 AI 对话应用,经 dart:ffi 调 C++ Sidecar,走 DeepSeek Anthropic 兼容端点)目前**对上下文无任何管理**:`_buildApiMessages`(lib/main.dart:1077-1149)把会话全量拼进 `apiMessages`,`_callModel`(main.dart:689)原样发给 sidecar;`model_gateway.cpp:500` 透传 `body["messages"]`。无截断、无压缩、无预算。

同时**零 token 度量**:`Message.token_count` 列存在(database_service.dart:42/:92)但**无 writer**;`OnDoneCallback(int, const char*, const char*)`(sidecar_api.h:46)**不带 usage**;SSE `message_start`/`message_delta`(AnthropicAPIDoc.md:354/:372)只被 LOG_TRACE(model_gateway.cpp:278-280)。

设计依据:本 change 全部技术决策固化于 `Docs/context-compression-reference.md`(含 6 视角对抗评审 + 6-claim N≥3 对抗验证 + 外部实现证据,含 Claude Code 参照 §5.4)。方案方向经对抗验证:6 条核心 claim 中 C2 SURVIVED、其余 5 条被 KILLED 后的**真缺陷均已修正**回写(见参考文档 §8)。

约束:CLAUDE.md 规定测试可观测性、不修改验收标准、无 user-in-the-loop 任务、对抗式 Workflow 诚实循环;DeepSeek 端点,严禁借 Anthropic 行为;usage 字段名随端点——Anthropic-format `/v1/messages` 用 `input_tokens`/`output_tokens`([UNVERIFIED],AnthropicAPIDoc.md:354/:372),`prompt_tokens`/`completion_tokens`(DeepSeekAPIDoc.md:661)是 chat/completions 字段,不适用于 `/v1/messages`。

## Goals / Non-Goals

**Goals:**
- 持续、自动地把发给模型的上下文维持在安全范围,无需手动 `/compact` 指令。
- 层级化压缩:近端原文、中端段总结、远端总结之总结;原始对话**无损留盘**(树是派生索引)。
- 通过接口**实测 usage**(Anthropic-format `/v1/messages` 的 `input_tokens`/`output_tokens`,[UNVERIFIED])驱动触发;上限为 per-agent-type 必填配置 `maxContextTokens`。
- 决策/执行分离保证**可测确定性**。

**Non-Goals:**
- 不提供手动压缩指令、不新增持续的"压缩管理"操作(仅一次性必填配置 `maxContextTokens`,同 apiKey)。
- 不做向量/嵌入检索式长记忆(无 embedding 基建;是远未来)。
- 不修改任何既有测试/验收标准来迁就实现。
- 不追求摘要内容可与原文逐字核对(摘要本质有损;靠"保留决策 + 再执行钥匙 + 原文可 re-expand"兜底)。

## Decisions

**D1 压缩形态 = 层级化摘要树 + recency 梯度**(非单一滚动摘要 / 非滑窗截断)。
- 理由:对数成本、粒度梯度(近详远略)、远端"总结之总结"保留决策链;外部 remnic LCM / hierarchical-context-ai-agent 验证。
- 备选:单一滚动总结(简单但 O(N) 重写、粒度差)、滑窗截断(破坏完整性/丢失再执行钥匙)。

**D2 摘要 role 用 `user`,不塞 system**(参照 Claude Code §5.4)。
- 顶层 `system` 留作真指令;摘要 = role:user 文本 + 正文标记(`## 更早上下文(压缩xN,非用户发言)`)。DeepSeek `name` 字段(DeepSeekAPIDoc.md:221)是 **chat/completions** 消息字段,`/v1/messages` 未验证——故**首选正文文本标记**,不依赖 `name:'history'`。
- 备选:摘要进 system(污染真指令)、发明 role("history" 非合法 role)。

**D3 触发预算 = 必填配置 `maxContextTokens` + 实测 usage**(非查精确窗口、非隐藏默认)。
- 接口拿不到精确窗口(无 `/models` 元数据);DeepSeek `/v1/messages`(Anthropic 格式)usage 字段为 `input_tokens`/`output_tokens`(AnthropicAPIDoc.md:354/:372),**但 [UNVERIFIED] 待从 DeepSeek 官方 Anthropic 兼容文档核实**;侧车应**防御性解析 usage 块**(读端点实际返回的 token-count 字段);`prompt_tokens`(:661)是 chat/completions 字段,不适用于 `/v1/messages`。
- 必填(同 apiKey);`stop_reason: length` 不作触发(:328 语义含糊)。

**D4 确定性:决策/执行分离 `buildTree(history, config, proxy_usage)` 纯函数 + `FakeSummarizer` seam**。
- **"哪些段该折 + 预算 + cover 拓扑"是纯函数**(确定性);LLM 只填"已定死叶子"的内容,不改变这些。**唯一的 LLM 影响树形点 = 边界缝(见 D5),被 memo 化约束为可复现**。测试断言树形/预算/耦合/边界,不断言措辞;后台物化 = 幂等缓存,materialize == buildTree。

**D5 语义边界选 A(LLM 在安全候选点挑话题缝),memo 化保可复现**。
- 结构安全切点可能拆开话题簇;A 把边界选择嵌入同一次摘要调用(边际成本小),memo 化(内容哈希 keyed)让重建/测试可复现。**它是"纯函数折叠计划"的唯一例外(只影响缝,不改'折哪些段'),且被 memo 化**。
- 备选:C(结构切+recency 兜底,简单但保留接缝丢细节)。

**D-guard 不变量守卫(用户目标/验收标准/不变量永不塌缩)**。
- 用户目标、验收标准、"don't touch X" 不变量被 pin 为**不可压缩锚点**,每轮重注入(system 或消息头部),无论多旧都不塌缩。锚点集合**有界、去重、可失效**(随用户撤销需求淘汰);来源为**显式 standing-requirements 机制**(非 LLM 从 prose 抽取,temp=1 非确定)。这与 CLAUDE.md"禁止改验收标准"呼应。

**D6 折叠原子单元 = 完整工具轮 + 段边界规则 + node_type 门控**。
- 原子单元 = 带 tool_calls 的 assistant 消息 + 紧随其后的合成 user(tool_result)(main.dart:1125-1147);绝不拆开。
- 段边界只落(a)真实用户文本 / (b)无 tool_use 的 assistant 终答;绝不落带 tool_calls 的行。
- 带 tool_calls 的叶子**永原样展开(node_type)**,无论多旧(近端超大 `tool_result` **正文**可按 Near-zone elision requirement 裁为"标记+再取记录",轮结构/工具对不变);纯文本输出,不合成 thinking/tool_use/tool_result 块(DeepSeekAPIDoc.md:199 等正确理由)。

**D7 压缩调用复用 `model_gateway`,用"摘要 profile"(关 thinking、`max_tokens` 512-1024、可选更便宜模型)**。
- 同一 `/v1/messages` 端点,末端 user 消息追加 summarize 指令(参照 Claude Code `querySource:'compact'`)。

**D8 后台折卷 idle-gated + 可抢占(request-id 定向)+ 断点续 + 事务原子落库**。
- 单槽(模型路径);折卷与用户请求轮换共享、用户优先;`summary_nodes` 表事务写 + `tree_version` 递增(dirty-seq 标记失效,lazy 重折);materialize == buildTree。
- 注意:串行化的**只是模型路径**,web_search/web_fetch 在独立 worker isolate(不可与用户模型请求并发但工具/网络路径未被门控)。

**D9 存储:seq 全序 + `summary_nodes` 树 + 派生索引**。
- `messages` 加 `seq INTEGER`(autoincrement)+ `(session_id, seq)` 索引;树边界用 `(session_id, start_seq, end_seq)`,不用 UUID。
- `summary_nodes`:(session_id, level, start_seq, end_seq, node_type, parent_id, summary_json, token_cost, summary_prompt_version, model, covered_min_seq, covered_max_seq);`summary_json`(role blocks)非单段 text;covered_min/max 稠密非重叠 + `leaf_owner` 平面索引;parent_id 仅导航;memo 化摘要(content hash + prompt version + model)。
- 原始 `messages` 表逐字保留;树节点按需展开路径由 harness 注入(非 agent 工具)。

**D10 便宜层优先 + 折卷预算**。
- 先用 DeepSeek prompt-caching(user_id,:241)+ **对远端采用"已存在的更粗摘要层"**(不是直接裁剪、不丢决策/再执行钥匙)作为便宜层;近端超大 `tool_result` **正文**(非工具对)允许轮内裁剪为"截断标记 + 再取记录"(保住 tool_use 块与工具对,不折叠该轮);LLM 树仅长会话升级。每会话折卷次数/token 上限 + 破平衡点回归(折卷 input ≪ 每请求省下 input)。

## Risks / Trade-offs

- [压缩本质有损] → 摘要保留决策/结论 + 再执行钥匙(tool_input 原文/绝对路径)+ 原文留盘可 re-expand;live 连续性测试 + 对抗审查兜底。
- [tool_use/tool_result 拆分导致 API 400] → 原子单元 + 边界规则 + node_type 门控 + 工具对完整属性测试。
- [单槽折卷卡用户 / 抢占误杀用户请求] → request-id 定向 cancel + `_chain` 空时入队 + 断点续;折卷绝不进入用户关键路径。
- [非确定摘要破坏测试确定性] → 决策/执行分离 + FakeSummarizer + memo 化;断言树形不断言措辞。
- [边界拆话题(语义)] → A 方案 LLM 挑话题缝,memo 化保确定性;测试注 FakeSummarizer 固定边界。
- [预算锚点不可验证] → 必填 `maxContextTokens` + 实测 usage;未授权时不借 Anthropic 数字;已知精确窗口仅让用户填得更准(可选)。
- [旧库迁移 / 同毫秒排序] → seq 回填 best-effort;不给旧数据预建 rollup;schema 镜像 `openAt`;迁移测试。
- [web_search/web_fetch 未被单槽门控] → 折卷只走模型路径;工具/网络路径的记录处理按 §3.2(web_fetch/web_search 不视为幂等读轮)。

## Migration Plan

1. **schema v3→v4**:`messages` 加 `seq INTEGER`(backfill by created_at+rowid,best-effort)+ `(session_id, seq)` 索引;新增 `summary_nodes` 表;新增每会话 `tree_version`。**不给旧数据预建 rollup**(旧消息作未压缩叶子,惰性向前建高水位);schema 镜像到 `openAt`(database_service.dart:69-111);补 v3→v4 迁移测试。
2. **Phase 0 先行**:usage 遥测(解析 `/v1/messages` 的 `message_start`/`message_delta` usage → 新 FFI 回调 → `token_count`)+ seq 列 + 必填 `maxContextTokens` 配置。此阶段无压缩行为变化。
3. **配置迁移**:首次启动设置对话框增加 `maxContextTokens` 必填项(同 apiKey 引导)。
4. **回滚**:停用压缩(不建压缩树、直接全量)即回到现行为;树是派生索引,删除 `summary_nodes`/`tree_version` 即回到无压缩(原始 `messages` 仍在)。

## Open Questions

- 语义边界 A 的 memo 键 / 是否复用同一摘要调用(实现层,我把关;见参考文档 §8 D1/D2/D3 已降级为实现细节)。
- DeepSeek `/v1/messages`(Anthropic 兼容)的 usage 精确字段名(Anthropic 格式 `input_tokens`/`output_tokens`)待核实;`prompt_tokens` 是 chat/completions 字段。精确窗口数(可选优化,不做前置;用户授权时从官方核实)。
- 摘要是否要"意图叙述"还是纯结构化记录(tool_input/outcome/refetch_hint 是数据,可纯机械;叙述部分可选)。
