# Design: slash-command-completion

## Context

`add-slash-commands`（已归档）定了展开语义：`/技能名` 在模型装配面展开、未命中静默透传。本 change 只给输入侧加补全，装配侧一行不碰。DSH 参照（`dsh-client-ui-commands` README）：fuzzy-label 匹配（不区分大小写子序列、前缀优先、组内按前缀→得分→原始顺序）、Tab/回车接受、Esc/Shift+Tab 归还焦点、弹窗占 composer 浮层宽度。

AliasAgent 输入框：`lib/ui/input_bar.dart` 的 `InputBar` 组件——`_InputBarState` 持有 `_focusNode`，`Focus(onKeyEvent: _onKey)` 包住 `TextField`（`_onKey` 现状：Enter 且非 Shift → `_submit()`，其余 ignored），`onSubmit` 是构造参数。技能名清单：`SkillCatalogService.instance.activeSkillNames`（List<String>，字典序，= 最近一次 `scan()` 的结果）。

## Goals / Non-Goals

**Goals:**

- 打 `/ed` + Tab ⇒ 输入框变成 `/edge-skill `，全程不用记全名。
- 不接受补全时的一切行为与现状**逐字节一致**（透传、发送、展开）。
- 候选表跟随当轮技能目录，无缓存失效问题。

**Non-Goals:**

- 命令目录/分组/装饰（DSH 生态那套）、非技能命令、排序配置项、触屏手势优化。

## Decisions

**D1 触发与关闭条件（状态机）。**
面板只在**全部**成立时出现：① 输入框文本非空且第一个字符是 `/`；② `selection.isValid && selection.isCollapsed && 1 <= selection.baseOffset <= 首段末`（首段末 = 首个 U+0020/U/0009/U+000A 的下标，无空白时 = text.length；`isValid` 为假或越界 ⇒ 条件不成立、面板不显示，实现不得直接对 text 做越界 substring）；③ 输入框有焦点；④ **首段之后没有任何文本**（`text.length == 首段末`——有正文后光标再回首段也不弹；这条与 D4 一起堵死"接受吃正文"的可达状态）。任一不再成立即关闭（打出空白、删了 `/`、失焦、Esc、或首段后出现了文本）。**失焦即关**是硬规则：面板不抢焦点（never request focus），接受/关闭都把焦点还给输入框——这保证面板是纯"建议层"，不改变任何现有焦点行为。

**D2 Tab/回车拦截（机制按 Flutter 事实写）。**
Flutter 的按键分发从 primary focus（TextField 的 `_focusNode`）沿祖先上溯，节点返回 `ignored` 才继续外走；`Tab` 在输入行 Focus 层 `ignored` 之后到达 WidgetsApp 默认 Shortcuts（`SingleActivator(tab)` → `NextFocusIntent`）变成焦点遍历——这就是"Tab 被系统吃掉"的真机制。接法：在**输入行现有的 `Focus(onKeyEvent: _onKey)`**（`lib/ui/input_bar.dart`，不用已废弃的 `onKey`）里、**先于**既有 Enter→`_submit()` 分支处理面板按键。**拦截前置条件是"面板可见且存在高亮行"**：零候选（无匹配/空目录）时按键一律 `ignored` 走原行为（Enter 仍发送、Tab 仍遍历焦点），面板只是提示层不吞键。面板可见且有高亮行时：`Tab`/Enter=接受、`↑`/`↓`=移动、`Esc`/`Shift+Tab`=关闭不替换，全部 `handled`。单测锁：面板可见时 Tab 不移动焦点、焦点正断言（`hasFocus`）、文本被替换；无候选时 Enter 仍发送（回归）。Shift+Tab 等同 Esc（关闭不替换）。

**D3 匹配规则（借鉴 DSH 排序骨架，有意简化）。**
`lib/ui/slash_completion.dart` 提供纯函数 `List<String> filterSkillNames(String query, List<String> names)`：query 为空 ⇒ **按 names 输入顺序**全量返回（`activeSkillNames` 本身已按字典序，生产观感即字典序）；否则按"前缀命中（不区分大小写）→ 子序列命中（不区分大小写、按序不必相邻，按首次命中位置排序）→ 其余丢弃"排序返回。DSH 的 fuzzy-label 原文档是"前缀→对齐分→原始顺序"，本实现**有意不移植对齐分**、简化为前缀→首次命中位置（技能名是短串，更少的排序逻辑足够）——措辞如实写"借鉴骨架"不写成"移植"。**白盒点**：匹配对象只有技能名本身（无描述参与）。空查询/无命中都是合法输出（无命中 ⇒ 面板显示一行"无匹配技能"提示，不是消失——可见性原则；但此时按键不拦截，见 D2）。

**D4 接受 = 只替换首段、只改写输入框文本。**
接受高亮行：把首段（`/`+查询串）替换为 `/完整技能名␣`，**首段之后的文本原样保留**（D1④ 已让"首段后有文本"时面板不出现，双保险）；光标落在插入文本之后。**不**发送、不改任何状态；展开仍由 `add-slash-commands` 的装配面机制负责。**回车改道语义如实写**：面板可见且有高亮行时回车是"接受补全"不是发送——打完整名想直接发送的用户需要接受后（或 Esc 关闭面板后）再按回车；这是本特性与输入行既有 Enter→发送分支的唯一交互点，用户文档写明。鼠标点击候选=接受该行。

**D5 面板渲染（Overlay 锚定，不占布局）。**
`LayerLink` + `CompositedTransformTarget` 放在 `input_bar.dart` 的 `_InputBarState.build` 内、包住 `Expanded` 里的 TextField（不包整个 InputBar）；面板是 `OverlayEntry` 里的 `CompositedTransformFollower`，浮在输入框**上方**，宽度对齐输入框，窗口缩放/滚动跟随不脱节。行高/内边距用既有主题文本样式；高亮行用主题 `ColorScheme.secondaryContainer` 级色调（不新增品牌色）。空技能目录 ⇒ 单行空态文案（精确串见 tasks 2.1）；无匹配 ⇒ 单行"无匹配技能"（中性信息色）。

**D6 数据源读取时点（= 最近一次 scan 的结果）。**
面板每次打开/每次击键重筛时读取 `SkillCatalogService.instance.activeSkillNames`（getter 返回不可变副本，读一次 O(n)）——**不缓存、不监听、不触发扫描**。读取的是最近一次 `scan()` 的快照（启动时或上一轮装配）：装/删/改技能后需发一条消息触发下一轮装配，候选表才更新——面板不是即时通道，如实写进用户文档已知限制。

## Risks / Trade-offs

- **[Tab 与无障碍/键盘习惯]** 面板可见时 Tab 被截胡——这是本特性的核心交互（用户点名），面板不可见时 Tab 行为完全不变，影响面可控。
- **[弹层遮挡]** 面板盖住输入框上方的消息区——DSH 同款取舍，Escape/失焦即关。
- **[候选误导]** 空目录时的空态提示若太像报错会误导——用中性信息色文案，写明"装一个技能后这里会自动出现候选"。

## Migration Plan

纯新增交互，无数据迁移；回滚=回退代码提交。用户文档随代码同 change 更新。
