# Proposal: slash-command-completion

## Why

`add-slash-commands` 落地后，用户可以用 `/技能名 正文` 显式触发技能，但**首版按拍板没做输入补全**：技能名必须一个字母不差的完整手打（名字还带连字符，如 `edge-skill`），打错一个字符就静默透传。2026-11-11 用户明确要求补全（explore 原话：「能不能给 slash command 加一个匹配功能……我不用完整写完，直接打 tab 就行」）。这是**拍板反转**：2026-11-06 旧拍板「输入补全弹菜单不在首版」被本条新指令覆盖（新拍板优先，旧拍板留档在本句）。

对照 DSH 的做法（`@deepseek-ai/dsh-client-ui-commands` 包文档，已读）：键入 `/` 弹本地候选菜单、敲字实时模糊筛选、**Tab/回车接受高亮行**、Esc 归还焦点、↑↓ 移动；匹配规则为不区分大小写的模糊子序列 + 前缀优先（fuzzy-label 模式）。本 change 把这套交互移植到技能名补全，范围严格限定为"技能名"一种候选。

## What Changes

- 输入框**键入 `/` 且光标仍在首段、首段后还没有任何文本**时，输入框上方弹出候选面板：数据源 = `SkillCatalogService.instance.activeSkillNames`（= 最近一次扫描的快照；装/删技能后下一条消息起候选表跟着变，非即时）。
- **匹配规则**（借鉴 DSH fuzzy-label 的排序骨架：前缀→命中位置，有意不移植对齐分）：查询串对技能名做不区分大小写的按序子序列匹配（`/egk` 命中 `edge-skill`），前缀命中排最前；空查询按输入顺序全量。
- **键盘**（接线点在 `lib/ui/input_bar.dart` 的 `InputBar`——main.dart 里没有 TextField）：面板可见**且有高亮行**时，`Tab` 与回车接受高亮行（只把首段替换为 `/完整名␣`，其后文本原样保留），`↑`/`↓` 移动，`Esc`/`Shift+Tab` 关闭不改写；**零候选（无匹配/空目录）时不吞键**——Enter 仍发送、Tab 仍走默认焦点遍历。Flutter 的 Tab 默认由 WidgetsApp Shortcuts 变成焦点遍历，必须在输入行现有 `Focus(onKeyEvent:)` 里先于 Enter→发送分支拦截（design D2）。
- **关闭条件**：打出第一个空白、删掉开头的 `/`、失焦、Esc、或首段后出现了文本——面板消失，回到普通输入。提交函数与装配面展开零改动（`_submitInput` / `_sendMessage` / `_buildApiMessages` 不动）；但输入行的回车分支在面板可见且有候选时被改道为"接受补全"——打完整名想直接发送，需接受后（或 Esc 后）再按回车，用户文档写明。
- **空技能目录**：键入 `/` 显示一行空态提示（引导看 skills.md），不报错。
- 文档：`Docs/user-guide/slash-commands.md` 补"补全"一节；spec delta 给 `slash-commands` 能力 ADDED 补全条文。

不做（明确范围外）：命令目录/分组/装饰体系（DSH 那套多命令生态）、非技能类命令补全、模糊匹配之外的排序配置、移动端手势。

## Capabilities

### New Capabilities

（无）

### Modified Capabilities

- `slash-commands`：ADDED「技能名补全交互」条文（触发/匹配/接受/关闭/空态五要素 + 场景）。

## Impact

- **Dart**：新增 `lib/ui/slash_completion.dart`（匹配纯函数 + 面板组件，输入框处接线）；`lib/main.dart` 输入框挂候选面板（Overlay + CompositedTransformTarget）。
- **测试**：unit（匹配纯函数：前缀/子序列/大小写/空查询/无命中）；widget（触发/筛选/Tab 接受替换文本/回车同 Tab/Esc 关闭/打出空白关闭/空目录提示/鼠标点击）。
- **文档**：`Docs/user-guide/slash-commands.md` + 文档守卫同步。
- **不动**：装配面展开语义、透传规则、技能目录扫描、发送链路、`add-slash-commands` 的任何条文。
