# Tasks: refresh-skill-catalog-each-turn

按物理顺序执行。数字与判据回链：增量探测指纹=（mtime,size）两个数（设计 D1，无新上限）；"重读数"用测试可见计数断言（D4），耗时只记录不断言阈值（无合法来源不发明数字）；生效时机条文以本 change 的 skills delta 为准，替代 `add-skill-mechanism` 的"重启生效"句。

## 1. 技能服务改增量刷新（Dart）

- [x] 1.1 改 `lib/services/skills/skill_catalog_service.dart`：`scan()` 从"一次性全量"改为**增量刷新**——缓存每个候选的指纹（`SKILL.md` 的 mtime+size）与校验结果（生效条目或失败条目）；每次 scan 先 `listSync` 列目录，仅对新增/指纹变化/消失的条目重读全文+解析+校验，指纹未变条目直接复用缓存（含失败条目复用——坏文件不反复重读）。新增：`@visibleForTesting int lastScanReReadCount`（本次实际重读文件数，注解+注释写明仅测试读取）；每次 scan `debugPrint` 一行耗时毫秒实测；新增 `setRootForTests` 测试钩子（`spill.cpp` 的 `set_root_for_tests` 同形，传空恢复默认）
- [x] 1.2 扩 `test/unit/skill_catalog_service_test.dart`（临时目录夹具）：首次扫 3 个合法技能 → `lastScanReReadCount=3`；磁盘不动再扫 → `=0` 且目录文本一致；改 1 个文件内容 → `=1` 且该条 description 更新为新值；删 1 个 → 生效集合少一条；坏文件（校验失败）不动再扫 → 失败清单保持、`lastScanReReadCount=0`；**盲区如实测**：把文件改成同长度内容并把 mtime 设回原值 → 目录不变（用例注释写明这是 spec 登记的检测盲区，不是缺陷通过）。贴全绿输出

## 2. 每轮装配接线与界面提示（Dart）

- [x] 2.1 改 `lib/services/agent.dart`：每轮请求装配开头（`promptSection` 读取与 `toolDefinitions` 组装之前）调 `SkillCatalogService.instance.scan()`；语义钉死为"每轮装配刷新一次，一轮内视图一致"（设计 D2），不得放进每次工具派发
- [x] 2.2 新建 `test/integration/skill_hot_refresh_test.dart`（FakeSidecar + `setRootForTests` 临时目录）：第一轮发出后改夹具技能（新增第二个技能/改 description）→ 第二轮发出的 systemPrompt 目录反映新内容、第一轮不含；两轮之间磁盘不动 → 第二轮 `lastScanReReadCount=0`（经服务单例读）；**一轮内一致**：在同一轮的两次模型请求（工具循环轮内第二轮 sendMessage）之间改文件 → 该轮第二次请求的 systemPrompt 仍是装配时快照、不含改动（本 change 引入"一轮内一致"语义的专属用例，缺实现即红）。贴全绿输出
- [x] 2.3 改 `lib/main.dart`：在既有每轮回调（`onSnapshot` 或等价的轮次完成事件，选最小接线点）重读 `SkillCatalogService.instance.failureNotice`，与当前上屏值不同才 setState；启动扫描与其首次提示保留。`test/widget/skill_failure_notice_test.dart` **新增**用例（不是复述既有的"启动见坏文件→提示"）：应用已启动、首条消息走过一轮之后放入坏文件 → 下一条消息的装配后提示出现且含技能名与原因；再修好文件 → 下一条消息后提示消失。**改动前这两条必须红**（现状提示冻结在启动快照）——先贴一次改动前的红证据再实现（防"既有绿用例冒充验收"）

## 3. 文档与守卫同步

- [x] 3.1 改 `Docs/user-guide/skills.md`：「怎么算生效」由"放好文件重启即生效"改为"放好文件，下一条消息就生效（无需重启）"；已知限制节**第一条**"改了技能文件要重启应用才生效（目录在启动时扫描一次）"整条删除，替换为两条如实限制——空闲时不秒级生效（改动要等下一条消息；文件监听是后置路线 B）、同修改时间且同大小的覆盖写可能不被发现（与 `edit_file` 版本检查同款既有限制）。全文 `grep 重启` 逐处判定：新口径句（"无需重启"）保留，旧口径句清零
- [x] 3.2 同步 `test/unit/skills_docs_test.dart` 守卫：改前=正向断言 `contains('重启')`（旧口径时代留下的，**文档留着旧限制句它照样绿——测不住本 change**）；改后=正向断言「下一条消息就生效」+「覆盖写」限制句，**并新增负向断言**「改了技能文件要重启应用才生效」不得出现（旧句残留即红，比旧守卫严）。判据三条齐备：依据=本任务与 design D5；不放松（正向+负向双向）；对照=本条改前改后。人为留旧句跑一次贴红证据再清（证明负向断言真的能失败）

## 4. 全量验证与变异（主循环批次执行）

- [x] 4.1 `flutter analyze`（基线 161，改动文件零新增）；`scripts\sync_sidecar_dll.ps1`（本 change 不动 C++，跑它只为 DLL 新鲜度守卫不红）后 `flutter test` 全量贴 `+N All tests passed!`
- [x] 4.2 对本 change 引入的两个新机制各变异一处（不是凑次数，一处机制一条）：①增量判定——把指纹比对改成恒重读 → 1.2 的"磁盘不动再扫=0"用例必须红；②每轮刷新——删掉 2.1 的装配前 `scan()` 调用 → 2.2 的"第二轮反映新内容"用例必须红。各贴红证据后当场恢复，复跑全绿、改动文件哈希与变异前逐位相同
- [x] 4.3 `openspec validate refresh-skill-catalog-each-turn` 通过贴输出

## 5. 创建技能简则注入（返工追加，2026-11-08 用户拍板「至少该给个简单说明，告诉ai怎么写一个技能」）

- [x] 5.1 改 `lib/services/skills/skill_catalog_service.dart`：创建简则抽成服务侧常量（英文，与 "Available skills…" 段语言一致；每个规则在注释写明出处=`skill_frontmatter.dart` 常量 / `Docs/AgentSkillsDoc.md`）；`promptSection` 改造——非空=标题+清单+简则同段，空=只返回简则段（不再返回空串；无 "Available skills" 标题与 `- ` 清单行）。简则含：目录位置（<主目录>/.aliasagent/skills/）、目录名即技能名、frontmatter 字段规则（name/description 必填、compatibility 选填若提供则 1-500，上限 64/1024/500——apply 时按事实源修正"三必填"起草措辞）、附属 references/scripts/assets、写好下一条消息生效（no restart）、校验失败界面可见原因。`flutter analyze` 改动文件零新增
- [x] 5.2 扩 `test/unit/skill_catalog_service_test.dart`：**先贴红证据再实现**（现状空目录返回 ''，新用例必红）——新增用例断言：①空目录 `promptSection` 含简则关键句（目录位置、技能名规则、frontmatter 必填、下一条消息生效）且不含 `- ` 清单行与 "Available skills" 标题；②有技能时同段含清单与简则；③简则关键规则与 `skill_frontmatter.dart` 的常量对得上（如 64/1024/500 出现在简则里，防简则与校验漂移）。贴全绿输出
- [x] 5.3 既有用例适配（点名改、不许静默放松断言）：`test/integration/skill_catalog_injection_test.dart` 的「无技能不注入空段」改为新口径「无技能注简则」（先贴改动前红证据：5.1 后旧断言必红）；fixedOverhead 差值用例的期望从"目录文本长度"改为"注入的 promptSection 全段长度"（仍是逐字等值，不放松为约等于）。贴改前红与改后绿
- [x] 5.4 文档同步：`Docs/user-guide/skills.md`「助手什么时候用它」节加一句"提示词里常年带一段创建简则，助手随时可以帮你写新技能"；`test/unit/skills_docs_test.dart` 受影响字样断言同步（无影响则说明为什么不改）
- [x] 5.5 全量验证与变异（主循环批次执行）：变异——把 5.1 的简则注入删掉（promptSection 恢复旧形态）→ 5.2 新用例必须红，贴红证据后恢复、文件哈希与变异前逐位相同；`scripts\sync_sidecar_dll.ps1` 后 `flutter test` 全量贴 `+N All tests passed!`；`openspec validate refresh-skill-catalog-each-turn` 通过
