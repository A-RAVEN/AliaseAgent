# Design: model-truth-from-gateway

## Context

已核实的代码事实（对抗审查 v2 逐条核实过，含推翻本 change 初版的修正）：

- `AgentTypeConfig.maxContextTokens` 是 `int?`（`lib/models/agent_type_config.dart`）；窗口有 **8 个读取点、6 个方法**（`_callModel`、`_maybeScheduleBackgroundFold`、`_runBackgroundFold`、`_loadClosedSegments` 等）——解析必须收拢到一个单点再分发，不能只在 `_callModel` 改。
- 持久化目录条目（`ModelCatalogEntry`）的窗口字段名是 **`context_window`**（网关响应同时带 `context_length`，产品快照只持久化 `context_window`）；思考档位字段是 **`reasoningEfforts`**（`supported_reasoning_levels[].effort` 列表），**没有 reasoning 布尔**。
- 思考白名单 `kThinkingEfforts` 是**五档**：low / medium / high / xhigh / max（`lib/services/agent_config_resolver.dart`）。
- `AgentConfigResolver.resolve` 现状把窗口当必填正整数（`isValidWindow` 拒 null/<=0），`ResolvedAgentConfig.maxContextTokens` 是非空 int——"可选覆盖"语义要改这里。
- **首启向导现状第二步只有窗口整数输入，没有任何探测**；探测入口只有 Providers 页；`SetupDialog._submit` 是同步 void，不持有 ProviderCatalogDiscovery。「Start 本来要求探测成功」是初版假事实。
- 补问触发只剩"配置不存在/缺字段"类入口；缺密钥等其它"触发"现状是死态或发送期异常（`Configuration Error` / `MissingAgentProviderException`），不是活的补问。
- D7 承重墙：Agent 实例现状拿不到模板/目录的实时引用——需要 `AgentFactory.create` 注入查找器（模板：按 agentTypeName 查注册表；目录：按 provider 名查探测结果）。

## Goals / Non-Goals

**Goals:**

- 生效上下文窗口只有一个事实来源：网关目录。写死的窗口数字在产品里绝迹；目录与覆盖都拿不到时**显式失败**（不发明缺省）。
- 首启配置里的模型名与窗口都来自向导内当场探测成功的目录；产品里不存在任何硬编码模型 id。
- 配置里的模型名在目录中消失时，用户在界面上看得见。
- 缺省思考强度按目录档位取中间档；显式配置档永远优先；推理强度修改对运行实例下一消息生效。

**Non-Goals:**

- 自动修复/改写用户配置里的脏模型名（既有条文禁止；可见性就够）。
- 目录探测失败时的自动重试；窗口/思考的 GUI 编辑（覆盖仍走 config.json 手编）。

## Decisions

**D1 窗口解析规则（唯一口径，三档归并）。**
解析点收拢到 `AgentConfigResolver.resolve`（单点，6 个消费方继续读 `ResolvedAgentConfig`）：该模型在所属 Provider 当前目录里有正的 `context_window` ⇒ **一律以目录为准**；目录缺失（Provider 未探测 / 目录无此模型 / 窗口值非正）⇒ 用配置 `max_context_tokens` 正整数覆盖；**两者都没有 ⇒ 显式失败**——创建 Agent 时报错，错误消息点名模板名并给两条出路（去 Providers 页探测该 Provider 的目录；或在 `agent_types.<模板名>.max_context_tokens` 写正整数覆盖）。**不设数字回落**（回落值就是隐性硬编码，正是本 change 要消灭的东西）。覆盖值与目录值不一致时打一行 `debugPrint` 日志点名被忽略的覆盖值（大于、小于两个方向都打）。压缩阈值/等待上界只消费解析结果，公式零改动；窗口仍是**实例创建时解析一次**，运行实例不随目录刷新变（`context-occupancy-ring` 条文不变）。

**D2 首启缺省模型 = 向导内当场探测目录的第一项。**
向导第二步改造：删掉窗口整数输入，**新增一次探测门**（注入 ProviderCatalogDiscovery；Start 放行条件 = 探测成功且目录非空；失败/空目录按既有校验通道报错、不写出配置）。探测成功的目录**同一次保存写回** `providers.<名>.models`（`ModelCatalogEntry` 形状，窗口键 `context_window`）并写 `discovered_at`，此后窗口解析与脏值判定都有了目录可用。缺省模型 = 目录第一项（网关顺序，本产品不排序），下拉可改。补问路径（已有配置）不碰模型字段。删掉的硬编码模型串包含现有 flash 那处（整处删除，连"缺省偏好"都不留——首启要求网关可达是如实的新前提）。

**D3 删窗口输入步；缺 `max_context_tokens` 不再是补问触发条件。**
缺席从此合法（=目录语义或覆盖缺失）。**如实改写**：删掉这一处后，产品不再有任何自动补问入口（仅剩"配置不存在"的首启）——初版"保留缺密钥等其余触发"的说法是错的（那些路径现状是死态/发送期异常），按现状写。setup_dialog 头注释整段按新语义重写（原"那一步是补问触发条件，不能被砍掉"写明为什么现在能砍）。写回配置不含窗口键（除非用户手编）。

**D4 脏模型名可见（只提示，不改写；按编辑器打开时的目录快照）。**
模板编辑器模型行：已保存模型不在该 Provider 目录 ⇒ 警示文案（"当前目录没有这个模型"）；Provider 从未探测（无 `discovered_at`，**不得**用"目录为空"代替判断）⇒ 中性文案。**没有实时通道**：提示按编辑器打开那一刻的目录快照计算；关闭编辑器 → Providers 页刷新 → 重开编辑器重算。不自动改配置（既有条文不动）。

**D5 既有测试点名改，不许静默放松。**
钉旧语义的用例（`setup_dialog_test` 窗口输入/写出断言、`app_shell_test` R1-7 补问触发、`template_editor_catalog_test` 读 `helperText` 的用例、`agent_template_controller_test` 窗口必填断言等，0.1 回填精确清单）按新语义改写，改前逐条贴红证据。

**D6 缺省思考强度 = 目录档位取中间档（2026-11-09 用户裁定「缺省值给中间档」）。**
解析规则（与 D7 同一注入点）：显式合法档（`kThinkingEfforts` 五档 low/medium/high/xhigh/max）**永远优先**；缺键时，该模型目录条目的 `reasoningEfforts` 含 none 之外的合法档 ⇒ 取其中**按 `kThinkingEfforts` 顺序的中间档**（flash：low/high/max ⇒ high；qwen：low/medium/xhigh ⇒ medium）；`reasoningEfforts` 为空/全 none/目录缺失 ⇒ `disabled`（不变得更糟）。**理由**（对抗审查裁决）：字面 `medium` 在 flash 目录里不存在，硬发 medium 会被上游映射成 high（`Docs/DeepSeekAPIDoc.md` §2.7.1 注(2)），造成"Dart 侧 resolved=medium / 实发=high"的双重口径；"按目录取中间档"让 resolved=实发，且对声明了 medium 的模型真的取到 medium。`reasoning` 谓词定义：目录条目的 `reasoningEfforts` 非空且含 none 之外的 `kThinkingEfforts` 档（目录没有 reasoning 布尔，不许 apply 时私加字段）。

**D7 推理强度每轮重解析，其余字段维持创建时生效。**
`AgentFactory.create` 给 Agent 注入两个查找器：模板查找器（按 agentTypeName 查当前注册表）与目录查找器（按 provider 名查当前探测结果）；每轮装配时重新解析思考模式/强度（与 D6 同一推导）；窗口/工具/模型/系统提示词仍创建时生效。范围严格限定——`context-occupancy-ring` 的实例窗口条文不动；**在途粒度**：同一轮里，已发出的请求保持原参数，该轮后续模型请求仍用保存前的强度（保存从下一轮装配起生效——"下一消息"的精确语义）。实例创建后第一次装配即解析一次（运行实例也立刻吃到目录推导的缺省，不靠创建时的快照）。生效时机提示（模板菜单 `kAgentTemplateEffectiveNote` 与 `main.dart` 的 SnackBar）统一改成新口径："只有推理强度从下一条消息起对运行中对话生效，其余字段对新会话生效"。

## Risks / Trade-offs

- **[首启要求网关可达]** 没网关就完不成首启（探测门挡住 Start）→ 与"装完就能用"冲突，但这是"模型名/窗口来自目录"的必然代价；错误文案给明出路（先起网关、在 Providers 页探测）。
- **[目录优先于覆盖]** 用户写的小覆盖（想省 token）会被目录值忽略并打日志 → 行为写进文档；要"强制小窗口"没有开关（不做配置项）。
- **[D6 中间档随目录漂移]** 不同模型缺省档不同（flash→high、qwen→medium），用户看到的"缺省"不是固定字面 → 这正是"从网关读"的语义；文档写明。
- **[D7 每轮解析的成本与一致性]** 每轮一次模板+目录查找，成本可忽略；查找器读到的是注册表/探测结果的当前引用，无需监听机制（不新建回调通道）。
- **[双缺失败的兼容]** 现有合法配置（目录已探测或带覆盖）全部不受影响；只有"未探测且无覆盖"的裸配置会从静默回落变显式报错——把半月无人察觉的 1000 式沉默换成可见失败，是本 change 的目的。

## Migration Plan

纯行为变更，无数据迁移。已有配置兼容：带窗口覆盖的继续当回落用（目录缺失时）；带脏模型名的从此看得见。回滚=回退代码提交。用户文档随代码同 change 更新。
