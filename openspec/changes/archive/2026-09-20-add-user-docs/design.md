## Context

**现状（2026-09-20 核对）**：仓库里面向用户的文档只有 `README.md`（65 行：环境要求 / 构建运行 / 配置 / 测试 / 项目结构），**没有任何功能使用说明**，README 里也没有功能索引。`Docs/` 下已有的都是**开发者向**的文档：`TESTING.md`（怎么写测试）、`DEBUGGING.md`（C++ 侧车调试）、`context-compression-reference.md`（压缩机制的设计参考）、`known-bugs.md`、`rejected-approaches.md`、两份 API 文档整理。

**用户可见的功能（照代码清点，不是凭印象）**：

- **界面**：会话列表（新建 / 删除 / 自动标题）、对话区（消息气泡、工具调用卡片、思考卡片、流式输出）、「对话视图 / 真实上下文」切换、输入框与发送按钮、首次启动的欢迎对话框（`API Key` + `Max Context Tokens` 两个输入）。
- **工具（13 个，全部由模型调用，不是用户直接点）**，注册分三批（照 `lib/main.dart` 的 `_initSearchAndTools` 数出来）：
  - 无条件注册 7 个：`read_file`、`write_file`、`edit_file`、`list_dir`、`glob_file`、`grep_file`、`get_current_time`
  - 只有本机浏览器栈可用时才注册 4 个：`browser_navigate`、`browser_click`、`browser_type`、`browser_snapshot`
  - 只有配置了搜索服务时才注册 2 个：`web_search`、`web_fetch`
  - **`browser_available` 不是工具**：它是启动时问一次"本机浏览器能不能用"的探测（`_sidecar.browserAvailable()`），用来决定上面那 4 个浏览器工具要不要注册，**模型不能调用它**。
- **配置**：`~/.aliasagent/config.json` —— 供应商（`api_key` / `base_url`）与 agent 类型（`provider` / `model` / `system_prompt` / `tools` / `max_context_tokens` / `thinking_effort` / `standing_requirements` / `compaction_threshold_percent`）。
- **两条最容易踩的前提**：①**文件类工具只能碰工作区内的路径**，而工作区是**用户主目录**（代码里 `_sidecar.setWorkspace(ConfigService.homeDir)`），越界会直接被拒；②`web_search` 需要**付费搜索服务**的 key，没有可用服务时搜不了。

**约束**：本变更**不改任何产品代码**（`lib/`、`sidecar/`、`scripts/` 一行不动）；文档内容必须照**当下代码的真实行为**写，逐条核对来源，不照记忆写、不写"打算怎么做"。

## Goals / Non-Goals

**Goals:**

1. 一个没读过代码的人，只凭 README + `Docs/user-guide/` 就能把每个功能用起来，并且知道出错时看到的现象是什么意思。
2. README 成为**总入口**：每个功能一句话 + 链接到它的使用说明。
3. 加一条**能失败的**一致性校验，抓住三类腐烂：索引漏了文件 / 文件漏了索引、文档里的配置键代码里没有、文档里的工具名代码里没有。
4. 文档与代码的对应关系**当场可核**（键名从产品代码的解析路径取、工具名从工具清单取、界面文案从 UI 代码取）。

**Non-Goals:**

- **不写开发者文档**：构建、测试分层、侧车调试、内部设计已经分别在 `README.md`、`Docs/TESTING.md`、`DEBUGGING.md`、OpenSpec 工件里，本变更不重复也不搬动它们。
- **不做多语言**：只写中文（与应用界面文案一致）。
- **不写"内部怎么实现"**：使用说明里不解释压缩算法、不解释 FFI、不解释目录结构。
- **不承诺没实测过的行为**：写不出"出错时会看到什么"的功能，就不编那句话。
- **不改产品代码**，也不为了让文档"更好写"去改界面文案。

## Decisions

### D1 文档放 `Docs/user-guide/`，每功能一份

`Docs/` 下已有开发者文档，用户文档单独放一层，避免与它们混在一起；文件名用功能名（kebab-case），README 里按同一顺序列索引。

**备选与否决**：把使用说明都塞进 README —— **否**。README 是"装起来、跑起来"的入口，塞进 8 个功能的使用细节会变得又长又难找；反过来，每个功能只在 README 里写一句、细节放文档里，读者能按需往下钻。

### D2 按"用户要做什么"切，不按代码模块切

8 份文档按功能切：对话 / 真实上下文视图 / 上下文压缩 / 文件类工具 / 联网工具 / 浏览器工具 / 配置 / 常见现象。**不**按 `lib/services/*` 的模块切 —— 读者找的是"我想干这件事怎么做"，不是"这段代码在哪"。工具类按"要碰什么"分三份（本地文件 / 联网取数 / 开浏览器），因为这个分法决定了用户要准备什么（工作区路径 / 付费搜索 key / 本机浏览器）。

### D3 每份文档都要覆盖同样几件事，但不强制小节标题

覆盖：**这是什么**（一句话）→ **在哪用**（界面上哪里，或说明它由模型自动调用）→ **怎么操作**（步骤或示例）→ **参数 / 配置**（有就写，没有就说没有）→ **出错时会看到什么**（照代码里的真实措辞写）→ **限制**（已知做不到的事）。

**为什么不强制固定小节标题**：标题服务于可读性，硬套模板会让短文档长出空章节；但**内容必须覆盖这几件事**，写的时候逐条对。

### D4 一致性校验只查三类"能机械核对"的东西

`test/unit/user_docs_test.dart` 查：

1. **索引 ↔ 文件双向一致**：`Docs/user-guide/` 下每个 `.md` 都能在 README 里找到链接；README 索引里链的每个文件都真实存在。
2. **配置键存在**：文档里出现的 `~/.aliasagent/config.json` 的键（`api_key`、`base_url`、`provider`、`model`、`system_prompt`、`tools`、`max_context_tokens`、`thinking_effort`、`standing_requirements`、`compaction_threshold_percent`），都要能在产品代码的解析路径里找到（`AgentTypeConfig.fromJson` / `toJson`、`ProviderConfig`、`ConfigService` 读配置那几处）。
3. **工具名存在**：文档里写的工具名（`read_file` 等 13 个），都要能在代码注册的工具清单里找到。

**明确不做**：**不**自动判断"说明写得准不准"。那种断言只能写成恒真（比如"文档非空"），写出来是自欺。**能核的只有名字对不对得上**；内容准不准靠人读，并且靠 `CLAUDE.md` 里那条"改动功能必须同步改文档"的规定在评审时兜住。

**为什么不把校验写成"必须先有文档才能提交"的钩子**：本工程没有 pre-commit 钩子体系，加一个是另一个变更的事；放进 `flutter test` 的单元层已经能挡住"跑了全量测试还漏文档"。

### D5 内容逐条照代码核对，写清来源

写每份文档时按下表取值，**不凭记忆**：

| 要写的东西 | 从哪取 |
|---|---|
| 界面文案（`对话视图` / `真实上下文` / `Send` / `New Chat` / `Delete session` / 欢迎对话框标题与字段名） | `lib/main.dart`、`lib/ui/chat_area.dart`、`lib/ui/setup_dialog.dart` 里的字符串 |
| 工具名与它们的说明 | `lib/main.dart` 里的工具定义 |
| 配置键与缺省值 | `lib/models/agent_type_config.dart`、`lib/models/provider_config.dart`、`lib/services/config_service.dart` |
| 工作区边界 | `_sidecar.setWorkspace(ConfigService.homeDir)` |
| 压缩触发与摘要标记 | `CompactionEngine.thresholdTokens`、`lib/services/compaction/summary_provider.dart` 里的两个标记字符串 |
| 报错措辞 | 工具实现里返回的错误文案（读代码取原话，不改写） |

## Risks / Trade-offs

- **[文档会腐烂]** → D4 的三条校验能抓住"名字对不上"这一类；内容层面的漂移靠 `CLAUDE.md` 的同步规则 + 评审。**如实说**：自动校验管不到"说明是否过时"，这是这条路的固有缺口。
- **[8 份文档之间内容重叠]** → 重叠的内容只在一处写全，别处链接过去（例如"工作区边界"在 `tools-file.md` 写全，`troubleshooting.md` 只链接）。
- **[`troubleshooting.md` 容易变成"许愿池"（写没验证过的猜测）]** → 只写**代码里确实会出现的现象**（错误文案可核），不写"可能是网络问题"这类猜测。
- **[文档写"将来要支持"的东西]** → 禁止。本变更只描述当下行为；想做的新功能各自走 change。
- **[README 变长]** → 只增一节索引（每功能一行），细节不塞进 README。

## Migration Plan

无数据与兼容性影响：只新增文档与一个纯文件读取的单元测试。回滚就是删掉这些文件。

## Open Questions

1. **要不要给 `troubleshooting.md` 配截图？** 界面截图能显著降低理解成本，但截图会随界面变化而过期，而本工程没有"截图过期"的自动检查。**处置**：本变更先用文字 + 界面文案（可核），截图留到以后单独议；不阻塞。
2. **每个功能文档要不要都带一段"它由模型自动调用，你不用手动点"的说明？** 工具类文档容易让用户以为要自己调用。**处置**：写，统一放在"在哪用"那一段的第一句（这属于 D3 覆盖的一项，不是新增结构）。
