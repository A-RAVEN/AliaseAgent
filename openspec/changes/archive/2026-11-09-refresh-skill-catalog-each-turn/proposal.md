# Proposal: refresh-skill-catalog-each-turn

## Why

`add-skill-mechanism` 把"技能内容变更后重启生效"定成了实现口径（其文件头注释自认这是首版省事方案，规范原文并未强制）。用户 2026-11-08 明确否定："（改了文件要重启才生效）感觉这不太好"，并在两条路线（A 每轮装配前重扫 / B 文件监听+失效）中拍板 **A**（原话「那先A吧，你加一下返工任务」）。目标：把技能文件放进/改到 `~/.aliasagent/skills/` 后，**下一条消息就生效**，不用重启应用。

## What Changes

- `SkillCatalogService` 的扫描时机从"仅启动一次"改为"**每轮请求装配前增量重扫**"：每轮先做轻量探测（列目录 + 每个 `SKILL.md` 的修改时间与大小两个数），**只对新增/变更/消失的技能重读全文并重新校验**，未变技能复用上轮缓存的生效条目与失败条目（本条钉死"不许每轮全量重读"——用户 2026-11-08 问"是不是每轮都重读所有技能文件"，答案：不是，只重读指纹变过的文件）。生效技能集合、注入目录、失败清单都随本轮磁盘现状更新（同步 IO，单线程事件循环内天然不可交错，无需锁）。
- 派发 `load_skill` 的生效集合闸门自动读最新缓存（同一份单例，无需改动语义）。
- 界面失败提示随重扫更新：**复用 `lib/main.dart` 已有的每轮回调**（design D3：不新建监听机制、不加"变化回调"这类新结构）重读 `failureNotice`，与当前上屏值不同才刷新既有提示组件（不新增任何界面）。
- 每轮重扫耗时写一行调试日志（实测用，不设阈值断言——无合法来源不发明上限）。
- 文档同步：`Docs/user-guide/skills.md` 的「怎么算生效」与「无热更新」限制句改写为新口径（下一条消息即生效）；守卫用例的字样断言同步（改前改后留对照）。
- **BREAKING（行为口径）**：主 spec `skills` 的「技能目录的存放与发现」中"生效时机 SHALL 为重启应用"条文改为"下一轮请求装配时重扫生效"。

不做（路线 B 的范围，用户未选）：文件监听器、秒级空闲生效、空闲零扫描。启动那次扫描保留（首条消息前失败提示即可见，且热更路径复用它的数据结构）。

## 返工追加（2026-11-08 用户拍板，原话「至少该给个简单说明，告诉ai怎么写一个技能」「你直接给这个change加返工任务」）

**Why**：技能机制落地后，模型在系统提示词里只看得到"有哪些技能"，看不到"怎么写一个"——用户让 AI 帮忙创建技能时它没有格式依据。考察 DSH 的对照结论：DSH 也没有"创建技能"产品功能（创建=往磁盘写 SKILL.md，安装靠 find-skills 技能引导），但它常年把写作规范放在模型上下文里。

**What Changes（追加）**：

- `promptSection`（`skill_catalog_service.dart`，每轮注入系统提示词的技能目录段）追加一段**创建技能简则**：目录位置、技能名规则（目录名即技能名）、`SKILL.md` frontmatter 字段规则（`name`/`description` 必填、`compatibility` 选填、长度上限）、附属子目录约定、写好下一条消息生效。事实源=`skill_frontmatter.dart` 校验规则与 `Docs/AgentSkillsDoc.md`，简则与校验规则不一致即缺陷。
- 注入形态：**有技能=目录清单+简则同段；没有技能=只注简则**（解决第一个技能怎么写的冷启动）。注入通道就是每轮重拼的系统提示词——API 无状态、没有"只发一次"的系统提示词机制，目录段本来就每轮随发，简则搭同一通道，成本为固定小段、不随对话增长。
- **BREAKING（行为口径）**：主 spec `skills` 的「技能目录注入系统提示词」中"没有任何生效技能时 SHALL NOT 注入空目录段"改为"不注入目录清单（仍不留空悬句子），但 SHALL 注入创建简则"。
- 既有测试按新口径适配（点名改、不静默放松）：`skill_catalog_injection_test` 的「无技能不注入空段」与 fixedOverhead 差值两条。

不做：bundled 内嵌技能基建、`save_skill` 工具、新增交互界面。

## Capabilities

### New Capabilities

（无）

### Modified Capabilities

- `skills`：「技能目录的存放与发现」的生效时机条文由"重启"改为"每轮装配前增量重扫、下一条消息生效"（失败提示的更新语义属实现层，由 design D3 与 tasks 2.3 钉，不在 spec 另立条文）。

## Impact

- **Dart**：`lib/services/skills/skill_catalog_service.dart`（scan 改增量、可重复调用，带测试可见的重读计数）、`lib/services/agent.dart`（装配点先重扫再取 `promptSection`）、`lib/main.dart`（在既有每轮回调里重读提示、变化才刷新，启动扫描保留）。
- **测试**：`test/unit`（连续两次 scan 看见新增/修改/损坏；磁盘不动时重读计数=0）、`test/integration`（FakeSidecar 两轮之间改文件→第二轮 systemPrompt 反映新内容——热更核心验收；同轮中途改文件→本轮不反映）、`test/widget`（改好坏文件后下一轮提示消失——改动前该条必须红）。
- **文档**：`Docs/user-guide/skills.md` 两处措辞 + `test/unit/skills_docs_test.dart` 守卫字样同步。
- **不动**：C++/FFI、`tool-output-spill`、配置格式、用户既有技能文件。
