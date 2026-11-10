# Proposal: model-truth-from-gateway

## Why

2026-11-09 用户连番问责暴露同一根因：**模型的事实参数（上下文窗口、模型名是否存在）写在配置里当唯一来源，而配置里的值可以错、错了没人看得见**：

1. `lib/ui/setup_dialog.dart` 首启缺省写死 `claude-sonnet-4-6`——magpie 网关上不存在这条路由，应用装完就是哑的；这个值还顺着配置活了很久（live 测试被迫每次手工换模型再恢复）。
2. `max_context_tokens` 同样是手填裸数字，被写错过 1000（上下文上限 1000 token，几乎每条消息都触发压缩），半个月无人察觉——没有任何校验、没有任何可见告警。
3. 网关目录里这些值**本来就有**：探测接口返回每个模型的 `context_length` / `context_window` / `id`（2026-11-09 实测 `deepseek/deepseek-flash` context_length=1048576）。产品已经会读目录（模型下拉就是目录内容），却把这些事实存在配置里当真相，目录只用于展示。

用户裁定（原话）：「这种值不是应该从网关读的吗？」「不要让我再看到什么硬编码的傻逼上下文长度」。

## What Changes

- **上下文窗口以网关目录为事实源**：该模型在所属 Provider 当前目录里有正的 `context_window` ⇒ **一律以目录为准**；目录缺失（未探测 / 目录无此模型 / 值非正）⇒ 用配置键 `max_context_tokens` 的正整数覆盖；两者都没有 ⇒ **显式失败**（创建时报错、点名模板、给"去探测目录"与"写覆盖值"两条出路）——**不设数字回落**，产品里不再有任何写死的上下文窗口长度。覆盖与目录不一致时打一行日志点名被忽略的覆盖值。压缩阈值链（25%/75% 派生）只消费解析结果，公式不动。
- **首启缺省模型与目录写回**：删掉 setup 向导里写死的模型字符串（连同 flash 那处一并删除）；向导第二步现状**没有任何探测**（探测只有 Providers 页有——初版"本来就要求探测成功"是假事实，经代码核实），本 change 把第二步改成**探测门**：注入探测、Start 放行 = 探测成功且目录非空，探测到的目录同一次保存写回 `providers.<名>.models`（此后窗口解析与脏值判定都有事实源）；缺省模型 = 目录第一项（网关顺序，下拉可改）。
- **`max_context_tokens` 不再是补问触发条件**：配置缺这个键从此是合法状态（目录语义），首启向导删掉窗口数字输入步。删光后产品不再有任何自动补问入口（初版"保留缺密钥等其余触发"的说法经代码核实为死态/发送期异常，按现状如实写）。setup_dialog 头注释按新语义重写。
- **脏模型名可见**：模板编辑器模型行按**编辑器打开时的目录快照**判定：已探测但不含该模型 ⇒ 警示文案；Provider 从未探测（以 `discovered_at` 判定，**不得**用"目录为空"代替）⇒ 中性文案。只提示不改写配置（既有"目录刷新不回改已保存模板"条文不动）；无实时通道——Providers 页刷新后重开编辑器重算。
- **推理强度修改下一轮装配生效**（2026-11-09 用户问责「这个改完推理强度不立刻应用到对话是什么狗屁设计」）：`thinking_effort` 每轮装配时按最新模板与目录重解析（`AgentFactory` 注入模板/目录查找器）；运行实例从**下一轮装配**吃到新档，在途轮的后续请求仍用旧档；窗口/工具/模型/系统提示词维持创建时生效（窗口绑定实例的既有条文不动）。生效时机提示（模板菜单与 SnackBar）统一新口径。
- **缺省思考强度 = 目录档位取中间档**（用户裁定「缺省值给中间档」）：显式五档（low/medium/high/xhigh/max）永远优先；缺键时目录 `reasoningEfforts` 含 none 之外合法档 ⇒ 按 `kThinkingEfforts` 顺序取中间档（flash：low/high/max ⇒ high；qwen：low/medium/xhigh ⇒ medium——取"中间档"而非字面 medium，因为 flash 目录没有 medium，硬发会被上游映射成 high，造成"Dart resolved=medium / 实发=high"双重口径）；目录缺失或全 none ⇒ `disabled`。
- 文档：`configuration.md`（窗口键语义改"覆盖兜底/缺席=目录"、首启样例去窗口字段）、`agent-templates.md`（脏值提示与生效时机说明）同步；既有测试里把 `max_context_tokens` 当必填的断言按新语义更新（点名改、贴改前红证据）。

## Capabilities

### New Capabilities

（无）

### Modified Capabilities

- `agent-config`：ADDED「生效上下文窗口的解析顺序」（目录为准/覆盖兜底/双缺显式失败）与「缺省思考强度的推导」（五档白名单、目录中间档、disabled 兜底）；MODIFIED 主 spec 既有「Thinking effort in Agent Type config」的档位词表为五档。
- `setup-dialog-tests`：MODIFIED「validates input」（探测门替代窗口校验）与「creates config on valid submit」（模型=目录首项、写回目录、无窗口键）；MODIFIED「Setup dialog renders」的两步结构。
- `agent-template-management`：MODIFIED「模板保存保持配置完整并明确生效时机」（推理强度下一消息生效、其余字段创建时生效）；ADDED「目录中不存在的模型名可见提示」。
- `agent-runtime`：MODIFIED「每个 Agent 使用不可变的实例生效配置」——不可变范围收窄为窗口/工具/模型/系统提示词（思考强度除外）；双缺窗口时创建失败与该能力既有失败语义对齐。
- `context-occupancy-ring`：MODIFIED 窗口来源条文措辞（生效窗口按 D1 解析；窗口无法确定 ⇒ 创建失败，与 D1 双缺显式失败一致）。
- `context-compaction`：窗口消费术语随 D1 单点解析对齐（公式不变）。

## Impact

- **Dart**：`lib/models/agent_type_config.dart`（窗口解析语义注释与消费辅助）、`lib/services/agent.dart`（生效窗口解析点：目录值→覆盖值→缺省 的回落链，单点）、`lib/ui/setup_dialog.dart`（删硬编码模型串、删窗口输入步、缺省取目录首项）、模板编辑器（脏值可见提示）。
- **测试**：unit（回落链：目录值/覆盖值/双缺 三态；setup 写出的配置无窗口键、模型=目录首项）、widget（向导不再问窗口；脏值提示出现/消失）、integration（目录刷新后生效窗口跟随变化、配置覆盖优先）；既有钉"必填/缺键触发补问"的用例点名改。
- **文档**：configuration.md / agent-templates.md + 文档守卫。
- **不动**：压缩阈值公式（仍百分比派生）、目录刷新不回改配置的条文、C++/FFI。

不做：自动把脏模型名改写成目录里的近似项（只提示，不动手）；多 Provider 目录合并仲裁；窗口值的界面编辑（覆盖只能手编 config.json，与现状一致）。
