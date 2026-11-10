# Tasks: model-truth-from-gateway

按物理顺序执行。回链：窗口规则=目录为准/覆盖兜底/双缺显式失败（design D1，不设数字回落）；首启=向导内探测门+目录第一项+目录写回（D2）；缺键合法、补问入口全拆（D3）；脏值按编辑器打开时快照、以 `discovered_at` 判定（D4）；思考=显式五档>目录中间档>disabled（D6）；强度每轮装配重解析、其余字段创建时生效（D7）。**凡"读码回填"处，先亲自读码把事实写进备注再动手。**

## 0. 事实回填（动手前）

- [x] 0.1 读码回填五项并写进本条备注：① `agent.dart` 全部窗口读取点（对抗审查实测 8 处 6 方法，列全）与现状回落逻辑；② `AgentConfigResolver.resolve` 现状（isValidWindow 拒 null/<=0 等）与 `ResolvedAgentConfig.maxContextTokens` 类型；③ 补问触发的精确判定位置与"删后是否还剩任何触发"的实况；④ `ModelCatalogEntry` 的真实字段名（`contextWindow`/`reasoningEfforts`/`discoveredAt` 等）与 Provider 目录在运行时怎么查（按 provider 名）；⑤ `AgentFactory.create` 的签名与依赖——确认注入模板/目录查找器的挂点（D7 承重墙）
  - 备注①（窗口读取点，全部读 `ResolvedAgentConfig.maxContextTokens`，无一处回落数字）：`_callModel`（`final maxContextTokens = config.maxContextTokens;` 入口一处）、`_maybeScheduleBackgroundFold`（`if (config.maxContextTokens <= 0) return;`）、`_runBackgroundFold`（`buildTree(maxContextTokens: config.maxContextTokens)`）、`_loadClosedSegments`（`thresholdTokens(config.maxContextTokens, …)`）、`_prepareSeamChooser`（`resolveFoldSeamInputs(maxContextTokens: config.maxContextTokens)`）、`_resolveSummariesInner`（`thresholdTokens(...)`、`total > config.maxContextTokens`、超预算日志里的 `total - config.maxContextTokens` 与字面 `maxContextTokens` 各一处——同一条表达式）。合计 **8 处 / 6 个方法**。现状回落逻辑：`Agent` 侧没有回落，只有 `> 0` / `<= 0` 两个分支（0 是旧数据遗留 ⇒ 不压缩、不留环），数字全部来自 `resolve`；`tool_catalog.dart` 的 `ToolListMigration` 只做字段搬运，不读窗口语义。
  - 备注②（resolver 现状）：`resolve` 先 `isValidWindow(template.maxContextTokens)`（拒 null / <= 0）⇒ 抛 `InvalidAgentContextWindowException`，随后 `maxContextTokens: template.maxContextTokens!`；`ResolvedAgentConfig.maxContextTokens` 是**非空 `int`**。`AgentConfigResolver` 只持有 `ProviderResolver`（`Map<String, ProviderConfig>`）——因此目录可由 `providers.resolve(name)?.models` 直接取，**不需要**新增注入；`resolve` 单点即可拿到目录与覆盖值。
  - 备注③（补问触发实况）：唯一活的触发在 `lib/main.dart` 的 `_loadConfig()` → `addPostFrameCallback` 里 `registry.lookup('general')?.maxContextTokens` 为 null / <=0 ⇒ `_showSetup()`（注释即 "R1-7"）。另一个入口是 `ConfigStatus.notFound`（首启，不是补问）。日志/发送期另有两处 `Configuration Error` / `MissingAgentProviderException`，与补问无关。**删掉 R1-7 这处后，产品里再无任何"缺 max_context_tokens"的自动补问入口**（2.2 已按此实况核对）。
  - 备注④（`ModelCatalogEntry` 真字段）：`id`、`displayName`（JSON `display_name`）、`contextWindow`（JSON **`context_window`**，非正/缺失 ⇒ null）、`maxOutputTokens`、`inputModalities`、`outputModalities`、`reasoningEfforts`（来自 `supported_reasoning_levels[].effort`；null=字段缺失，`[]`=无已知档位）、`nativeEndpoints`、`pricing`；**没有 reasoning 布尔**。已探测判定：`ProviderConfig.discoveredAt`（JSON `discovered_at`，null=从未探测）。运行时查询：`ProviderResolver.resolve(providerName)?.models` 按 `id` 命中；探测写回能力入口 `ProviderCatalogDiscovery.discover(config, name)`（`ModelDiscoveryReport` 带 `entries`/`discoveredAt`/`config`，但**探测即写盘**），低层可注入接口是 `ModelCatalogProbe.fetch(baseUrl, apiKey, previewChars)`。
  - 备注⑤（`AgentFactory.create` 挂点）：签名 `Future<Agent> create(Session session, {AgentCallbacks callbacks = const AgentCallbacks(), ChildRunOptions? child})`；工厂已持有 `templates`（`AgentTypeRegistry`，`lookup(name)` 永远读到注册表当前引用）与 `providerResolver()` getter（生产返回 `main.dart` 的全局 `resolver`，Provider 改动时被整体替换），并在创建时把 `template`（`AgentTypeConfig`）交给 `Agent`。D7 挂点：给 `Agent` 加两个可选查找器（模板按 `agentTypeName` 查 `templates.lookup`；目录按 provider 名查 `providerResolver()?.resolve(name)?.models`），由 `AgentFactory.create` 注入；`Agent` 在 `_callModel` 开头（**每轮装配**）重解析思考档并写进该轮局部变量，窗口/工具/模型/提示词仍用创建时冻结的 `ResolvedAgentConfig`。
  - 备注⑥（受影响既有用例清单，供 1.3 / 2.3 / 3.2 逐条点名）：**窗口语义**：`test/unit/agent_template_controller_test.dart` 的"非法上下文窗口（零、负数、非整数）"循环里 `''`（=必填）这一项、`test/widget/agent_template_editor_test.dart`（模板侧窗口）——这两处随"缺席合法"改；`test/unit/resolved_agent_config_test.dart` 的"缺失/零/负数都拒绝创建"**不改**（双缺仍然抛错，消息保留"正整数""拒绝创建"）；`agent_session_restore_test` / `context_ring_agent_config_test` / `session_agent_controller_test` / `input_location_test` 的 `maxContextTokens: 0` 用例**不改**（0 + 无目录仍显式失败）。`agent_runtime_real_bridge_test` **不受影响**（provider `local` 无目录 ⇒ 覆盖值兜底；beta 无目录 ⇒ disabled），故 1.3 只点名真正会红的那几条。**补问触发**：`test/widget/app_shell_test.dart` R1-7 断言反转、`test/widget/setup_dialog_test.dart` 全部窗口输入/写出断言。**思考档**：`test/integration/agent_template_apply_test.dart` 的 `sidecar.lastThinkingEffort == 'high'`（保存后第二轮按 D7 应变 `low`）与生效时机 SnackBar 文本断言。**脏值 helperText**：`test/widget/template_editor_catalog_test.dart` 的"不在最近一次目录中"那条。**实测修正**：`agent_template_editor_test` 最终**不需要改**（它填的是窗口覆盖值，换模型确认框与保存断言都仍成立）；真正会红的只有 `agent_template_controller_test` 的 `''` 那一项（见 1.3 红证据）。

## 1. 窗口解析链与思考推导（Dart）

- [x] 1.1 在 `AgentConfigResolver.resolve` 单点实现 D1 窗口链（目录正数 `contextWindow` 为准；目录缺失用配置覆盖；双缺抛带模板名的错误、消息给两条出路）+ D6 思考链（显式五档优先；缺键按 `reasoningEfforts` 取 `kThinkingEfforts` 顺序中间档；空/全 none/无目录→disabled）；覆盖与目录不一致时 `debugPrint` 点名被忽略的覆盖值；8 个消费方继续读解析结果、公式零改动
- [x] 1.2 扩展 unit 用例（断言窗口数值与 `debugPrint` 捕获——沿用 `test/unit/agent_type_config_command_test.dart` 的日志捕获手法）：窗口三场景（目录为准含"有覆盖也按目录且打日志"、目录缺失用覆盖、双缺抛错且消息含模板名与两条出路）+ 思考三场景（flash 档位→high、qwen 档位→medium、空/未探测→disabled、显式 xhigh→xhigh）。贴全绿输出
- [x] 1.3 既有测试点名改（先贴改前红证据再改）：`agent_template_controller_test` 的窗口必填断言、`agent_runtime_real_bridge_test` 等钉旧窗口语义的用例（0.1 列全后逐条点名）。贴改后绿输出
  - 改前红证据 `%TEMP%\mtg_apply_1.3_before.log`：`test/unit/agent_template_controller_test.dart` 的"非法上下文窗口（零、负数、非整数）"在 `''` 一项 `fail('这次保存必须被拒绝')`（因为 1.1 落地后窗口留空=合法）。改后拆成两条（0/-1/abc 仍拒绝 + 留空保存成功且配置里无该键），绿输出 `%TEMP%\mtg_apply_1.2.log`（`+44: All tests passed!`）。`agent_runtime_real_bridge_test` 经 0.1 复核**不受影响**（其 provider 无目录 ⇒ 走覆盖值；beta 缺 `thinking_effort` 且无目录 ⇒ disabled），故不改。
  - 本条的**产品侧配对改动**（没有它就造不出"缺席"状态，D1 的"缺席合法"无从落地）：`AgentTemplateController.validate` 把空窗口当"无覆盖"（`maxContextTokens: null`，不写该键），只在非空且非正整数时拒绝；`AgentTemplateEditor` 的窗口 helperText 改为"留空 = 用网关目录的窗口；填了 = 目录缺失时的覆盖值"，且窗口留空时跳过"换模型确认窗口"弹窗（没有值要确认）。三处测试改动与它们一一对应，未放松任何非法值校验（0/-1/abc 仍逐条被拒）。

## 2. 首启向导改造（Dart）

- [x] 2.1 按 D2 改造 `setup_dialog.dart`：删硬编码模型串与窗口输入步；注入探测依赖（按 0.1④的目录查询能力），第二步执行探测、成功且目录非空才放行 Start；模型下拉用目录条目（显示 display_name、存 id）、缺省第一项；同一次保存写回 `providers.<名>.models`（`ModelCatalogEntry` 形状）与 `discovered_at`；写回配置无 `max_context_tokens` 键；头注释按新语义整段重写（含"为什么能砍补问触发"）
- [x] 2.2 删除"缺 `max_context_tokens` 触发补问"的判定（0.1③的位置）；核对删后产品确无其它活的补问触发，把实况写进备注
  - 备注：删掉的是 `lib/main.dart` `_loadConfig()` 里 `ConfigStatus.ok` 分支的 `addPostFrameCallback`（原 `registry.lookup('general')?.maxContextTokens` 为 null/<=0 ⇒ `_showSetup()`），整段连注释一起删除并换成 D3 的说明。删后逐出口核对实况：① `_showSetup()` 现在只剩 `ConfigStatus.notFound` 一个调用点（首启，不是补问）；② 全 `lib/` grep `maxContextTokens == null` / `_showSetup`，除编辑器/控制器对"覆盖值可空"的正常处理外没有任何对话框触发；③ 缺密钥等其它"触发"现状是 `Configuration Error`（启动期结构错）或发送期 `MissingAgentProviderException`，都不是活的补问入口。结论：**产品里已无任何"缺 max_context_tokens"的自动补问触发**，补问路径只剩"合并既有配置"这一用途。
- [x] 2.3 既有测试点名改（先贴改前红证据）：`test/widget/setup_dialog_test.dart` 的窗口输入/写出断言、`test/widget/app_shell_test.dart` R1-7（补问触发判据反转）等（0.1③列全后逐条点名）。贴改后绿输出
  - 改前红证据 `%TEMP%\mtg_apply_2.3_before.log`（7 红）：`renders API key + max context tokens fields`（找不到 `Max Context Tokens`）、`valid API key triggers onComplete`、`补问合并现有配置`、`补问时改 Provider 名`、`missing max context tokens shows validation error`、`两步都过才 onComplete`（找不到 `setup-max-context-tokens`）、`app_shell_test` R1-7（`SetupDialog` 数=0，断言"必须弹"失败）。改后 `%TEMP%\mtg_apply_2.3_after.log`：`+17: All tests passed!`（新增"第 2 步=探测门/无窗口输入"、"探测失败挡 Start"、"空目录挡 Start"、"下拉显示 display_name、存 id"、"补问不碰模型/窗口"等）。

## 3. 脏值提示与生效时机（Dart）

- [x] 3.1 模板编辑器模型行按 D4 实现：`main.dart _openTemplateEditor` 把探测状态（最小为 `Map<String, String?> discoveredAtByProvider`）传入编辑器；已探测（有 `discovered_at`）且不含该模型→警示；从未探测→中性文案；提示按打开时快照，无实时通道
- [x] 3.2 widget 用例（先贴改前红证据）：点名 `test/widget/template_editor_catalog_test.dart` 读 `helperText` 的既有用例按新文案/新入口改；锁三场景（已探测不含→警示、未探测→中性、刷新后重开编辑器警示消失）。贴改后绿输出
  - 改前红证据 `%TEMP%\mtg_apply_3.2_before.log`：`手输目录外模型可保存，并显示中性提示"不在最近一次目录中"` 红（`Actual: '目录未探测：直接手填模型名（这不代表模型不存在）'`——旧用例没给 `discovered_at`，按 D4 判据就是"未探测"，不再是"不在最近一次目录中"）。改后 `%TEMP%\mtg_apply_3.2_after.log`：`+20: All tests passed!`，三场景 OBS 见该日志（已探测缺失→error 色警示点名模型名且仍可保存；未探测→中性文案且警示=0；刷新后重开→警示=0、中性=0、helperText=可从右侧目录选择）。
- [x] 3.3 生效时机 UI 文案统一：`lib/ui/agent_template_menu.dart` 的 `kAgentTemplateEffectiveNote` 与 `lib/main.dart` 的 SnackBar 改成新口径（"只有推理强度从下一条消息起对运行中对话生效，其余字段对新会话生效"）
- [x] 3.4 D7 接线：`AgentFactory.create` 注入模板/目录查找器；`Agent` 每轮装配时重解析思考模式/强度（在途轮仍用旧档，从下一轮装配生效）；集成用例锁"保存模板改强度→同一 Agent 第二条消息的思考参数为新档、第一条为旧档"

## 4. 文档与清查

- [x] 4.1 `Docs/user-guide/configuration.md`：窗口键语义改"覆盖兜底/缺席=目录/双缺报错"、首启样例去窗口字段、写明首启需网关可达；`Docs/user-guide/agent-templates.md` 补脏值提示与生效时机说明；文档守卫同步（能失败的判据）
  - 落地：`configuration.md` 改首启两步说明（第 2 步=探测门+模型下拉、无窗口输入）、首启样例（写出 `models`/`discovered_at`、无 `max_context_tokens`）、`max_context_tokens` 键语义行、错误表（探测失败/空目录/双缺红条），并写明**首启要求网关可达**；`agent-templates.md` 改生效时机文案与两段式语义、窗口字段可留空、换模型确认框只在填了覆盖值时出现、模型行两态提示表（已探测缺失=红字警示 / 未探测=中性）+ 无实时通道说明、缺省推理档=目录中间档、创建期红条新文案。守卫：`test/unit/agent_template_docs_test.dart` 新增「窗口语义、首启探测门与脏值提示的文档判据（4.1）」（代码文案↔文档双向、旧窗口控件文案不得出现、窗口三档语义与"首启要求网关可达"必须出现），并把旧的「已经运行的会话不会热更新」断言换成新口径（`只有推理强度会跟着变` + `kAgentTemplateEffectiveNote`）。红→绿证据：`%TEMP%\mtg_apply_4.1_docs_before.log`（旧断言红：文档已不含该笼统说法；另 `重新打开` 被禁用词拦，改成"再开一次编辑器"）→ `%TEMP%\mtg_apply_4.1_docs_after.log`（`+13: All tests passed!`）。
- [x] 4.2 全文 grep 清查：lib/ 不得残留硬编码模型 id（claude-sonnet、deepseek-flash 字面量）与写死窗口长度；结果贴进报告
  - 结果（`%TEMP%\mtg_apply_4.2_grep.log`）：① 模型 id 形态（`claude-*` / `deepseek/*` / `gpt-*` / `kimi*` / `qwen*`）在 `lib/` **零命中**（setup 里那处 `deepseek/deepseek-flash` 已随 2.1 删除）；② 常见窗口数值（1048576/200000/1000000/640000/262144/131072/128000/32768/8192/4096）只命中 `lib/services/image_budget.dart` 的**图片像素上限** 8192/4096（平台硬限，抄自 `Docs/DeepSeekAPIDoc.md` §6.4.3，与上下文窗口无关）；③ `maxContextTokens: <字面量>` 零命中——没有任何地方给窗口赋数字；④ 旧窗口输入控件文案（`Max Context Tokens` / `e.g. 200000` / `Compaction threshold (one-time setting)`）零命中。

## 5. 全量验证与变异（主循环批次执行）

- [x] 5.1 `scripts\sync_sidecar_dll.ps1` 后 `flutter analyze`（基线 161——出处 `%TEMP%\skill_9.1_analyze.log`，改动文件零新增）+ `flutter test` 全量贴 `+N All tests passed!`
- [x] 5.2 变异：把 1.1 的"目录值为准"分支删掉（恒走覆盖/失败）→ 1.2"目录为准"场景必须红；贴红证据后恢复，复跑全绿、改动文件哈希与变异前逐位相同
- [x] 5.3 `openspec validate model-truth-from-gateway` 通过贴输出
