# Design: add-skill-mechanism

## Context

事实源：`Docs/AgentSkillsDoc.md`（开放规范全文，2026-11-06 抓取，字段硬限 64/1024/500 的出处）。用户拍板记录：`TODO.md`「技能与斜杠命令支持」条目（2026-11-06 两轮：专门工具加载、允许读附属文件、只做全局目录、不加任何交互界面、全量生效无逐模板开关）。

现状管道（均已实地核实）：工具定义唯一目录 `lib/services/tool_catalog.dart`（`kBaseToolNames` 11 项 + 条件注册）；系统提示词每轮拼装点 `lib/services/agent.dart` 的 `` '${config.systemPrompt}\n${guard.inject()}\n...' ``（`GuardAnchors::inject()` 是"每轮重新注入的动态段"先例）；工具派发 switch 与结果后处理同在 `agent.dart`；大输出交付契约在 C++ `spill::shape_stream`（`run_command`/`web_fetch` 共用，`web_fetch` 形状集中在包装函数、两个成功出口各调一次）；C++ 有 `spill.cpp` 的 `home_dir()`（Windows 走 `USERPROFILE`）与 `tools.cpp` 的 `canonical()`/`is_within_workspace()` 路径基建；启动就绪门 `_toolsReady` 在 `lib/main.dart`，迁移类可见提示有现成通道（`ToolListMigration.notices` 拼接上屏）；执行分组守卫在 `lib/services/tool_group_planner.dart`（两集合并集 = 全已知工具，按集合相等断言钉住）。

## Goals / Non-Goals

**Goals:**

- 全局技能目录（`~/.aliasagent/skills/`）的发现、规范校验、失败可见。
- 技能目录每轮注入系统提示词，且与模板工具白名单联动。
- `load_skill` 基础工具：正文与附属文件加载、目录穿越防护、spill 交付形状。
- 新用户与老用户**零配置改动**：`load_skill` 与技能目录在装配层无条件交付（对抗审查后修订——原"进 kBaseToolNames + 模板勾选"方案与用户拍板「全量生效、无逐模板开关」冲突，见处置记录）。
- 分层测试与用户文档同 change 落地。

**Non-Goals:**

- 斜杠命令与 `/技能名` 显式触发（用户拍板后置另立 change）。
- 工作区级技能、逐模板开关、技能管理/安装界面（用户明令"不新增交互界面"）。
- `allowed-tools` 预批准语义（本产品零审批全权限）、Claude Code 扩展字段（`context: fork`/`model`/`hooks` 等）、frontmatter 内 `` !`命令` `` 动态注入。
- 既有模板的配置文件工具清单**永不写入** `load_skill`（它在装配层无条件交付，根本不存在"追加"问题——`agent-template-management`「不得凭默认形状推断升级意图」规则因此不触发；对抗审查后修订，原方案把勾选当生效前提，与用户拍板冲突）。
- 技能文件的热更新（改文件重启生效，与规范"启动时载入元数据"同形）。
- symlink 技能目录（Claude Code 允许，本首版按真实目录，规范未强制）。

## Decisions

**D1 职责切分：目录侧 Dart，加载侧 C++。**
扫描/校验/目录文本组装在 Dart（服务化，新增 `lib/services/skills/`）；`load_skill` 的文件读取、正文切除、路径校验与 spill 形状化在 C++（新增 `sidecar/src/skill_tool.cpp/.h`，`sidecar_api.cpp` 导出 `load_skill(handle, request_json)`，经 `context_api` 绑定当前上下文——与 `web_fetch` L116 同形）。理由：落盘与形状机制只在 C++ 存在（`spill::shape_stream`），反向方案（Dart 读文件再回传 C++ 落盘）要新发明一条通用搬运入口，多一条跨语言管道且无先例。备选「全 Dart 不落 spill」否决：无截断即全文进上下文，违反"长资料按层加载"的技能本意，且绕开产品不变量（大输出先落盘）。

**D2 frontmatter 切法两侧同规，互为守卫。**
规则（与 Claude Code 行为同形，事实源第二节）：`SKILL.md` 首行恰为 `---` 才算有 frontmatter，切到下一个独立成行的 `---`；不满足 = 无 frontmatter = `name`/`description` 必填校验失败 = 该技能不生效且可见报错。Dart 用 `yaml` 包解析该块；C++ `load_skill` 返回"闭合 `---` 之后的正文"（不解析 YAML 语义，只做行切）。守卫：同一组夹具文件（含"首行不是 `---`""值内含引号/冒号""正文里出现 `---` 行"等边角）在 `test/unit`（Dart 解析）与 `sidecar/test`（C++ 切除）各测各侧、结果互相对得上；两侧规则文本都回链本节。

**D3 依赖引入用真实解析。**
`flutter pub add yaml`（package:yaml），解析出的版本号由 apply 执行时的命令输出落地进 tasks 记录，设计不预设版本号。pubspec 现有依赖均 pub.dev 常规包，无版本锁定策略冲突。

**D4 目录注入与 `load_skill` 定义无条件交付（对抗审查后修订，改前原文见处置记录）。**
注入段文本（英文，与现有拼装段同语言，示例形态）：
`Available skills (load one with load_skill(skill) before following its instructions; load_skill also reads files inside the skill directory): - <name>: <description>`。
依据用户拍板原文「技能对所有 Agent 模板全量生效、无逐模板开关」（`TODO.md:162`）：目录段与 `load_skill` 定义在**每轮装配时无条件交付**——目录段仅在有生效技能时注入（空目录不出空句子），`load_skill` 定义常驻该轮 tools 数组。`load_skill` 不进 `kBaseToolNames`（保持 11 项）、不进模板勾选清单、不写入任何用户配置。**修订前方案**：仅当 `config.tools` 含 `load_skill` 才注入目录 + `load_skill` 作第 12 项基础工具靠编辑器勾选——对抗审查判定这与用户拍板矛盾（勾选=变相开关，且「放入即发现」对老模板不成立），废弃。
目录顺序 = 生效技能 `name` 字典序（可测、稳定）。`description` 不截断（规范硬限 1024 已在校验处把关，超限=技能无效，无"截了还要可恢复"的负担）。注入发生在 `agent.dart` 每轮拼装点，`guard.inject()` 之后；`fixedOverheadTokens` 含整个 systemPrompt（现状即如此），目录开销自动进占用估算——用例断言这一点。

**D5 请求/响应形态。**
请求 JSON：`{"skill": "<name>", "file": "<相对路径，可选>", "preview_chars": <config.spillPreviewChars>}`——与 `web_fetch` 的 `preview_chars` 透传同形。响应进既有信封：`ok/content/total_bytes/omitted_bytes/ref` 等字段由 `spill::shape_stream` 决定（短→全文内联；长→头尾 `preview_chars` + 省略标注 + `read_spill` 可恢复），落盘 tag 固定 `skill`（文件形如 `<6 位序号>-skill.txt`；同一上下文序号继续全局自增，与 `stdout`/`content` 先例同表）。不带 `file` 返回 `SKILL.md` 正文（frontmatter 已切除）；带 `file` 原样返回文件全文（附属文件不切 frontmatter）。

**D6 路径与生效的三道闸（对抗审查 blocking-2 后修订）。**
第一道（新增，Dart 侧）：派发 `load_skill` 前核对技能名在**生效技能集合**（目录服务产物）内——不在（含"目录存在但校验失败"）直接返回 `ok:false` 带"校验失败/未生效"原因，不触 C++。修订前方案只有 C++ 两道，审查指出校验失败的技能仍可按目录名加载正文，"校验失败不生效"承诺在加载路径为假，故补此闸。
第二道（C++ 字符集）：`skill` 参数先按规范字符集校验（小写字母/数字/单连字符分隔，≤64，不以 `-` 开头结尾、无 `--`）——字符集本身排除 `.`/`/`/`\`，再拼 `home_dir() + "/.aliasagent/skills/" + skill`；与父目录名一致只在 Dart 校验侧把关（事实源第一节），C++ 靠"拼出来不存在就是可见错误"兜底；这道闸直连 FFI 时独立成立（不经 Dart 派发路径的调用也防得住）。
第三道（C++ 路径）：`file` 参数先拼接、再 `canonical()`（`tools.cpp` 现有函数同款语义），结果必须仍以该技能目录（canonical 后）为前缀，否则 `{"ok":false,"error":"..."}` 带完整原因。显式防御：事实源第一节「File references」段原文 `Keep file references one level deep from SKILL.md.` 是面向技能作者的祈使句，本项目**不**把它实现为客户端路径深度校验规则（措辞对照审查 m10：工件不称其"建议/要求"，只引用原文并声明裁剪）。

**D7 失败可见走现成提示通道。**
启动扫描在 `lib/main.dart` 的初始化链（`_toolsReady` 置位前完成一次，await；纯本地小文件 IO，延后可忽略）。校验失败技能：不入目录 + 汇总一条上屏提示（复用 `ToolListMigration.notices` 同形的界面提示串，不新建界面）+ 逐条进日志。技能目录不存在 = 静默正常（首次用户无技能是默认状态）；目录存在但不可读 = 可见提示。错误文案不得含 provider 密钥等敏感串（沿用既有迁移提示同款禁令）。

**D8 进程级单份目录，子 agent 自动继承。**
扫描结果存进程级单例服务（`ToolCatalog` 单例先例同形）；`Agent` 装配读同一份 → 子 agent（`AgentFactory.create` 同路径）自动可用，无需新机制。技能变更重启生效（Non-Goal 热更新）。

**D9 无条件交付的连锁面（对抗审查后按修订方案重算）。**
`load_skill` 定义存放于技能服务侧常量（**不进** `kBaseToolNames`、不进 `kSerialToolNames`；但定义 SHALL 注册进 `ToolCatalog` base 表——否则模板清单手写 `load_skill` 会 `UnknownToolsException` 打挂整次请求；注册的副作用=编辑器候选会列出它，勾选与否行为相同（装配恒追加），如实登记），交付点=单一入口 `agent.dart` 的 `toolDefinitions` getter：`resolve` 结果后追加 `load_skill` 定义（若清单恰已含同名项则去重不双发）。连锁判定（逐处核过）：①`test/integration/startup_tool_readiness_test.dart` 的"就绪后发出 13 个"断言变 14，"未就绪 11 个"变 12（定义注册进 base 表后同步即存在，与 6.1 落地口径一致），reason 文案同步——**必改**；②`test/unit/parallel_tools_docs_test.dart`（9+8/17 名单）与 `tool_group_planner` 集合守卫**不受影响**（`load_skill` 不在两集合也不在目录，"不在只读名单→逐个段"自动成立）——留一条回归验证任务而非改动任务；③`legacy_tool_migration_test`/`ToolListMigration` 不受影响（`kBaseToolNames` 未动）——留边界用例声明两类既有形状都不被改写；④新 DLL 导出绑定后 `scripts/sync_sidecar_dll.ps1` 再全量（`sidecar_dll_freshness` 先例）。

## Risks / Trade-offs

- **[D2 两侧切除规则漂移]** 一次改一侧忘另一侧 → 缓解：夹具互验用例 + 两侧注释回链同一节；对抗审查可查的失败态在守卫里。
- **[模型不调 load_skill]** 目录注入≠模型一定用（description 质量决定命中）→ 缓解：live 用例用真实技能 + 匹配话术断言实际调用；质量属技能作者责任，规范 best-practices 已在事实源引用。
- **[非 ASCII 附属文件名]** C++ 窄字符路径 API 下中文文件名可能取不到（与 `read_file` 现状同源的既有面，非本 change 新增缺陷）→ 处置：本 change 不扩面修复；失败返回可见错误文案；如实登记 `Docs/known-bugs.md` 一条（症状+根因方向+与本工具的既有同源关系），技能名本身限 ASCII 不受影响。
- **[用户不知道 load_skill 存在]** 定义不进编辑器清单、界面无入口（用户明令不新增界面）→ 处置：用户文档 `skills.md`「怎么算生效」写死"放文件重启即生效，无需任何勾选"；目录注入本身让模型每轮可见。
- **[目录每轮占上下文]** 每技能最多 1024 字符（规范字段上限，字符数≠token 数，对抗审查 m7 修正量纲表述）；token 量由 `ContextEstimator` 对整段系统提示词估算、经 `fixedOverheadTokens` 计入占用环（现状机制）→ 用户删技能文件即可减；不设技能条数上限（无合法来源，宁缺毋造）。
- **[首启链变长]** 扫描 await 进 `_initSearchAndTools` → 延后量级=本地目录读 N 个小文件；live 用例记录实际耗时于日志。

## Migration Plan

无数据迁移（配置零改动即升级）；新增 FFI 导出要求重编 DLL；回滚 = 回退代码提交，`~/.aliasagent/skills/` 目录残留不影响旧版本运行（旧版不扫描该目录）。

## Open Questions

无阻塞项。斜杠命令 change 的形态已拍板（提示展开型 + `/技能名`），其设计复用本 change 的目录服务与提示通道，等本 change 归档后立项。
