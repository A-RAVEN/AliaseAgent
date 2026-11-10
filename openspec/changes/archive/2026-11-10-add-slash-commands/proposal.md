# Proposal: add-slash-commands

## Why

技能体系（`add-skill-mechanism` + `refresh-skill-catalog-each-turn`）落地后，模型每轮都看得到技能目录与创建简则，但**用户没有任何显式触发手段**——想让助手严格按某技能干活，只能自然语言说"请用某某技能"，措辞不对时模型可能不去 `load_skill`。TODO.md「技能与斜杠命令支持」条早就定过拆分与形态（2026-11-06 用户两轮拍板）：技能先行、斜杠命令后置单独立项，**首版只做提示展开型（含 `/技能名` 显式触发）**，本地动作型与输入补全弹菜单不在首版。本条就是后置的那半个。

## What Changes

- 消息发送增加**斜杠命令展开**：用户消息以 `/` 开头、首段（斜杠之后到首个空白为止）**逐字等于**某个生效技能名时，发给模型的文本被替换为固定模板——指示模型先 `load_skill(skill: "<名字>")` 读取该技能并严格遵循其指令、然后处理用户余下正文；**对话视图里的一切保持原样**（对话视图气泡、会话标题、落库内容都是用户手打的原文；既有「真实上下文」屏按既有规范显示实际发出的内容，其中会显示展开后的模板全文，如实披露、不加遮掩）。
- 展开是**模型装配面的纯文本变换**：发生在 `Agent._buildApiMessages` 把每条消息拼成 API 请求文本块的地方（`_callModel` 与压缩投影共用这一入口），对**进入本次请求的每一条** user 消息按**当轮**生效技能集合逐条判定（幂等、纯函数、无状态）。子 Agent 的任务文本走同一装配路径，若以 `/技能名` 开头同样会被展开——这是按 role 判定的副作用事实，不是本变更承诺的触发方式（用户输入仍是唯一被承诺的入口）。
- 未命中（`/ unknown`、`/` 单独出现、首段不是任何生效技能名、大小写不一致、消息不以 `/` 开头）一律**原样透传**，不报错、不弹任何提示。
- **零新增界面**：不做人命令面板、不做输入补全菜单、不做横幅；气泡显示原文即全部界面行为。
- 文档：`Docs/user-guide/slash-commands.md` 新用户文档 + README 索引行 + 文档守卫同步。

不做（首版明确排除）：本地动作型命令（如 `/清空` 真的去清会话）、输入补全弹菜单（以上两项 2026-11-06 用户拍板，见 TODO.md 的「技能与斜杠命令支持」条拍板段）；命令参数解析语法（`/name --flag` 只会被当成正文余下部分）、自定义命令模板（以上两项为本设计首版排除的设计取舍，非用户要求，见 design.md 的 Non-Goals）。

## Capabilities

### New Capabilities

- `slash-commands`：用户消息在模型装配面的斜杠展开规则（命中判定、替换模板、透传与幂等语义）。

### Modified Capabilities

（无——不改技能目录、不改 `load_skill`、不改 spill。）

## Impact

- **Dart**：新增 `lib/services/slash_commands.dart`（纯函数 `expandSlashCommand(String text, List<String> activeSkillNames)` 返回替换后的模型文本，未命中原样返回）；`lib/services/agent.dart` 的 `_buildApiMessages` 在构造 user 文本块处调用它（单点接线，`_callModel` 与压缩投影共用）。
- **测试**：`test/unit`（纯函数全边界：命中/未命中/空白/大小写/多行/技能消失）；`test/integration`（FakeSidecar：发给模型的 user 文本是展开版、库中与标题是原文、未命中原样透传、第二轮历史里该条仍按当轮集合判定）；`test/widget`（输入 `/技能名 正文` 发送，气泡显示原文）。纯文本确定性变换，不新增 live 用例（分层原则：便宜层已锁行为）。
- **文档**：`Docs/user-guide/slash-commands.md`、`README.md` 索引、文档守卫用例。
- **不动**：C++/FFI、`load_skill` 定义与闸门、技能目录扫描、配置格式、DB schema。
