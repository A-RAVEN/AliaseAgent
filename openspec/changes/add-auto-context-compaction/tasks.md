# Tasks — add-auto-context-compaction

## 1. Phase 0 — 遥测地基(token usage + 全序 + 配置)

- [ ] 1.1 model_gateway 解析 `/v1/messages`(Anthropic 格式)SSE `message_start`/`message_delta` 的 usage,字段名按 Anthropic 格式 `input_tokens`/`output_tokens`(**[UNVERIFIED] 待从 DeepSeek 官方 Anthropic 兼容文档核实**),侧车防御性解析 usage 块(读端点实际返回的 token-count 字段);勿用 chat/completions 的 `prompt_tokens`
- [ ] 1.2 sidecar FFI 新增 usage 回调(或扩展 on_done)把 input/output token 回传 Dart;sidecar_bridge 接收并透传
- [ ] 1.3 insert 时把实测 usage 写入 `Message.token_count`(填补当前无 writer)
- [ ] 1.4 `messages` 加 `seq INTEGER`(autoincrement)+ `(session_id, seq)` 索引;message/model/repository 透传 seq
- [ ] 1.5 `AgentTypeConfig` 加必填 `max_context_tokens`;设置对话框新增必填项(同 apiKey 引导)
- [ ] 1.6 schema v3→v4 迁移:seq + `summary_nodes` 表 + 每会话 `tree_version`;不给旧数据预建 rollup;镜像到 `openAt`;补迁移测试
- [ ] 1.7 测试:usage 回传写库可观测(dump usage 后断言);seq 在同毫秒插入下严格单调;本地 token 估算器确定性

## 2. Phase 1 — 单层平铺 MVP(近段原文 + 一个根总结)

- [ ] 2.1 实现 `buildTree(history, config, proxy_usage)` 纯函数:分段 + 段边界规则 + 预算/cover + 近段原文 + 一个根总结;可注入 `FakeSummarizer`(决策/执行分离)
- [ ] 2.2 原子单元:折叠单元 = 带 tool_calls 的 assistant 消息 + 紧随其后的合成 user(tool_result);段边界只落"真实用户文本 / 无 tool_use 的 assistant 终答",绝不落带 tool_calls 的行
- [ ] 2.3 摘要输出为 role:user 纯文本 + 明显标记(`## 更早上下文(压缩xN,非用户发言)`);不合成 thinking/tool_use/tool_result 块(DeepSeek /v1/messages 客户端侧标记,不依赖 chat/completions 的 `name` 字段)
- [ ] 2.4 摘要请求 profile:复用 model_gateway,关 thinking、`max_tokens` 512-1024,末条 user 追加 summarize 指令;不用交互式 16K 路径
- [ ] 2.5 组装投影:`_buildApiMessages` 改为读压缩树投影 `[system][摘要][近段原文][当前]`;节点按需展开(harness 注入,非 agent 工具)
- [ ] 2.6 后台折卷(idle-gated):槽空 + `_chain` 空 + 用户空闲才跑;request-id 定向 cancel;存断点"fold pending on segment N",下次空闲续折,绝不 delay 用户发送
- [ ] 2.7 `summary_nodes` 落库(单事务)+ bump `tree_version`;折卷和用户请求轮换共享单槽
- [ ] 2.8 测试:工具对完整性属性测试(折叠后仍合法交替、可喂回 `_buildApiMessages` 不拆对);树形/预算/确定性(FakeSummarizer);headless 集成(dump 折叠视图 + 前后 token)
- [ ] 2.9 guard/anchor:实现不可压缩锚点——用户目标/验收标准/"don't touch X" 不变量 pin 为永不塌缩,每轮重注入,集合有界/去重/可失效;来源为显式 standing-requirements(非 LLM 从 prose 抽取)

## 3. Phase 2 — 失效/重算 + 两级梯度

- [ ] 3.1 节点表按 `(session_id, level, start_seq, end_seq)` 键 + `covered_min/max_seq` 稠密非重叠 + `leaf_owner` 平面索引;insert/delete/updateToolCalls 标记受影响 span + 祖先 stale(dirty-seq 水位线),lazy 重算
- [ ] 3.2 失效触发基于**已有的** `updateToolCalls`(当前唯一叶子级修改);`tree_version` 递增验证;不为此变更引入新 delete/内容编辑(超出本 change 范围)
- [ ] 3.3 两级梯度(knob B):level-1 段总结;recency 梯度作为 segment index + config 的纯函数
- [ ] 3.4 测试:改中间叶子→仅受影响 span+祖先重算,cover 仍正确,tree_version 递增

## 4. Phase 3 — 全树 + canonical-cover 前锋 + 语义边界

- [ ] 4.1 层级用文本标记编码(非角色/块);"总结之总结"(level-2)卷起
- [ ] 4.2 ascend-on-the-left canonical-cover 前锋;预算驱动 `coarsen-only`(缩 N_verbatim / 换粗父);cover 稠密 + 完整 + 梯度单调
- [ ] 4.3 语义边界 A:LLM 在安全候选切点挑话题缝(嵌入同一摘要调用)+ memo 化(content hash keyed)保重建/测试可复现
- [ ] 4.4 测试:cover 稠密且完整;梯度单调(近详→远略);总预算 ≤ `maxContextTokens`;LADDER 可断言;确定性(同 history+config → 同树形);memo(重建用缓存不重调 LLM)

## 5. Phase 4 — 成本纪律 + 便宜层

- [ ] 5.1 每会话折卷预算(折卷次数 / 折卷 token)封顶;可见性只作调试/回放视图(不引入用户可见的"管理压缩"操作)
- [ ] 5.2 破平衡点回归测试:折卷 input tokens ≪ 每请求省下的 input tokens(用实测 usage)
- [ ] 5.3 便宜层:DeepSeek prompt-caching(`user_id`)+ 对远端采用**已存在的更粗摘要层**(非直接裁剪、不丢决策/再执行钥匙);近端大 `tool_result` **正文**(非工具对)轮内裁剪为截断标记 + 再取记录
- [ ] 5.4 评估/钉 DeepSeek `/v1/messages`(Anthropic 格式)usage 字段(`input_tokens`/`output_tokens`,**[UNVERIFIED]**);`prompt_tokens` 属 chat/completions,勿混用;禁止借 Anthropic 模型窗口数

## 6. Phase 5 — 对抗式诚实审查(Workflow)

- [ ] 6.1 开 Workflow 对**全部已勾 `[x]`** 任务做对抗验证:多 agent 从不同维度独立审查,交叉验证发现的问题(禁止手动/确认式单 agent)
- [ ] 6.2 逐项核查压缩历史从不:(a)拆 tool_use/tool_result (b)丢 tool_input 再执行钥匙 (c)丢用户目标/验收标准/不变量 (d)合成 thinking/tool_use/tool_result 块 (e)丢 workspace 根
- [ ] 6.3 发现的问题**追加为新任务**到文件末尾(绝不撤销旧 `[x]` 勾选);最后一项仍是诚实审查任务
- [ ] 6.4 回归检查前几轮已修项是否被本轮破坏;发现回归 → 追加修复任务
- [ ] 6.5 反复循环,直到诚实审查确认无问题,或达 **3 轮上限**;达上限后仍需一轮收尾审查且所有发现全修复
- [ ] 6.6 停止时输出审查结果报告:已审查轮数、每轮问题数、最终任务状态(最后一条消息必须是该报告)
