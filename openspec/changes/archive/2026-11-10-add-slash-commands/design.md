# Design: add-slash-commands

## Context

技能体系已落地（`~/.aliasagent/skills/` 全局目录、`SkillCatalogService` 每轮装配前增量重扫、`load_skill` 工具 + 生效集合闸门、提示词内创建简则）。用户侧缺一个显式触发器。TODO.md 已拍板：首版只做提示展开型，`/技能名` 显式触发；本地动作型与输入补全菜单不做。

发送链路（已核实代码）：`main.dart _sendMessage(text)` → `Agent.send(text)` → `_sendMessageRound` 把 **text 原样** `messageRepo.insert` 落库、进 `_history`、生成会话标题 → `_callModel(messages: snapshotMessages)` 在装配面把消息映射成 API 请求。实际的 per-message 映射循环在 `_buildApiMessages(List<Message>)`（`_callModel` 与压缩投影 `_buildCompactionProjection` 共用这一入口，对每个原文段各调一次）；`_callModel` 本身没有映射循环，只是调度方。**落库/标题/气泡全部发生在模型装配之前**——这是本设计的关键事实。

## Goals / Non-Goals

**Goals:**

- 用户输入 `/技能名 正文`，模型该轮收到的 user 文本是"先 load_skill 再干活"的完整指示 + 用户正文。
- 用户在**对话视图**看到的（气泡、标题、历史、落库）永远是手打原文；既有「真实上下文」屏按既有规范（快照=实际发出的 apiMessages）会显示展开后的模板全文——如实披露，不加遮掩、不改既有屏。
- 行为是**纯函数 + 幂等**：同一文本在同一生效集合下任何一轮判定结果相同。

**Non-Goals:**

- 本地动作型命令、命令面板、输入补全弹菜单（用户首版明确排除）。
- 自定义模板 / 参数语法（`/name --flag` 的 `--flag` 只是正文一部分）。
- 对 assistant / tool 消息做任何变换；只对 user 消息生效。

## Decisions

**D1 展开点在模型装配面，不在发送入口。**
候选位置比对：① `main.dart _sendMessage` 展开后再 `agent.send`——**被否**，因为 `_sendMessageRound` 会把收到的 text 落库并进历史，展开文本会污染气泡、历史与会话标题（`updateTitleIfDefault` 用 text 起标题）；② `Agent.send` 加平行参数——被否，签名复杂度换不来好处；③ **装配面**（选定）：`Agent._buildApiMessages(List<Message>)` 的 per-message 循环里、构造 `{'type': 'text', 'text': msg.content}` 的那一处，按 `msg.role == 'user'` 用展开结果替换写入的文本块。`_callModel` 与压缩投影 `_buildCompactionProjection` 共用 `_buildApiMessages`（对每个原文段各调一次），所以压缩投影里的历史 user 消息一并判定——这正是 spec「进入本次请求的每一条 user 消息」的实现点。**禁止**在 `_callModel` 工具轮或装配后的 apiMessages 层做替换：那里 role=='user' 的条目可能是 tool_result 块列表（content 是 List，不是 String），会与 spec 的负向要求冲突。落库/标题/气泡早于装配，天然不受影响。

**D2 判定规则：逐字命中、当轮集合、进入本次请求的全 user 消息。**
- 判定对象：消息文本**第一个字符是 `/`**（空串直接透传，不做首字符判定）；首段 = 第一个 `/` 之后到首个空白字符或文本末尾为止的子串；**空白字符的集合钉死为 U+0020（空格）、U+0009（制表）、U+000A（换行）——全角空格 U+3000 不算空白**，所以 `/edge-skill　正文`（全角空格）的首段是整个 `edge-skill　正文`、不命中；首段**逐字等于当轮生效技能名**（`SkillCatalogService.instance.activeSkillNames`，命中口径是设计决定：技能名受 `skill_frontmatter.dart` 的 `validateSkillMd`/`_kSkillNamePattern` 约束只含小写字母/数字/连字符，大小写不一致=不命中）。
- 命中后余下正文 = 首段之后跳过一个空白的剩余文本（可为空——空正文也展开，只发加载指示）。
- **进入本次请求的每一条 user 消息都判定**（不止最后一条）：第二轮及以后历史里那条 `/技能名` 仍按**当轮**集合展开，语义逐轮一致（与技能热刷新同哲学：装配面永远反映当轮现状）；纯函数天然幂等，重复装配无漂移。生效名单在 `_buildApiMessages` 的逐条循环外取一次（`final activeNames = SkillCatalogService.instance.activeSkillNames;`），循环内复用同一份；**禁止**缓存到 Agent 字段或构造期快照（当轮语义由每轮开头的 `scan()` + getter 保证）。
- **范围限定**：被压缩折叠进摘要的 user 消息不再接受展开、也不再携带加载指示（摘要按原文生成），属压缩能力的既定损失，首版不补偿。
- 未命中一律原样透传：无报错、无提示、无界面——零新增 UI 的代价就是静默透传，如实写进文档已知限制。
- 子 Agent 任务文本的副作用事实：`subagent_runner.run()` 里 task 先 `.trim()` 再 `child.send`，故 `expandSlashCommand` 的判定对象是 trim 后的文本；父路径用户手打文本不 trim（`main.dart` 的 `_submitInput` 原样传 `_inputCtrl.text`），同一条带前导空白的串在两条路上命中结果不同——这是子 Agent 任务入口的既有行为，本 change 不改。子任务若以 `/技能名` 开头会被展开，这是按 role 判定的副作用，不是本变更承诺的触发方式。

**D3 替换模板是单个固定常量，不开放配置。**
模板（中文，与界面语言一致；模型对目录段/简则的中英混排已有先例）形态钉死：**固定前缀句 + "\n\n" + 余下正文**；无正文时文本止于前缀句后的两个换行。前缀句（精确措辞以此为准）：`已按斜杠命令展开技能 "<技能名>"：请先调用 load_skill(skill: "<技能名>") 读取该技能说明并严格遵循其中的指令，然后处理下面的请求：`。**不新增配置项、不发明上限数字**——模板长度是固定常量，token 随正文自然增长，无阈值可言。措辞由 tasks 1.1 的常量注释与 tasks 1.2 的整段逐字断言钉死（前缀固定、正文拼接；这是设计决定，把"固定常量"的定位锁进可失败用例）。

**D4 纯函数住独立文件，返回单个 String。**
`lib/services/slash_commands.dart`：`String expandSlashCommand(String text, List<String> activeSkillNames)`——命中返回模板拼接结果，**未命中原样返回入参**（透传语义写在返回值里，调用方无条件使用返回值替换、无需任何判断）。无 IO、无状态、无结果对象（`expanded`/`skillName` 字段在首版没有消费方，不预留），单测全覆盖边界。

**D5 不计入 fixedOverheadTokens，但如实登记低报后果。**
展开文本属于 user 消息内容本身（随正文增长），不属于系统提示词固定开销；既有估算对 user 消息的口径不变，spec 不立新条文。如实登记后果（数字按代码实算，非预估）：模板文本只进模型装配面的请求体（`_buildApiMessages` → apiMessages / messagesJson），不计入 fixedOverheadTokens（那只装 systemPrompt + toolsJson），也不进任何消息 token 估算——`ContextBreakdown.verbatim`、`estimatedProjectionTokens` 与 `buildTree` 读的都是展开前的落库 `Message.content`（估算口径 4 字符/token、向上取整）。因此占用环与压缩等待门槛的读数按每条命中 user 消息**净低报约 20 token**（模板 91 字符 ≈ 23 token，但手打的 `/edge-skill` 11 字符 ≈ 3 token 本已计入；按 10 字符技能名、空正文计），历史里每条命中每轮按当轮集合重新展开、差值随命中条数线性累加。**本项目接受这一低报，不另改估算口径**；若将来要求读数与请求体一致，单独立任务把展开文本计入 breakdown 原文桶（会牵动 `fromTimeline`/`verbatim` 与对应单测），不属本 change。

## Risks / Trade-offs

- **[静默透传]** `/ unknown` 或打错技能名时模型收到原文、可能困惑 → 缓解：用户文档写明规则（首段须逐字等于技能名）；模型侧有创建简则与目录，看到 `/xxx` 原文时可自行提示用户。不弹提示是零新增 UI 的既定代价。
- **[历史消息语义漂移]** 旧消息 `/name` 在技能被删后不再展开 → 与热刷新同哲学（当轮集合为准），spec 场景写死：第二轮按当轮集合重新判定。
- **[压缩折叠的消息不再展开]** 被折进摘要的历史 user 消息到不了 `_buildApiMessages` 的原文段 → 属压缩能力的既定损失（摘要本来就替代原文），首版不补偿，spec 已限定「进入本次请求」。
- **[真实上下文屏显示展开文本]** 该屏按既有规范显示实际发出的内容 → 不改既有屏、不改快照，proposal/design/spec 的断言收窄到「对话视图」，用户文档如实披露并给核实方法。
- **[模板措辞变更]** 模板前缀整段措辞由 tasks 1.2 的逐字断言钉死——改措辞必须同步 tasks 1.1 常量注释、1.2 断言与用户文档三处，改漏任何一处即红；这是把"固定常量"定位机器化的代价，措辞演进走正常任务流程。

## Migration Plan

纯新增行为，无数据迁移；回滚=回退代码提交。用户文档随代码同 change 发布。
