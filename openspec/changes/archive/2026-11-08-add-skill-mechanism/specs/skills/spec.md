# skills 能力（delta）

## ADDED Requirements

### Requirement: 技能目录的存放与发现

系统 SHALL 在应用启动时扫描全局技能目录 `<主目录>/.aliasagent/skills/`（Windows 主目录取自 `USERPROFILE`，与 `spill.cpp` 的 `home_dir()` 同源），把每个**真实子目录**下的 `SKILL.md` 作为一个候选技能纳入发现。技能目录整体不存在 SHALL 是正常状态（静默、零提示、不报错）；目录存在但整体不可读 SHALL 产生可见提示。本期 SHALL NOT 支持工作区一级的技能目录（用户拍板：只做全局），SHALL NOT 提供技能管理或安装界面（用户明令：不新增交互界面）——"安装"就是往该目录放文件。技能内容变更后的生效时机 SHALL 为重启应用（与规范"启动时载入元数据"同形），此限制 SHALL 写进 `Docs/user-guide/skills.md`。

#### Scenario: 没有技能目录时零打扰
- **WHEN** 用户从未创建 `<主目录>/.aliasagent/skills/`，启动应用
- **THEN** 启动不出现任何技能相关提示或错误，其余功能不受影响

#### Scenario: 放入即发现
- **WHEN** 用户把一个合法技能目录放入 `<主目录>/.aliasagent/skills/` 并重启应用
- **THEN** 该技能出现在技能目录里（下一轮请求的系统提示词可见其名字与描述）

### Requirement: SKILL.md 元数据校验

系统 SHALL 校验每个候选技能的 `SKILL.md`：首行恰为 `---` 才按 YAML frontmatter 解析到下一个独立成行的 `---`；字段 SHALL 按开放规范（出处 `Docs/AgentSkillsDoc.md` 第一节，数字为该规范的硬性字段限）校验——`name` 必填、1–64 字符、仅小写字母/数字/单个连字符分隔、不以 `-` 开头或结尾、无连续 `--`、且 SHALL 与父目录名一致；`description` 必填、1–1024 字符非空；`compatibility` 若提供则 SHALL 为 1–500 字符（提供但为空串 = 校验失败，与 `name`/`description` 同为 1–N 口径，出处 `Docs/AgentSkillsDoc.md` 第一节字段表原文"Must be 1-500 characters if provided"）；`license`/`metadata`/`allowed-tools` 为可选字段。规范六字段之外的键 SHALL 被忽略且 SHALL NOT 因此判失败（加载侧宽松口径，出处 `Docs/AgentSkillsDoc.md` 第二节对 Claude Code 行为的记载）。校验失败的技能 SHALL NOT 进入技能目录，且 SHALL 产生用户可见的汇总提示（每个失败技能一行：技能名 + 失败原因）并逐条写日志；提示与日志 SHALL NOT 含 provider 密钥等敏感串。无 frontmatter、YAML 解析失败、字段超限都属校验失败。

#### Scenario: 名字超限的技能不生效且可见
- **WHEN** 某技能的 `name` 为 65 个字符（超出规范硬限 64）
- **THEN** 该技能不出现在技能目录，且用户能看到一行含该技能名与"name 超过 64 字符"含义明确的失败原因

#### Scenario: 未知字段不挡加载
- **WHEN** 某技能 frontmatter 除规范六字段外还带 `context: fork`（Claude Code 扩展字段）
- **THEN** 该技能照常生效，`context` 键被忽略

#### Scenario: name 与目录名不一致
- **WHEN** 技能目录叫 `pdf-tools` 而 frontmatter `name` 是 `pdf-processing`
- **THEN** 校验失败，该技能不入目录且给出可见的失败原因

### Requirement: 技能目录注入系统提示词

系统 SHALL 在每轮请求的系统提示词里注入一段技能目录（拼接位置在 `guard.inject()` 动态段之后，装配点见 `lib/services/agent.dart` 系统提示词拼装处）：每个**生效**技能一行 `- <name>: <description>`，按 `name` 字典序排列，并附一句使用说明（提示模型先 `load_skill(skill)` 再遵循其指令）。注入不受模板工具清单影响（用户拍板原文「技能对所有 Agent 模板全量生效、无逐模板开关」，`TODO.md:162`）。没有任何生效技能时 SHALL NOT 注入空目录段（不留空悬句子）。`description` SHALL NOT 由本应用再做截断或改写（超长在校验处已挡）。目录段与 `load_skill` 工具定义 SHALL 同开同关：注入目录的那一轮，其 `tools` 数组 SHALL 含 `load_skill` 定义。目录段的 token SHALL 计入既有 `fixedOverheadTokens` 估算（现状对整段系统提示词的估算即覆盖，用例 SHALL 断言注入前后估算差与目录文本一致增长）。

#### Scenario: 所有模板都收到目录
- **WHEN** 存在 2 个生效技能，任一模板发起一轮请求（无论其 `tools` 清单是否写过 `load_skill`）
- **THEN** 发给模型的系统提示词含这两行目录（字典序）与使用说明句，且该轮 tools 数组含 `load_skill` 定义

#### Scenario: 无生效技能不注入空段
- **WHEN** 技能目录为空，或所有候选技能校验失败
- **THEN** systemPrompt 不含目录句子；tools 数组仍含 `load_skill` 定义（工具常驻，目录段随内容）

### Requirement: load_skill 无条件交付工具

系统 SHALL 新增工具 `load_skill`，交付形态为**每轮装配时无条件附加进请求的 `tools` 数组**：不进 `ToolCatalog.kBaseToolNames`（11 项不变）、不进模板勾选清单、不改动任何用户配置——「全量生效、无逐模板开关」（`TODO.md:162`）由此实现，「既有模板选择不被覆盖」规则（`agent-template-management`）因配置零改动而不触发。执行分组上 `load_skill` SHALL NOT 进入只读并发集合 `kReadOnlyToolNames`（不在名单中的名字自动逐个段执行，落安全侧，见 `tool_group_planner.dart` 既有规则）。请求形态 SHALL 为 `{"skill": "<技能名>", "file": "<可选相对路径>", "preview_chars": <配置值>}`，`preview_chars` 由 Dart 读 `spill.preview_chars` 随请求透传（与 `web_fetch` 同形），C++ 缺省兜底用 `spill::kDefaultPreviewChars`。执行落点 SHALL 在 C++ sidecar（`sidecar_api` 导出、经 `context_api` 绑定当前上下文——`web_fetch` 同形），文件读取、frontmatter 切除与交付形状 SHALL 复用共享实现 `spill::shape_stream`（该形状的全部不变量与"信封带量、写盘失败可见"条款对 `load_skill` 同样成立，见 `tool-output-spill` 能力）。落盘 tag SHALL 为 `skill`，文件名形如 `<6 位序号>-skill.txt`，序号在同一上下文内与 `stdout`/`content` 共表自增。**生效技能集合（Dart 校验产物）是加载的把关门**：Dart 派发 `load_skill` 前 SHALL 核对技能名在生效集合内，不在（含"目录存在但校验失败"）即返回 `ok:false` 带原因，SHALL NOT 把校验失败技能的内容交给模型；C++ 侧字符集与路径校验保留为直连 FFI 的第二道闸。

#### Scenario: 加载正文
- **WHEN** 模型调用 `load_skill` 且 `skill` 指向一个合法已生效技能、不带 `file`
- **THEN** 返回该技能 `SKILL.md` 中 frontmatter 之后的正文（frontmatter 不在返回内容里），短正文时 SHALL 为全文内联

#### Scenario: 加载附属文件
- **WHEN** 模型调用 `load_skill` 带 `file: "references/REFERENCE.md"`
- **THEN** 返回该文件全文（附属文件 SHALL NOT 被切除任何 frontmatter 段落）

#### Scenario: 未生效的技能名报错可见
- **WHEN** 模型调用 `load_skill` 传入磁盘上不存在的技能名
- **THEN** 返回 `ok:false`，错误文本 SHALL 含该技能名与原因，SHALL NOT 静默返回空内容

#### Scenario: 校验失败的技能加载被挡
- **WHEN** 磁盘上存在目录 `broken-skill/` 且其 `SKILL.md` 校验失败（如 `name` 超长），模型调用 `load_skill(skill: "broken-skill")`
- **THEN** Dart 生效集合拦截，返回 `ok:false` 且原因指明"校验失败"（可引用启动时的失败提示），该技能正文 SHALL NOT 进入模型上下文

### Requirement: 技能路径的双侧防护

`load_skill` 的参数校验 SHALL 两道独立把关：`skill` 名在 C++ 侧 SHALL 先按规范字符集校验（`Docs/AgentSkillsDoc.md` 第一节 `name` 字段规则），不合规直接 `ok:false`（不触文件系统）；`file` 参数 SHALL 与技能目录拼接后**平台规范化**（Windows `GetFullPathName`，与 `read_spill` 引用同款规则），规范化结果 SHALL 仍位于该技能目录（规范化后的前缀比较）之内，`..`、绝对路径、盘符改写一律拒。YAML 切除规则（首行恰 `---`、切到下一独立 `---` 行）SHALL 在 Dart 校验侧与 C++ 加载侧行为一致，SHALL 用同一组边角夹具互验（首行不是 `---`、值内含引号冒号、正文中出现独立 `---` 行）。规范「File references」段的 `Keep file references one level deep from SKILL.md.` 是面向技能作者的祈使句，SHALL NOT 被本项目实现为客户端路径深度校验规则（裁剪决策见 `Docs/AgentSkillsDoc.md` 第三节）。

#### Scenario: 穿越路径被拒
- **WHEN** 模型调用 `load_skill` 带 `file: "../../config.json"`
- **THEN** 返回 `ok:false` 且错误说明路径超出技能目录，`~/.aliasagent/config.json` 的内容 SHALL NOT 出现在结果中

#### Scenario: 非法字符的技能名不触文件系统
- **WHEN** `skill` 传入 `../evil` 或含大写字母的名字
- **THEN** 返回 `ok:false`，校验在字符集关卡即拒

#### Scenario: 两侧切除行为互验
- **WHEN** 对同一份边角夹具（正文中含独立 `---` 行的技能）分别跑 Dart 校验侧与 C++ 加载侧测试
- **THEN** 两侧认定的 frontmatter 边界 SHALL 一致（C++ 返回正文 SHALL 等于 Dart 侧解析后的同一区间）

### Requirement: 技能对子 agent 自动可用

技能目录与生效技能集合 SHALL 为进程内单份（扫描结果由服务单例持有，装配读同一份）；子 agent（`AgentFactory.create` 路径）SHALL 自动看到同一目录注入，无需单独注册或开关。

#### Scenario: 子 agent 继承目录
- **WHEN** 主会话模板含 `load_skill` 且有生效技能，主会话 spawn 一个子 agent
- **THEN** 子 agent 的首轮系统提示词含同样的技能目录段
