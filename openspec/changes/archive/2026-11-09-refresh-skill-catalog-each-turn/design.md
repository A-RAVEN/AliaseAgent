# Design: refresh-skill-catalog-each-turn

## Context

现状（`add-skill-mechanism` 已归档落地）：`SkillCatalogService`（`lib/services/skills/skill_catalog_service.dart`）单例，`scan()` 同步 IO（`listSync`+`readAsStringSync`+`validateSkillMd`），只在 `lib/main.dart` 启动初始化链调一次（`_toolsReady` 置位前）；`agent.dart` 每轮装配读缓存 `promptSection`（拼装点 `guard.inject()` 之后），派发 `load_skill` 前读生效集合作闸门；界面失败提示 `failureNotice` 由启动那次结果上屏。用户拍板路线 A（每轮装配前增量重扫），并追问钉死"不许每轮全量重读所有技能文件"。

## Goals / Non-Goals

**Goals:**

- 技能文件的增/改/删，**下一条消息**即反映到目录、生效集合、失败清单与界面提示。
- 稳态每轮成本 = 一次列目录 + 每技能两个数（mtime+size）的比较；未变文件不重读、不重新解析、不重新校验。
- 一轮请求内部目录一致（同轮装配后中途改文件不影响本轮），轮间刷新。

**Non-Goals:**

- 文件监听器（路线 B）：空闲秒级生效、chokidar 式抖动处理——用户未选。
- 附属文件（`references/`、`scripts/`）的热更语义：`load_skill` 本来就每次现读磁盘，天然最新，无需机制。
- 技能数量/体积上限、扫描频率配置项：不新增（无合法来源）。

## Decisions

**D1 增量探测 = 目录清单 + 每技能 `(mtime, size)` 指纹。**
服务内缓存 `Map<技能目录名, 指纹 + 校验结果（生效条目或失败条目）>`。`scan()` 改为可重复调用的增量刷新：`listSync` 列目录 → 对每个候选 `SKILL.md` 取 `File.statSync`（mtime+size 两个数）→ 与缓存指纹比对：**新增/变/删**的条目才 `readAsStringSync`+解析+校验并更新缓存；指纹相同的条目直接复用（含复用其失败条目——坏文件不反复重读）。目录整体不存在 = 空集合（与启动语义一致）。
**已知检测盲区（如实登记）**：同 mtime 且同 size 的覆盖写不会被发现——与产品既有 `edit_file` 版本检查同款限制（`Docs/user-guide/tools-file.md` 限制节先例），本 change 不解决、在 `skills.md` 限制节写明。

**D2 刷新点 = `agent.dart` 每轮装配开头（`promptSection` 读取前）。**
`toolDefinitions`/systemPrompt 拼装前调 `scan()`（同步、幂等、可重入；Dart 单线程事件循环内不会交错，无需锁）。子 Agent 走同一装配路径自动获得同语义。派发闸门（`load_skill` 查生效集合）读的就是本轮刷新后的缓存，无需另动。**一轮内一致**：装配之后、本轮工具循环中途的文件改动，到下一轮装配才反映——这条语义写进 spec 场景，防止被实现成"每次工具调用都扫"。

**D3 界面提示复用既有轮次回调，不新建监听机制。**
`lib/main.dart` 在现有每轮回调（`onSnapshot` 或等价的轮次事件，执行时按现有代码选最小接线点）重读 `failureNotice`，与当前上屏值不同才 setState。启动那次扫描与提示保留（首条消息前即可见）。不新增任何界面元素。

**D4 "没重读"要能证明：测试可见的重读计数。**
服务暴露 `@visibleForTesting` 的 `lastScanReReadCount`（本次 scan 实际重读+重校验的文件数）。unit 用例：首次扫 N 个技能 → 计数=N；原样再扫 → 计数=0；改 1 个 → 计数=1；删 1 个 → 目录条目减一且计数不增。同时每次 scan 用 `debugPrint` 记一行耗时（毫秒实测值，不设阈值断言——无合法来源不发明上限）。

**D5 spec 修订走 MODIFIED。**
`skills` 能力「技能目录的存放与发现」整块复制主 spec 现文，改动点=生效时机段（"重启应用"→"每轮装配前增量刷新、下一条消息生效"）+ 场景三处：旧场景「放入即发现」改为无需重启形态（新场景「放入即发现（无需重启）」），新增「未变文件不被重读」（重读计数=0 可测）与「一轮内视图一致」（装配后中途改动本轮不反映）；盲区（同 mtime 同 size）不立场景、以限制句进 spec 正文与用户文档——它的如实测归 tasks 1.2 的 unit 用例。文档守卫 `test/unit/skills_docs_test.dart` 的断言随文档措辞同步改：正向断言改为新措辞「下一条消息就生效」，并**新增负向断言**「改了技能文件要重启应用才生效」这句旧限制不得再出现（旧句残留即红——比只查正向更严）；改前改后贴进 tasks 备注。

**D6 创建技能简则住在 `promptSection`，与目录段同生共死（返工追加，用户 2026-11-08 拍板）。**
- **位置**：`promptSection`（`skill_catalog_service.dart`）。候选位置比对过：① load_skill 工具描述——工具描述讲工具怎么用，写技能是另一件事，会污染工具语义；② bundled 内嵌技能——为一段说明上打包基建不值；③ 独立文档让模型自己 read——模型不会无故读文件，正好 defeat 需求目的。目录注入段每轮必被模型看见，与「技能」语义内聚，是现成通道。
- **形态**：简则抽成服务侧常量（英文，与现有 "Available skills…" 段语言一致）；**有生效技能=标题+清单+简则，没有=只注简则**（空目录不再返回空串——这是 spec 「无生效技能不注入空段」条文被修改的原因；「不留空悬句子」的原则不变：无技能时不出现 "Available skills" 标题与清单行）。
- **每轮随发是通道固有属性，不是设计浪费**：系统提示词每轮重拼（本 change 的热更就建立在这一点上），API 无状态、不存在"只发一次"的系统提示词机制。简则为静态文本，成本固定一小段，不随对话长度增长。
- **事实源**：简则里的每个规则（名字字符集与 64 上限、description 1024、compatibility 选填若提供则 1–500、name/description 必填、附属目录约定、下一条消息生效）必须能在 `skill_frontmatter.dart` 常量与 `Docs/AgentSkillsDoc.md` 找到出处；简则与校验规则不一致即缺陷（tasks 5.2 用断言钉关键句）。返工执行时按事实源修正一处起草措辞：compatibility 是选填不是必填（`skill_frontmatter.dart` 校验逻辑与 AgentSkillsDoc 字段表均如此），简则如实写 `compatibility (optional, 1-500 chars when present)`。
- **连带改动（明账）**：`skill_catalog_injection_test` 两条既有用例按新口径改——「无技能不注入空段」改为「无技能注简则」，fixedOverhead 差值用例的期望从"目录文本"改为"promptSection 全段（清单+简则）"，仍是逐字等值比较，不放松为约等于；skills.md「助手什么时候用它」节加一句提示词常带简则。

## Risks / Trade-offs

- **[mtime+size 盲区]** 同刻同长覆盖写不生效 → 缓解：限制句进用户文档；真需要秒级/必感知走路线 B（监听器），留了明确的升级路径（用户原话"先A"即含此意）。
- **[每轮同步 stat 拖慢装配]** N 个技能=N 次本地元数据查询（不读内容）→ 缓解：每次 scan 的耗时实测值进 `debugPrint` 日志（tasks 1.1），量级以实跑读数为准、设计不预判数字；真出现不可接受时升级路线 B（监听器）。
- **[坏文件反复出现在失败清单]** 校验失败条目复用缓存后，若用户没改它就不该反复提示 → 语义定死：提示内容随指纹变化才更新（D3 的"不同才 setState"覆盖）。
- **[测试计数钩子被滥用进生产逻辑]** `@visibleForTesting` 注解 + 仅测试读取；实现注释写明用途。

## Migration Plan

纯行为变更，无数据迁移；回滚=回退代码提交。用户文档两处措辞随代码同 change 更新。

## Open Questions

无。
