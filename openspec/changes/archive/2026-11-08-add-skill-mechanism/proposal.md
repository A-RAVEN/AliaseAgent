# Proposal: add-skill-mechanism

## Why

可复用的操作手册（流程性知识）目前没有产品级机制承载：整段塞进系统提示词就每轮占上下文，复制粘贴进聊天则每次重来。开放规范 Agent Skills（agentskills.io，事实源已抓进 `Docs/AgentSkillsDoc.md`，2026-11-06 抓取）定义了跨工具通用的技能格式（目录 + `SKILL.md` + 六字段 frontmatter + 渐进加载三层），Claude Code / claude.ai / Skills API 共用这一格式——本应用支持同一格式后，用户已有的技能目录可以直接放进 `~/.aliasagent/skills/` 复用。需求形态由用户 2026-11-06 两轮拍板钉死：专门工具加载（`load_skill`，允许读技能目录内附属文件）、只做全局安装目录、不新增任何交互界面、技能对所有模板全量生效、无逐模板开关（`TODO.md`「技能与斜杠命令支持」条目）。

## What Changes

- 新增技能发现与校验：启动时扫描 `~/.aliasagent/skills/<name>/SKILL.md`，按规范六字段校验（`name` 1–64 字符、小写字母/数字/连字符、不以 `-` 开头结尾、无连续 `--`、须与父目录名一致；`description` 1–1024 字符非空；`compatibility` 若提供 ≤500）；规范六字段之外的键忽略不报错（加载侧宽松口径）。校验失败的技能不生效，且失败原因对用户可见（界面提示 + 日志），不静默跳过。
- 新增技能目录注入：每轮把「技能名 + description」拼进系统提示词（装配先例：`lib/services/agent.dart` 的 `guard.inject()` 动态段）；与 `load_skill` 一同**无条件注入**——不受模板工具清单影响（用户拍板原文「技能对所有 Agent 模板全量生效、无逐模板开关」，`TODO.md:162`）。
- 新增工具 `load_skill`：参数 `skill`（必填，技能名）与 `file`（可选，技能目录内相对路径）；不带 `file` 返回 `SKILL.md` 正文（frontmatter 之后的指令层），带 `file` 返回该附属文件全文；`file` 解析（规范化）后必须仍位于该技能目录内，越界与非法技能名都返回带原因的可见错误；**校验失败的技能加载时由生效技能集合拦截**（Dart 派发侧把关，报错带失败原因）；大结果走既有 spill 先落盘交付契约（截断可见、`read_spill` 可恢复）。
- `load_skill` 的交付形态：**每轮装配时无条件随请求附加该工具定义**（与目录段同开同关），不进 `ToolCatalog.kBaseToolNames`（保持 11 项）、不进模板勾选清单、不改动任何用户配置——既有模板的清单与保存行为完全不变（「既有模板选择不被覆盖」规则因此不触发）；执行分组上不属只读集合，自动逐个段执行。
- 执行落点：技能文件的读取与 spill 形状化在 C++ sidecar（复用 `spill::shape_stream` 与 `spill.cpp` 的 `home_dir()` 先例），与 `web_fetch`「定义在 Dart、正文形状在 C++」的分工同形；目录扫描与 frontmatter 校验在 Dart 侧。
- 新增 Dart 依赖 `yaml`（解析 frontmatter；引入与真实解析版本由任务实测落地，不自造）。
- 文档同步：新增 `Docs/user-guide/skills.md`（装在哪、怎么算生效=放好文件重启即可、出错会看到什么、已知限制），更新 `README.md` 功能索引与 `Docs/user-guide/tools-file.md` 交叉引用。

不在本 change 范围（用户已拍板后置）：斜杠命令与 `/技能名` 显式触发（另立 change）、工作区级技能、逐模板开关、技能安装/管理界面、`allowed-tools` 的预批准语义（本产品零审批全权限）、Claude Code 扩展字段（`context: fork`、`model`、`hooks` 等）。

## Capabilities

### New Capabilities

- `skills`：技能的存放与发现、frontmatter 校验与失败可见性、目录注入（含白名单联动）、`load_skill` 工具行为（附属文件、目录穿越防护、非法名与未知技能报错形态）、首启默认与既有模板不覆盖。

### Modified Capabilities

- `tool-output-spill`：「工具输出先落盘」适用范围从 `run_command` 与 `web_fetch` 扩展到 `load_skill`（标题、范围句与「交付形状实现只此一份」同改，新增 load_skill 场景）。

## Impact

- **Dart**：新增 `lib/services/skills/`（扫描、校验、目录文本组装、`load_skill` 定义常量）；改 `lib/services/agent.dart`（系统提示词拼装段 + `toolDefinitions` 装配追加 + `load_skill` 派发分支含生效集合闸）、`lib/main.dart`（base 表注册定义与启动扫描、失败提示接入现有 notices 显示通道）、`lib/services/sidecar_bridge.dart`/FFI 绑定（新导出）；`ToolCatalog.kBaseToolNames` 与 `tool_group_planner.dart` 两集合**不改**（连锁判定见设计 D9）。
- **C++**：新增 `sidecar/src/skill_tool.cpp/.h`（读文件、frontmatter 切除、路径校验、调 `spill::shape_stream`）；`sidecar_api.cpp/.h` 新增 `load_skill` 导出；`sidecar/CMakeLists.txt` 注册测试。
- **测试**：`test/unit`（校验纯逻辑、目录文本、分组集合守卫）、`test/integration`（FakeSidecar 派发与注入）、`sidecar/test`（`[skills]` 标签：越界/正文/形状/错误）、`integration_test/skills_live_test.dart`（真实模型自主调用，`--tags live`）。
- **依赖**：`pubspec.yaml` 新增 `yaml`。
- **用户可见**：零配置改动——`load_skill` 与技能目录对所有模板无条件生效（用户拍板原文「全量生效、无逐模板开关」）；技能放目录即生效，改动后重启生效（与规范"启动时载入元数据"同形，如实写进用户文档限制节）。
