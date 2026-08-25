# AliasAgent 上下文压缩参考(design reference)

> **创建日期**: 2026-08-23
> **类型**: 设计参考(非官方 API 文档)
> **目的**: 固化"层级化上下文压缩"(hierarchical context compression)机制的设计探索结果 + 外部实现证据,作为 `/opsx:propose add-auto-context-compaction` 的依据。
> **外部事实说明**: 本文件引用的外部实现(Letta/MemGPT、Zep、remnic LCM、hierarchical-context-ai-agent、hermes-agent、billion-context-omp、@context-chef/core、@one710/recollect、Generative Agents、Context Folding 等)均出自各项目公开文档/仓库,已附链接;本文件**未逐字复核其源码**,仅作设计佐证,**不构成用于验收的条文**。引用的项目行为是否存在、数字是否准确,以各项目官方文档为准。
> **未验证项标注**: 任何标注 `[UNVERIFIED]` 的信息都不得直接写入 spec/design 作为验收标准,必须先核实。
> **对抗验证标记**: §3.2 各条以 `[V]`(经 N≥3 对抗验证 SURVIVED,可直接入 spec)或 `[R]`(被对抗验证 KILLED 后修正,见 §8)标注。

---

## 1. 问题背景(现状)

AliasAgent(Flutter 桌面 AI 对话应用,经 dart:ffi 调 C++ Sidecar,走 DeepSeek Anthropic 兼容端点)目前**对上下文无任何管理**:

| 环节 | 现状 | 依据 |
|---|---|---|
| 组装请求 | `_buildApiMessages`(lib/main.dart:1077-1149)把会话**全量**拼进 `apiMessages`,`_callModel`(lib/main.dart:689)原样发给 sidecar。 | 无截断、无压缩、无预算 |
| sidecar | `model_gateway.cpp:500` `body["messages"] = json::parse(messages_json)`;`body["system"]`(:496)独立固定,不参与压缩;`body["tools"]`(:507)。 | 请求体 = 全量历史 |
| 请求 profile | `thinking_mode == "adaptive"` 时 `max_tokens=16000`,否则 `max_tokens=4096`(model_gateway.cpp:481-493);请求**未设 `temperature`** → DeepSeek 默认 `temperature=1`(DeepSeekAPIDoc.md:235),摘要输出**非确定**。 | 影响摘要可复现 |
| token 记账 | `Message.token_count` 列 + 字段**从未被写入**:仅出现在 schema(database_service.dart:42/:92)、模型(message.dart:8/:30/:42)、`message_repository` 的透传参数(:15/:25)与测试。**无任何 writer**。 | 零度量 |
| usage 回传 | `OnDoneCallback(int code, const char* err, const char* stop_reason)`(sidecar/include/sidecar_api.h:19-23/:46)**不带 usage**。SSE 解析读得到 `message_start`/`message_delta` 的 usage(AnthropicAPIDoc.md:354/:372),但只在 model_gateway.cpp:278-280 处 LOG_TRACE,**并未回传 Dart**。 | 零遥测 |
| 预算锚点 | `Docs/DeepSeekAPIDoc.md:230("输入+输出 token 总长受模型上下文长度限制")`、`:328("达到 max_tokens 或上下文长度限制")` —— **均未给出具体上下文窗口数字**。 | 锚点不可验证 |
| 消息全序 | `messages` 无 seq/position 列;唯一排序为 `created_at`(message_repository.dart:48),值取 `DateTime.now().millisecondsSinceEpoch`(:26),id 为 UUIDv4(:20)。**工具循环内同毫秒多个插入会碰撞**,UUIDv4 不可排序。 | 树 span 无法定界 |
| 编辑/删除 | 唯一叶子级修改是 `updateToolCalls(id, toolCallsJson)`(message_repository.dart:32-40);**无逐条 delete 路径**(仅 session 级级联删除)。 | 重算基础缺失 |
| 并发 | sidecar **模型路径**单在飞:`static ModelGateway g_gateway`(sidecar_api.cpp:11) + `request_mutex`(model_gateway.cpp:430) + `curl_thread.join()`(:602);Dart 侧经 `SidecarBridge._enqueue`(sidecar_bridge.dart:213)串行。**工具/网络路径不走此门**(见 §3.2). | 模型路径不可并发折卷;工具/网络路径未被门控 |

**小结**: 当前是"**无界发送 + 零度量**",`token_count` 列与 usage 相关的槽都没被填上——是"欠了管线"的脚手架。

---

## 2. 目标方案(用户提议)

给框架的 agent 加一套**持续、稳定、自动**的上下文压缩机制,把上下文始终维持在安全 token 范围内,**不设手动 `/compact` 指令**(避免开发者陷入上下文焦虑、频繁手动调用)。用户提议的形态:

1. 把对话上下文切分成段落(segment)。
2. 后台对每个段落做总结。
3. 上下文变长时,对**更远的多个段落的总结再做总结**(摘要之摘要),形成**层级结构**。
4. **接近的对话记录不压缩**(原文),较远的替换成段总结,更远的替换成总结的总结。
5. **原始对话信息仍存磁盘**(SQLite),压缩树作为**派生索引**。

即:recency-gradient(近→详,远→略)+ 多层级 rollup + 原文无损留盘 + 无手动触发。

---

## 3. 设计不变量与约束(6 视角对抗评审综合)

对目标方案做了一次 **6 视角设计评审**(retention-loss、tool-call-integrity、cost-latency、determinism、budget-geometry、storage-schema;每个视角独立 REFUTE + 给精炼建议)。**方向成立(5×needs-change + 1×supported,无一人否决)**,但所有人一致指向若干**必须先补的地基**,以及若干对初始方案的"纠正"。以下按重要性固化。

### 3.1 地基前提(Phase 0 铁门槛,跨视角共识)

| # | 前提 | 曝光视角 | 说明 |
|---|---|---|---|
| 1 | **token 记账 / usage 回传** | 5/6 | 必须把 usage 从 SSE(AnthropicAPIDoc.md:354/:372)经新的 FFI 回调(或扩展 `on_done`)回传 Dart,写入现有 `token_count` 列;另备一个**本地非 LLM token 估算器**(chars/~4 或 pinned tokenizer)作为触发兜底。**无度量则压缩无法触发、也无法验收**。注:usage 字段名随端点——Anthropic-format `/v1/messages` 为 `input_tokens`(message_start)/`output_tokens`(message_delta),[UNVERIFIED] 待从 DeepSeek 官方 Anthropic 兼容文档核实;侧车**防御性解析 usage 块**(读端点实际返回的 token 字段);`prompt_tokens`/`completion_tokens` 是 chat/completions 字段。 |
| 2 | **预算上限 = 必填配置参数,无"未设"状态** | 5/6 | 上下文长度上限作为 **per-agent-type 必填配置参数** `maxContextTokens`(与 `model`/`apiKey`/`baseUrl` 一同放 config.json,如同 `apiKey` 一样必填),由用户显式设置;**无隐藏默认、无"未设置"的 fallback 模式**。触发用接口实测 usage(Anthropic-format `/v1/messages` 的 `input_tokens`/`output_tokens`,[UNVERIFIED])。**`stop_reason: length` 不作触发信号**(DeepSeekAPIDoc.md:328 它同时表示"输出到 max_tokens"或"输入到上下文长度",语义含糊,且被动撞线会先让一条真实请求失败)。**严禁**借 Anthropic 的 200K/100K。 |
| 3 | **tool_use/tool_result 对不可拆分** | 6/6 | `_buildApiMessages`(:1125-1147)强要求每个 `tool_result` 作为 role:user 消息**紧随**其 `tool_use` 且 tool_use_id 匹配。**折叠原子单元 = 完整工具轮**(带 tool_calls 的 assistant 消息 + 紧随其后的合成 user(tool_result)),二者必须一起进出。 |
| 4 | **消息需要稳定全序(seq)** | storage | `created_at` 同毫秒碰撞、UUIDv4 不可排序 → 树 span 无法定界。需给 `messages` 加 `seq INTEGER`(autoincrement)+ `(session_id, seq)` 索引;一切树边界用 `(session_id, start_seq, end_seq)`,`绝不`用 UUID id 参与区间逻辑。 |
| 5 | **确定性(决策/执行分离)** | testability | LLM 摘要非确定 → 树形必须是**纯函数**`tree = f(维数史, config, 代理token预算)`,LLM 只填充"已定死的叶子",**永不反悔形态**。测试断言树形/梯度/预算/耦合不变量,**不断言摘要措辞**。 |

### 3.2 关键纠正(评审逼出 + 对抗验证修正)

> 标记说明:`[V]`=经 §8 对抗验证 SURVIVED(可直接入 spec);`[R]`=被 KILLED 后修正/精修(原缺陷见 §8)。决策点 D1/D2/D3 见 §8。

- **保留梯度用 recency;可恢复性/重要性是叠加的"守卫",不是替代轴** [R,原 RD6]:旧≠不重要,但"按可恢复性非年龄"与"近原文/远总结"是**同一轴上的两个正交约束**,不能互斥表述。正确写法:**recency 决定梯度(近→详,远→略);在梯度之上,部分内容(用户目标、验收标准、`don't touch X` 不变量)被 pin 为"无论多旧都不塌缩"的守卫**——guard 是梯度里的**例外项**,不是替换梯度。
  - **锚点必须有界 + 可失效 + 显式来源** [R,原 RD7+RD8]:guard 集合**不能无条件每轮注入、无限增长**——要有预算上限、去重、过期策略,并能随"用户后来撤销需求"淘汰旧 guard。锚点需**显式来源**(见 §8 决策点 D3),不能靠 LLM 从 prose 自动抽取(temp=1 非确定,会漂移)。
- **摘要必须保留"再执行钥匙",不是叙事**:
  - **本地读工具幂等**(read_file/list_dir/glob_file/grep_file):output 可重跑重取,但 `tool_input`(path/pattern/offset)不可重取,必须存;**web_fetch / web_search 不算"可省 output"的读轮**(外部网络、内容可变、会失败,其输出是不可复现的外部事实) [R,原 RD2]。
  - **变更工具不幂等**(edit_file/write_file):重读文件拿不回"改了哪 X→Y"。**前态必须在"写"的时刻由 harness 捕获**(写前读该 path 内容存入记录),**不能**依赖"某次先前的幂等读 output"——因为那个 output 正是"读轮可省"会删的 [R,原 RD3]。
  - **edit_file 是批量数组,非单条 old→new**:`edits: EditPair{old_text,new_text,replace_all}` + 空白归一化匹配 + 多处未配 replace_all 则整批拒(tools.cpp:718-989)。"精确参数 + 前后状态"须**按批量 + 归一化 + 批失败**记录 [R,原 RD5]。
  - 每个压缩工具轮编码为**结构化记录**(intent + tool_name + tool_input 全文 + outcome_verdict + refetch_hint);**非幂等轮永不塌缩**。
  - **path 存双字段** [R,原 RD4]:**raw tool_input(workspace 相对原文)** + **resolved 绝对路径(或当时的工作区根)** 分别存。"存原始 input"与"用可重跑的绝对路径"不互斥——用第二个字段做重跑钥匙,不动第一个。
- **摘要的 role 用 `user`,不是 system**(参照 Claude Code,见 §5.4)。**role 值是固定的**(Anthropic 只有 user/assistant;DeepSeek 另支持 system/tool),**不能发明 "history" 这类 role**;DeepSeek `name` 字段(文档 :221)属 **chat/completions**,`/v1/messages` 未验证,故**以正文文本标记为主**。"摘要"语义上既**不是**系统指令,也**不是**用户发言——所以:顶层 `system` 字段留给**真正的指令/固定系统提示**,摘要**不塞进去**(Claude Code 就把 system 留作不变指令、压缩前后原样存活);摘要用 **role:user 文本消息** + **明显标记**(正文写 `## 更早上下文(压缩xN,非用户发言)`)。
- **API 层没有"层级"**:本地文档仅列 text/tool_use/tool_result/thinking(AnthropicAPIDoc.md:153-159 / DeepSeekAPIDoc.md:692),无 `summary` 块类型;且连续同角色消息自动合并(AnthropicAPIDoc.md:109)。所以**层级只能编码为文本标记**(单个 role:user summary 消息内写 `## 更早上下文(压缩xN)…`),不能靠角色/块区分;末尾为 assistant 消息会触发 prefill/续写(AnthropicAPIDoc.md:110)。
  - **⛔ 防合并(格式细节,非设计决策)**:若段切断在"真实用户文本"处,投影会是 `[user(summary), user(问题), …]`。"连续同 role 合并"**是 Anthropic 的规则**(AnthropicAPIDoc.md:109),**DeepSeek 文档未记载该行为**(DeepSeekAPIDoc.md:221),反而提供 `name` 字段区分同角色。**勿把 Anthropic 行为搬到 DeepSeek**;AliaAgent 走 DeepSeek,这套合并行为不一定适用。真正要做的是**实现层确保 summary 不与下一条 user 指令语义混淆**(注入 system/独立段落,或置为 `name` 标记、或保证边界后紧跟 assistant),属实现细节,不需用户拍板。
  - **中断的工具循环使段不可切(潜在单体)** [R,原 RD12]:`turn>=50` 中止(main.dart:1055)/switch-epoch 取消后,轮次以合成 user(tool_result) 结尾、**无 assistant-终答**,边界规则在其中找不到合法切点 → 整段多轮循环变不可拆单体,消退式折叠对该类会话失效。需给"以未决工具循环结尾的片段"定义**兜底切点**或"整段保留/整段折叠"策略。
- **客户端侧边界标记(compact_boundary 类似物)** [新增,参照 Claude Code 见 §5.4]:在"压缩摘要|近端原文"之间定义客户端侧的**分隔标记**(我们的等价物:一个 split 标记 + `tree_version`/seq 高水位)。作用:①明确"哪段被压过、哪段是新的";②支撑**恢复会话时重构**压缩视图。参照:Claude Code 的 `compact_boundary`(system subtype)写在 JSONL 转录里、`--continue` 时据此重构 `[summary, boundary, recent]`——注意它是**客户端自记账**,不是以 `role:system` 真的发给 API(API 的 messages 无 system role)。
- **压缩输出必须是纯文本**:**不合成** thinking/tool_use/tool_result 块。**理由要按 DeepSeek 正确的规则**(不能用 Anthropic 签名续接机制) [R,原 RD9]:(a) DeepSeekAPIDoc.md:199 —— 有工具调用时须回传**模型自身 prior reasoning_content**,否则 400(所以**不能把模型自己的 thinking 当普通文本改掉**);(b) 合成的 tool_use 无法配上真实 tool_result(结构性配对);(c) **DeepSeek 支持 thinking/tool_use/tool_result**(DeepSeekAPIDoc.md:692/:142-157),所以**不是"一刀切禁这些块"**,而是"**被压缩掉的工具轮/推理不可重构为这些块再渲染**"——工具轮要么原样展开,要么整段折叠成文本,不能半合成。
- **段边界规则** [V:C1 配对部分 contract 确认;边界缺陷见 RD1/RD12]:只能在 (a) 真实用户文本消息,或 (b) 无 tool_use 的 assistant 终答消息上切断;**绝不**在带 tool_calls 的 assistant 行上切(会切断工具轮);段内不能半折叠一个工具循环;最后一个 `tool_use` 必须与其合成 `tool_result` 粘在一起。
  - **语义边界(不拆话题)【待拍板,2026-08-23 用户提出】**:结构安全切点可能把同一话题簇从中间切开(例:某话题的两条"用户文本"之间就有个安全切点,该话题被劈成"折叠侧/原文侧")。澄清:模型看到的仍是完整 `[摘要][近段原文]`,不是"接不上话",**真正风险是接缝处信息可能丢细节**;且 recency 让**当前话题恒在 verbatim 近段**,只有"稍旧又被重拾"的话题才跨缝。三种接法:
    - **A. LLM 在安全候选切点里挑语义最顺的话题缝**:语义最好、不拆话题簇。**边界选择可嵌入同一条摘要调用**(summary prompt 里让 LLM 先挑候选缝再总结),**边际 LLM 成本 ≈ 0**(不额外开一条调用,只是输出稍多);真正的代价是边界选择**非确定** → 需 **memo 化**(按内容哈希缓存那次选择)+ 测试注 `FakeSummarizer` 固定边界——但这套 memo/mock 本来就是为了确定性要做的。**我倾向 A**。
    - **B. 重叠窗口**:下段摘要带上段结尾一小段——无 LLM、接缝双侧都有、不易丢;但有重复 → 多耗 token。
    - **C. 接受结构切 + 靠 recency(当前话题恒 verbatim)+ "保留决策/再执行钥匙"兜底**:零成本、零确定性问题;但旧话题重拾时接缝可能丢细节(最不可靠)。
    - **真实性 tradeoff,待拍板(我的推荐:A)**:要"旧话题重拾也丝滑"就选 A——这正是你在意的;**且 A 边际 LLM 成本≈0**(边界选择嵌在同一次摘要调用里),memo/mock 反正要做。**我倾向 A**。C 只是想省事/最小复杂度时的退路,代价是**保留那个"接缝丢细节"**(也就是你不想要的那个尴尬);除非你确认不在意,否则 C 不推荐。
- **工整性保障**:带 tool_calls 的 assistant 消息**永远原样展开**(node_type 标记或被推导为 has_tool_calls),无论多旧;包含 tool_calls 叶子的 span 一律不塌缩。
- **近端超大 tool_result 会单独爆预算**:recency 规则保留近端原样,但近端恰好是大体落点 → 允许**近区轮内裁剪**:把大结果体替换为"截断标记 + 再取记录(path/字节/line 范围)",保住该轮的文本与工具意图。
- **后台折卷必须 idle-gated + 可抢占 + 断点续** [V:C6 结论成立,但前提要收窄]:串行的**只是模型路径**(g_gateway/request_mutex/curl join/Dart `_enqueue`);**web_search/web_fetch 在独立 worker isolate + 本地 CURL 句柄**(web_search 还 `std::async` 扇出),**文件工具是主 isolate 同步 FFI**——所以"单在飞"≠全 sidecar [R,原 RD10]。折卷须避开模型路径;且当前抢占原始对象是**全局 `cancel_flag`(无 request-id 目标)+ FIFO `_enqueue`** → 折卷排前面会让用户请求等它;TOCTOU 下 cancel 可能**误杀用户自己的请求**。**需 request-id 定向 cancel 或独立折卷通道(见决策点 D2)**。
- **折卷是"贵的",不是默认路径**:折叠要重读本要省下的 input token。先评估便宜层——**DeepSeek prompt-caching**(`user_id`,DeepSeekAPIDoc.md:241)+ 直接裁剪远端历史;LLM 树仅作长会话升级。折卷用**专用 profile**(关 thinking、`max_tokens` 512-1024、更便宜模型),**绝不**用交互式 16K 路径。
- **树是派生索引,原文永不破坏** [V]>rollup 只作请求 payload 投影,原始 `messages` 表逐字保留;树节点带 `(session_id, start_seq, end_seq)` 主键 + 按需展开路径(harness 注入,非 agent 工具),否则"原文留盘"是惰的。
- **树形与存储**:`summary_nodes` 表按 `(session_id, level, start_seq, end_seq, node_type, parent_id, summary_json, token_cost, summary_prompt_version, model, covered_min_seq, covered_max_seq)`;用 `summary_json`(role blocks)而非单段 `summary_text`;memo 化摘要(content hash + prompt version + model)保可复现;`covered_min/max_seq` 稠密非重叠 + `leaf_owner` 平面索引保 O(1) 失效;parent_id 仅作导航。
- **失效与重算**:加每会话 `tree_version` / dirty-seq 水位线;insert / delete / updateToolCalls 会 bump 并标记受影响 span + 祖先为 stale,lazy 重算。
- **迁移 v3→v4**:加 `seq` + rollup 表 + `tree_version`,但**不给旧数据预建 rollup**(seq 回填 best-effort,按 created_at+rowid),旧消息一律作未压缩叶子,惰性向前建高水位;schema 需**镜像到 `openAt`**(database_service.dart:69-111),并补 v3→v4 迁移测试。

---

## 4. 分阶段实施路线

每阶段先可测、**不修改任何验收标准**、无 user-in-the-loop 任务(符合 CLAUDE.md)。阶段顺序由"从零度量"推导。

```
Phase 0  token 遥测 + seq 列 + 可验证预算锚点   ← 铁门槛,先不做任何压缩逻辑
    - SSE 解析 usage → 新 FFI 回调(or 扩展 on_done)→ 写 token_count
    - messages 加 seq INTEGER + (session_id, seq) 索引;树边界一律用 seq
    - model_context_window 配置(保守默认 + [UNVERIFIED] 标注)或核实官方
    - 本地非 LLM token 估算器(触发兜底)
    - 测:usage 回传写库可观测;seq 在同毫秒插入下严格单调;估算器确定性
Phase 1  单层平铺 MVP(近轮原文 + 一个根总结)   ← 最小可剪面
    - 压缩 API 视图 = 最近 N 轮原样 + 一个纯文本 role:user 根总结(含防合并守卫 D1)
    - 预算驱动(真实 usage);idle-gated 后台折卷;专用廉价 profile
    - 段边界规则 + 工具轮原子性(绝不拆 tool_use/tool_result)
    - 测:折叠后仍是合法交替且 tool_use 后紧随 tool_result;可喂回 _buildApiMessages
Phase 2  失效/重算(编辑/删除)+ 两级梯度(knob B)
    - 节点表 + seq span 键;insert/delete/update 触发 span+祖先失效
    - 补逐条 delete / 内容编辑基础设施(当前缺失)
    - 测:改中间叶子 → 仅受影响 span+祖先重算,cover 仍正确,tree_version 递增
Phase 3  全树 + canonical-cover 前锋(knob R, L)+ 摘要之摘要
    - 层级用文本标记编码(非角色/块);recency 梯度作为 segment index+config 纯函数
    - ascend-on-the-left 前锋算法;预算驱动 `coarsen-only`(缩 N_verbatim / 换粗父)
    - 测:cover 稠密且完整;梯度单调(近详→远略);总预算 ≤ 阈值;工具相邻完整
Phase 4  成本纪律 + 便宜层
    - 钉 DeepSeek 真实上下文窗口;触发预算由测得 usage 推,非魔法常数
    - 每会话折卷预算(折卷次数/折卷 token)+ opt-in + 可见成本
    - 破平衡点回归测试(折卷 input_tokens ≪ 每请求省下的 input_tokens)
    - 评估 prompt-caching(user_id / KVCache)+ 裁剪远端作为默认便宜层
Phase 5  对抗式 Workflow 诚实循环(逐轮回归核查)
    - 验证压缩历史从不 (a)拆 tool_use/tool_result (b)丢 tool_input 再执行钥匙 (c)丢用户验收标准/不变量 (d)合成 thinking/工具块 (e)丢 workspace 根
    - 每轮回归核查前几轮已修项(CLAUDE.md 回归检查);发现回归 → 追加新任务,绝不撤销旧勾选
```

### 4.1 测试策略(分层 × 阶段)

> **主轴:决策/执行分离**——`buildTree(history, config, proxy_usage)` 是**确定性纯函数**(折哪几段、边界、预算、cover 全不靠 LLM);LLM 只填充"已定死的叶子"。所有单测 / widget / headless 集成用一个 **`FakeSummarizer`** 接口(返回固定长度/固定形状摘要;A 方案的边界选取也 mock 固定值)→ **离线、确定性可跑**。断言**只测树形 / 预算 / 耦合不变量 / 边界合法,never 比摘要措辞**。

| 阶段 | 层 | 测什么 | 怎么保确定 |
|---|---|---|---|
| P0 | `sidecar/test`(Catch2) | SSE 解析把 `message_start`/`message_delta` 的 usage 抛给新 FFI 回调;断言 usage 字段被解析 | 喂固定 fixture |
| P0 | `test/unit` + `test/integration` | `token_count` 在 insert 时写入;`seq` 同毫秒插入下严格单调;`maxContextTokens` 缺失→设置提示(同 apiKey);**dump usage 后才断言**(可观测) | FakeSidecar 返回固定 usage |
| P1 | `test/unit` | `buildTree` 形状(`[system][summary user][近段原文][当前]` 顺序);总预算 ≤ `maxContextTokens`;两建深等(确定性) | FakeSummarizer |
| P1 | `test/unit` —— **属性测试** | 折叠多轮工具对话后仍**合法交替 + 每个 `tool_use` 的 `tool_result` 就在下一条**;可喂回 `_buildApiMessages` 不拆对 | 多 fixture 扫,纯逻辑 |
| P1 | `test/integration`(headless) | 对话跨过上限时 `messagesJson` 变压缩形态;dump 折叠视图 + 折叠前后 token | FakeSummarizer + FakeSidecar |
| P1 | `integration_test`(live 真模型 `-d windows`) | 设 cap 远低于真实窗口→跑 N 轮:全程无"超限"报错 + 助手能正确引用早期上下文(连续性)+ 工具照常;先打印实际工具调用+文件终态再断言 | live,接受非确定,断言"行为结果" |
| P2 | `test/unit` | 编辑/删除中间叶子→仅受影响 span+祖先重算;`tree_version` 递增;cover 仍正确 | 确定性 |
| P3 | `test/unit` | cover 稠密+完整;梯度单调(近详→远略);总预算≤阈值;LADDER(哪段在哪层)在固定宽历史可断言;层级=文本标记非角色/块 | 固定 fixture |
| P3 | `test/unit` memo | 重建用缓存摘要(不重调 LLM);`materialize == buildTree` 等价(后台路径=纯函数) | 摘要缓存 |
| P4 | `test/integration` | **破平衡点回归**:折卷 input ≪ 每请求省下 input(用实测 usage) | FakeSidecar usage |
| P5 | Workflow 对抗审查(CLAUDE.md 强制) | 多 agent 验证从不:(a)拆工具对 (b)丢 re-run key (c)丢验收标准/不变量 (d)合成 thinking/工具块 (e)丢 workspace 根;逐轮回归核查 | 无网络,只读 |

**最关键一条(工具对完整性属性测试)**:

```dart
// 属性: 对任意工具密集对话, 折叠后仍合法交替 + tool_use 紧跟其 tool_result
for (final fixture in toolHeavyFixtures) {
  final compacted = buildTree(fixture, config, fakeSummarizer);
  assertValidApiOrder(compacted); // 交替 + 每个 tool_use 的 result 在下一条
  _buildApiMessages(compacted);   // 再重构一趟, 断言不报错、不拆对
}
```

这样"边界别把话题拆了(A/C)"和"别拆工具对"都落到**结构断言**,不靠猜。

**只能靠 live 真模型测**:
- 摘要质量/连续性(助手还记得旧上下文)——单测测不了(措辞非确定)。放 `integration_test`(`@Tags live`,`-d windows`):设 cap 远低于窗口跑 N 轮,断言 (a) 不超限 (b) 延续任务能引用决策 (c) 工具照常;并**先打印实际工具调用+文件终态再断言**。
- 这同时验证"压缩对模型行为无副作用"。

**诚实的边界**:
- 摘要"质量好坏"无法单测——只保证结构合法 / 预算不超 / 决策保留 / 不拆对;**措辞好坏靠 live 行为 + 对抗审查兜底**。
- A 方案语义边界若上 LLM:单测只测"边界选择被 memo/mock"(确定性),真实语义质量仍靠 live。
- 所有测试由主循环自跑(`flutter test` / `cmake ctest` / `dart run`),无 user-in-the-loop;遵守 CLAUDE.md 观测性(先 dump 再断言)与**不修改验收标准**。

### 4.2 后台折卷生命周期(触发 → 折卷 → 抢占/断点 → 落库 → 下次组装)

> **本质**:折卷本身也是一次模型请求(走摘要 profile),占的是那条**唯一在飞的模型槽**——它不是"真后台并行",而是**占用户空闲间隙**、与用户请求轮换共享同一槽。故必须 idle-gated + 用户优先 + 可抢占。

```
用户一轮结束(assistant 回完)
      │
      ▼ ① 触发评估
  有新满的段?  且  槽空闲 + _chain 空 + 用户不在输入/发送  且  折卷预算未超
      │ 是
      ▼ ② 发起折卷(占空槽)
  同 system/tools + 【被折那段的 messages】+ 末条 user 追加 summarize 指令
  (关 thinking、max_tokens 512-1024、可选更便宜模型)
      │
      ▼ ③ 用户此时发新消息 ──► 抢占
  定向 cancel(带 request-id,非全局 flag)+ 存断点 "fold pending on segment N"
  下次空闲从 N 续折 —— 绝不 delay 用户发送
      │ 没被打断,正常折完
      ▼ ④ 完成 → 落库(事务原子)
  summary_nodes(session_id, level, start_seq, end_seq, summary_json,
                token_cost, summary_prompt_version, model, covered_min/max_seq)
  + bump tree_version + 标记该段已折叠
      │
      ▼ ⑤ 下次组装
  读【已提交】树 + 同一纯函数投影 → [system][摘要][近段原文][当前] 发给模型
  未折完的段读不到(dirty-seq → lazy 补折)
```

- **①触发(精确条件)**:不是定时器——每轮完成后评估一次,三者都满足才折:①有新满的段(未折叠历史超过一段阈值,暴露"新料");②空闲(模型槽空 + `_chain` 空 + 用户不在输入/发送);③折卷预算未超(每会话折卷次数/token 上限)。缺一 → 不折,零成本。
- **②折卷请求**:复用 `model_gateway`,用**摘要 profile**(逻辑同 Claude Code:同 system/tools + 末条 user 追加 summarize 指令、`querySource:'compact'`、关 thinking、小 `max_tokens`)。L1 折段原文;L2 折"下层的若干摘要"。
- **③抢占/断点**:折卷在飞、用户发消息 → **定向取消该折卷**(D2:request-id 定向,非全局 flag,避免误杀用户请求)+ 写断点;下次空闲从 N 续折,不重读已折部分。
- **④落库(原子)**:折卷结果写 `summary_nodes`,单事务提交 + `tree_version` 递增。**用户界面完全不变**(原始对话仍在磁盘/界面);同步的是"发给模型用的派生树",不是聊天记录。写另一半时不会被读到(dirty-seq / 未提交事务)。
- **⑤下次组装**:组装走同一纯函数 `buildTree(history, config)` 读**已提交**的树 → 投影压缩后的 `messages`。后台折卷 = 给"纯函数算出的空壳"填上 LLM 内容并缓存 → **materialize(缓存后) == buildTree(纯函数)**(testability 等价测试保住)。
- **诚实边界(单槽)**:折卷和用户请求**轮换共享、非双通道**。若折卷未完成、用户就发消息,本轮可能用"只折了一半的树"→ 结果**比预算略保守(多带一点原文),但绝不超限、不丢内容**;新料下次空闲续折,最终收敛。

---

## 5. 外部实现证据

以下为已查证的外部项目(均出自其公开文档/仓库)。**它们不是验收标准,但佐证本方向可行,且其"正确做法"与第 3 章纠正一致**。标注 [UNVERIFIED] 的为仅凭文档描述、未复核源码。

### 5.1 与目标方案最贴合(多层级 + 近端原样 + 远端滚动总结)

| 实现 | 形态 | 与本方案关联 | 出处 |
|---|---|---|---|
| **remnic / Lossless Context Management (LCM)** [UNVERIFIED] | 摘要 DAG:depth0(叶子)≈8 轮(最细)→depth1≈32 轮(4 叶)→depth2≈128 → depth3≈512+;fresh tail(默认 ~16 轮)用叶子级最细;旧区用最深节点最省 | **几乎就是你提议的多层 rollup + 近细远粗梯度**;且用 SQLite FTS 索引、原文无损留盘,并给 `remnic_context_search`(全文搜索)/`remnic_context_describe`(区间摘要)/`remnic_context_expand`(取回原始无损消息)三工具,正对上"原文留盘但 agent 够得着" | <https://github.com/joshuaswarren/remnic/blob/main/docs/guides/lossless-context-management.md> |
| **koladilip/hierarchical-context-ai-agent** [UNVERIFIED] | 三层滚动总结 + 结构化记忆提取 + LLM-as-judge 质量监控;**60% 容量触发**(非 90%);留最近 **5-10 轮**完整;提取关键事实(budget/goals/路径) | 已上线、有评测;实测 judge **8.1/10**(Completeness 9.0 / Relevance 10.0),60+ 轮 **86.7% 事实召回**;"提取关键事实"直接对上"保 tool_input 再执行钥匙 + artifact ledger" | <https://github.com/koladilip/hierarchical-context-ai-agent> |
| **NousResearch/hermes-agent `context_compressor.py`** [UNVERIFIED] | `_SUMMARY_RATIO=0.20` + `_SUMMARY_TOKENS_CEILING=12000`,20% 预算触发 + 硬上限;预算耗尽仍保近期原样;压缩注记明确"**更早轮次被压进摘要…当作背景参考,不是活跃指令**";有确定性兜底(8000/700 char)保证收敛 | 开源可读;"摘要=背景非指令"对上"验收标准不可压缩";"近端原样"与"确定性兜底"是硬约束 | <https://github.com/NousResearch/hermes-agent/blob/44ddc552/agent/context_compressor.py> |
| **billion-context-omp** [UNVERIFIED] | T1→T2→T3 分层蒸馏;模型**自决**何时压什么(经 `compress` 工具,非常硬上限);压缩成带 `<acp>` 引用标签的块,配 `decompress`/`search_context`/`acp_status`;一次会话吃 **10-60 亿累计 token** 但上下文保持 **~150K**,比传统压缩省 **5×** | "区间引用标签 + 展开工具"正是"原文留盘可回看"的落地;分层蒸馏 = 层级 rollup | <https://www.npmjs.com/package/billion-context-omp> |
| **两级记忆系统(m1→m2)** [UNVERIFIED] | ~150 字单任务摘要 → 攒 20 条升 ~200 字宏摘要;维持恒定上下文长度;动机明确"**摘要之摘要保留决策链(m2→m1→原始任务可追溯)**" | 最朴素的多层卷起,即"更远 = 总结的总结" | <https://raw.githubusercontent.com/denda188/ClawIntelligentMemory/refs/heads/main/two-level-memory-system.md> |

### 5.2 支撑"近原样 / 旧卷起 / 原文留盘"的另一支路

| 实现 | 形态 | 关联 | 出处 |
|---|---|---|---|
| **MemGPT / Letta** [UNVERIFIED] | OS 式虚拟内存:main context(核心记忆,始终在窗内,agent **自我编辑**)+ recall memory(全量历史,可搜索)+ archival memory(向量库);显式做分页/摘要/驱逐/检索 | "无手动、持续自动、稳定保范围"正是它的 self-editing + heartbeat 设计哲学;三层内存 = 近/历/档 | <https://docs.letta.com/concepts/memgpt/> 、MemGPT 论文(2023) |
| **Zep** [UNVERIFIED] | 三层时序知识图谱:episode(原始无损)→ entity/facts(边的精确事实,带 `valid_at`/`invalid_at` 双时序)→ community(社区级高层摘要);**明确不建议只靠摘要做 grounding,要用 facts** | 支持"摘要 + 结构化记录(再执行钥匙)";"原文无损 + 高层汇总"三层即"episodic/semantic/community" | <https://github.com/Josephrp/zep> 、<https://help.getzep.com/v2/facts> |
| **Generative Agents(Stanford, Smallville)** [UNVERIFIED] | 记忆流 + 检索(`recency × importance × relevance` 加权)+ reflection(观察合成高层洞见,且**能反思自己的反思 = 递归层级**) | 两点直接印证纠正:(1) 保留梯度**非纯按年龄**,importance/relevance 与 recency 并列;(2) reflection 递归 = 摘要之摘要 | <https://github.com/StanfordHCI/genagents> |
| **Context Folding(ICML 2026 研究)** [UNVERIFIED] | 子任务开子轨迹,完成时**折叠中间步、只留结果摘要**;活跃上下文小 **10×** | 研究向,佐证"折叠中间步只留结果"方向 | <https://icml.cc/virtual/2026/poster/61950> |

### 5.3 支撑具体子机制(工具输出外移 / 触发 / 角色保护)

| 实现 | 子机制 | 出处 |
|---|---|---|
| **@context-chef/core** [UNVERIFIED] | 触发用 tokenizer 计算或 provider 返回 usage 超 `contextWindow`(`preserveRatio 0.8` / `preserveRecentMessages`);**把大工具输出 offload 到 VFS(`context://vfs/`)只留头尾**;`onBudgetExceeded` 钩子 | <https://socket.dev/npm/package/context-chef> |
| **@one710/recollect** [UNVERIFIED] | 保护 pinned 角色(system/developer)不被压掉;run-aware 压缩(用 runId)避免拆开进行中的工具链 | <https://www.npmjs.com/package/@one710/recollect> |
| **hermes-agent**(见上) | `_PRUNED_TOOL_PLACEHOLDER = "[Old tool output cleared to save context space]"`;图像按 1600 token/张计入预算 | 同上 |

### 5.4 客户端压缩参照(Claude Code,参考实现)

用户点名参照的产品。其 client-side compaction 要点(2026-08-23 经 WebSearch 核实,来源见下):
- 压缩摘要是 **`role:user` 的 `summary_message`**(重建后 `messages[]` 首条);**不是** system 字段,也不是 system 消息。
- **顶层 system prompt**(tools/permissions/CLAUDE.md)独属字段、不属消息历史,**压缩前后原样存活**——故动态摘要不进 system。
- **`compact_boundary` 标记**(system subtype)写在 **JSONL 转录**里,用于 `--continue`/`--resume` 时重构 `[summary, boundary, recent]`;它是**客户端自记账**,不是以 `role:system` 真的发给 API(API messages 无 system role)。
- 压缩请求本身 = 同 system/tools/history + 在**末条 user 消息**追加一段 summarization instruction(`querySource:"compact"`,关 thinking)。
- **对我们的启示**:摘要用 user role 是对的;system 留给真指令(压缩中存活);引入**客户端侧边界标记**定位"摘要|近段"+ 支撑恢复重构(见 §3.2 边界标记条)。

> 来源(Claude Code 官方/社区):[Context Management](https://mintlify.wiki/sanbuphy/claude-code-source-code/concepts/context-management) 、[compaction.mdx](https://github.com/claude-code-best/claude-code/blob/main/docs/context/compaction.mdx) 、[The Agent Loop](https://mintlify.wiki/sanbuphy/claude-code-source-code/concepts/agent-loop) 、[Context window(官方)](https://code.claude.com/docs/en/context-window) 。

---

## 6. 未决项 / 待验证

1. **[已解决] 上下文长度上限 = 必填配置参数,无"未设"路径**(2026-08-23 确认,A 方案):DeepSeek 接口给不出精确窗口数(无 `/models` 元数据、无"窗口=N"字段,:230/:328 仅作隐式上限),故**不作为前提**。上限作为 **per-agent-type 必填配置参数 `maxContextTokens`**(与 `model`/`apiKey`/`baseUrl` 同放 config.json),**如同 `apiKey` 一样必填**;**无隐藏默认、无"未设"fallback**。触发信号用接口实测 usage(Anthropic-format `/v1/messages` 的 `input_tokens`/`output_tokens`,[UNVERIFIED];侧车防御性解析 usage 块,读端点实际返回的 token-count 字段);`prompt_tokens`/`stream_options.include_usage` 是 chat/completions,不适用于 `/v1/messages`;`stop_reason: length` 不作触发(:328 语义含糊)。**测试(方案 A)**:Phase 0(token 遥测)后——设小 `maxContextTokens` → 造估计超限的对话 → 断言到阈值即折叠、折叠后仍合法、tool_use/tool_result 对完整、总预算 ≤ cap、树形确定;设大 cap → 断言不折;边界(恰好阈值下/上);全部用 mock usage 喂估算以保证确定性;live 验收用远低于真实窗口的 cap 跑 N 轮、断言无"上下文超限"报错。已知精确窗口仅让用户能填得更准,可后补;**严禁**借 Anthropic 的 200K/100K。
2. **N≥3 对抗验证(多数决 kill)已执行**(2026-08-23,Workflow `verify-context-compaction-claims`,18 怀疑者 / 6 claim)：**C2 SURVIVED;C1/C3/C4/C5/C6 KILLED**。C2 是唯一"可直接入 spec"的 claim;其余被判 kill 后**采纳的真缺陷修正**已回写 §3.2(标 `[R]`)。剔除的假阳性(ground 视角以"功能尚未实现"为由)与逐条记录见 §8。**未决设计选择 D1/D2/D3 见 §8**。
3. **是否用便宜层(prompt-caching + 裁剪)** 作为默认,LLM 树作为长会话升级 —— 需以实测(真实 usage)数据定,非拍板。
4. **需求若有改动须有用户明确授权**(CLAUDE.md 审查规则第 4 条)——本方案自用户原始提议起未改动。

---

## 7. 相关文件

- 组装/请求: `lib/main.dart`(`_buildApiMessages` :1077-1149, `_callModel` :660-), `sidecar/src/model_gateway.cpp`(:469-517 请求体), `sidecar/include/sidecar_api.h`(:19-23/:46 回调)
- 数据模型/库: `lib/models/message.dart`, `lib/services/database_service.dart`(schema v3, :42/:92 token_count), `lib/services/message_repository.dart`
- 官方文档: `Docs/DeepSeekAPIDoc.md`(上下文限制 :230/:328;usage :310-319/:660-665 = prompt_tokens(chat/completions);prompt cache :241,:313,:662-663;thinking 往返 :199;块类型 :692), `Docs/AnthropicAPIDoc.md`(块类型 :153-159;同角色合并 :109;末尾 assistant/:110;usage :354/:372 = input_tokens(/v1/messages))
- 相关既有变更: `openspec/changes/add-live-test-visual-acceptance`(active)

---

## 8. 对抗验证记录(2026-08-23)

对 §6.2 列出的成型 claim 各派 ≥3 独立怀疑者(源码印证 / API 契约 / 失效模式猎手)REFUTE(默认 refuted=true),多数决 kill(3 中 ≥2 否即杀)。Workflow `verify-context-compaction-claims`:18 怀疑者、0 错误、918K tokens、216 次本地读。

| Claim | 结论 | 怀疑者(ground/contract/failure) | 采纳 |
|---|---|---|---|
| C1 折叠原子单元 + 段边界 | KILLED (2/3) | ✗(未实现) / ✓(配对被 API 文档证实) / ✗(边界缺陷 RD1、中断循环 RD12) | 配对部分成立(见 §3.2 段边界 `[V]`);边界部分改写(D1/D2) |
| C2 预算 = usage 驱动 + 锚点不可验证 | **SURVIVED (1/3)** | ✓ / ✓ / ✗(字段名 RD11) | 方向入 spec;字段名随端点——`/v1/messages`(Anthropic 格式)用 `input_tokens`/`output_tokens`,chat/completions 才用 `prompt_tokens`;[UNVERIFIED] 待核实 |
| C3 非幂等轮不塌缩 + 读轮保 tool_input | KILLED (2/3) | ✗(未实现+路径矛盾) / ✓ / ✗(RD2/RD3/RD4/RD5) | 框架成立;幂等集合、双字段、前态捕获、批量数组全改(§3.2 `[R]`) |
| C4 验收标准 = 不可压缩锚点 | KILLED (3/3) | ✗(未实现) / ✗(无文档化豁免) / ✗(RD6/RD7/RD8) | 思想保留;recency 为轴 + guard 为守卫;锚点有界/显式(§3.2 `[R]`) |
| C5 层级文本标记 + 纯 text | KILLED (3/3) | ✗(未实现) / ✗(错 provider 理由 RD9) / ✗(RD1) | 文本标记方向保留;纯 text 理由改 DeepSeek 规则(§3.2 `[R]`) |
| C6 sidecar 单在飞 → idle-gated | KILLED (2/3) | ✗(收窄) / ✓ / ✗(RD10) | 前提收窄到"模型路径";抢占需定向 cancel/独立通道(§3.2 `[R]`,D2) |

### 剔除的假阳性(诚实过滤,不当缺陷)

- **ground 视角多次以"代码里没有折叠/压缩逻辑"为由 refute**(C1/C3/C4/C5):该功能本就是**待实现新特性**,"尚未实现"对设计验证是字面正确、但**不是设计缺陷**;不计入。
- **contract 视角对 C1/C3/C6 未 refute**:tool_use/tool_result 配对被 Anthropic/DeepSeek 文档证实;工具轮记录是 harness 内部规则、非 API 行为断言;单在飞(模型路径)前提代码可证。

### 实现层待定(我把关,不需用户拍板;结果会回写本文档)

以下的"方案"是**我该做的实现选择**,不是"用户要做决定"的设计分叉(2026-08-23 更正:此前误列为"决策点")。

- **D1(防合并)**:格式细节,已按 §3.2 处理(勿套 Anthropic 合并行为;DeepSeek 有 `name` 字段)。实现时选一:summary 注入 system/独立段落;或置 `name` 标记;或保证边界后紧跟 assistant。
- **D2(抢占/并发)**:需保证**后台折叠不卡用户、可安全打断**。实现时优先 request-id 定向 cancel + 折卷仅在 `_chain` 空且无在飞请求时入队(最小改动),不引入第二通道。
- **D3(锚点来源)**:用户目标/验收标准/不变量的识别。默认方案:显式 "standing requirements" 模块(零漂移、可测、可失效);如需改为自动抽取再议。
