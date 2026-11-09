# Tasks: add-skill-mechanism

按物理顺序执行。规则回链：数字全部有出处——64/1024/500 = `Docs/AgentSkillsDoc.md` 第一节规范硬限（1–N 含下界）；1000 = 既有配置项 `spill.preview_chars` 与常量 `spill::kDefaultPreviewChars`；「全量生效、无逐模板开关」= `TODO.md:162` 用户拍板原文（对抗审查 blocking-1 后按此修订：`load_skill` 不进基础清单、装配层无条件交付）。本 change 不新增任何数量上限。

## 1. 依赖与元数据解析（Dart 纯逻辑）

- [x] 1.1 `flutter pub add yaml`，把真实解析出的版本号贴进执行报告（设计 D3：版本号不预设；解析失败即停工贴报错）

  > 实测（2026-11-07）：`flutter pub add yaml` 退出码 0，日志 `%TEMP%\skill_apply_1.1.log`；解析结果 `yaml 3.1.4 (was 3.1.3) (from transitive dependency to direct dependency)`，`pubspec.yaml:22` 写入 `yaml: ^3.1.4`。
- [x] 1.2 新建 `lib/services/skills/skill_frontmatter.dart`：按设计 D2 切 frontmatter（首行恰 `---`、切到下一独立成行的 `---`，否则整个文件按正文=无 frontmatter），校验规范六字段与约束（`name` 必填 1–64、仅小写字母/数字/单连字符、不以 `-` 首尾、无 `--`、须等于父目录名；`description` 必填 1–1024 非空；`compatibility` 若提供则 1–500（**空串=校验失败**，1–N 口径，事实源第一节原文 "Must be 1-500 characters if provided"）；`license`/`metadata`/`allowed-tools` 可选；未知键忽略不报错；YAML 解析失败 = 校验失败）

  > 实测（2026-11-07）：文件落地 `lib/services/skills/skill_frontmatter.dart`（`splitSkillMd` + `validateSkillMd`，含 `kSkillNameMaxChars=64` / `kSkillDescriptionMaxChars=1024` / `kSkillCompatibilityMaxChars=500` 三个常量并在注释回链 `Docs/AgentSkillsDoc.md` 第一节）。C++ 侧同规实现在 4.1 落地，两侧共用夹具 `sidecar/test/fixtures/skills/edge-skill/SKILL.md`（305 字节，LF，无 BOM）。
- [x] 1.3 新建 `test/unit/skill_frontmatter_test.dart`：夹具覆盖边角——首行不是 `---`（判"无 frontmatter"失败）、正文含独立 `---` 行（只切第二处、其后的 `---` 留正文）、`name` 65 字符、`name: pdf--processing`、`name` 与目录名不一致、`description` 1025 字符、`compatibility` 501 字符、`compatibility: ""`（空串必须失败）、带 `context: fork` 未知键照常通过、值含引号/冒号。每条判据引用 `Docs/AgentSkillsDoc.md` 对应小节；贴全绿输出

  > 实测（2026-11-07）：`flutter test test/unit/skill_frontmatter_test.dart` 退出码 0，末行 `00:00 +20: All tests passed!`（日志 `%TEMP%\skill_apply_1.3.log`）。20 条覆盖上列全部边角，另加 CRLF、未闭合 `---`、`license`/`metadata`/`allowed-tools` 保留、YAML 解析失败各一条，以及"跨侧夹具"一条（读 `sidecar/test/fixtures/skills/edge-skill/SKILL.md`，断言正文 == C++ 侧将断言的同一个字面量）。

## 2. 技能目录服务与注入文本（Dart）

- [x] 2.1 新建 `lib/services/skills/skill_catalog_service.dart`：进程级单例（`ToolCatalog` 单例同形），启动扫描 `<主目录>/.aliasagent/skills/`（主目录解析与 Dart 侧 `config_service.dart` 的 `configDir` 同源）；技能根不存在 = 空目录静默；技能根存在但**不是目录**或整体不可读 = 产出一条"技能目录不可读"汇总提示（不抛崩、不静默）；子项是文件而非目录 = 忽略；校验失败技能收集为一行式失败清单（技能名+原因）并**排除出生效集合**；生效技能按 `name` 字典序。暴露两个只读出口：生效集合（名字→描述）与失败清单

  > 实测（2026-11-07）：落地 `SkillCatalogService`（单例 `instance`，`scan({String? rootPath})`，出口 `activeSkills` / `activeSkillNames` / `failures` / `rootError` / `failureNotice` / `noticeLines` / `isActive` / `failureReasonFor` / `promptSection`）。根路径 `defaultRootPath` = `ConfigService.configDir + Platform.pathSeparator + 'skills'`（与 `config_service.dart` 同源）。文件类型判定用 `FileSystemEntity.typeSync(followLinks: false)`：`notFound` 静默、非目录给"该路径存在但不是目录"、列举异常给 `技能目录不可读：<路径>（<异常>）`；子项 `is! Directory` 一律跳过。
- [x] 2.2 同文件实现注入文本组装：使用说明句（英文，模板见 specs「技能目录注入系统提示词」）+ 每生效技能一行 `- <name>: <description>`；`description` 不截断不改写

  > 实测（2026-11-07）：`promptSection` getter 第一行 `Available skills (load one with load_skill(skill) before following its instructions; load_skill also reads files inside the skill directory):`（design D4 的模板），之后每行 `- <name>: <description>`，无生效技能返回空串。2.3 的 `zebra` 用例用 300+ 字符 description 断言原文整段出现、且区段内无 `...`/`省略`/`truncated`。
- [x] 2.3 `test/unit/skill_catalog_service_test.dart`（临时目录夹具）：目录不存在零提示零报错；混放 1 合法 + 2 非法（超长 name、无 frontmatter）→ 生效集合只含合法 1 条、失败清单含两条各自原因；**技能根路径指向一个文件（模拟整体不可读）→ 产生"不可读"汇总、生效集合为空、不抛异常**；字典序稳定；组装文本无省略字样。贴全绿输出

  > 实测（2026-11-07）：`flutter test test/unit/skill_catalog_service_test.dart` 退出码 0，末行 `00:00 +7: All tests passed!`（日志 `%TEMP%\skill_apply_2.3.log`）。7 条：不存在→零提示；混放→`{pdf-tools: 处理 PDF：拆分与合并}` + 两条失败（含 `name 超过 64 字符（实际 65）`、`没有 frontmatter`）；根是文件→`技能目录不可读：…（该路径存在但不是目录）`；混放文件→忽略；字典序 `[alpha, middle, zebra]` + 无省略字样；重复扫描清空；定义常量 `required=[skill]`、属性集 `{skill, file}`。夹具全在 `Directory.systemTemp.createTemp` 造的临时目录，`tearDown` 递归删除。

## 3. 装配接线（Dart → 请求，对抗审查后按「无条件交付」修订）

- [x] 3.1 `lib/services/agent.dart`：系统提示词拼装处（`guard.inject()` 之后）接入目录段——**不受模板工具清单影响**，仅当生效技能非空才拼（空目录不出空句子）；`toolDefinitions` getter 改为 `resolve(config.tools)` 结果后**追加 `load_skill` 定义**（已含则不重复追加，保 resolve 原顺序、追加在尾部）

  > 实测（2026-11-07）：`systemPrompt` 改为 `StringBuffer` 拼装（模板提示 → `\n` → `guard.inject()` → 有技能时 `\n`+目录段 → `\nCurrent date: …`）；`toolDefinitions` getter 先 `ToolCatalog.instance.resolve(...)`，`alreadyListed` 为假时 `[...resolved, kLoadSkillToolDefinition]`。3.3 实测：不含 `load_skill` 的模板发出 `tools=[read_file, write_file, load_skill]`；清单已含它的模板发出 `[read_file, load_skill]`（恰一次）。
- [x] 3.2 `load_skill` 工具定义常量放 `skill_catalog_service.dart`（英文 description，写明"先加载再遵循；file 读技能目录内附属文件"），`lib/main.dart` 的 `_initSearchAndTools()` base 表注册该定义（与 `spawn_subagent` 同处注册，`ToolCatalog.instance.seed(base)`），使模板显式列它也不报 `UnknownToolsException`；**`ToolCatalog.kBaseToolNames` 保持 11 项不变**（不写进任何默认/迁移清单）

  > 实测（2026-11-07）：`kLoadSkillToolName='load_skill'`、`kLoadSkillToolDefinition`（description 写明 "Call this BEFORE following a skill listed in the system prompt" 与 "With `file` it returns the full text of that file … relative to the skill directory"；schema `required: ['skill']`，属性 `{skill, file}`）落在 `skill_catalog_service.dart`；`lib/main.dart` 的 base 表在 `spawn_subagent` 之后加 `kLoadSkillToolName: kLoadSkillToolDefinition`，`ToolCatalog.kBaseToolNames` 未改（`test/unit/tool_catalog_test.dart` 的 11 项断言仍绿，见 6.1）。
  >
  > **工件内部不一致（如实登记，未自行改工件）**：design D9 的括号注写「（**不进** `ToolCatalog`、不进 `kBaseToolNames`、不进 `kSerialToolNames`、不进模板编辑器候选）」，本条任务与 6.1 的计数要求（未就绪清单 11→12）要求该定义**在 base 表注册**（即进 `ToolCatalog`，模板编辑器候选来自 `ToolCatalog.instance.nameSet`，因此它也会出现在候选里）。两者冲突时按本条与 6.1 的显式指令执行（它们给出了可测的计数判据）；`kBaseToolNames` 仍 11 项、`kSerialToolNames` 未动、任何模板的工具清单都未被写入 `load_skill`。此差异留待主循环修订 design 或在归档前裁定。
  > **结案（主循环 2026-11-07 裁定并已修订 design）**：注册进 `ToolCatalog` 是必需的（否则模板手写 `load_skill` 会抛 `UnknownToolsException`），编辑器候选里出现 `load_skill` 属如实登记的副作用；本条实现与 6.1 的计数判据即为最终口径，本条备注至此结案。
- [x] 3.3 `test/integration/skill_catalog_injection_test.dart`（FakeSidecar）：2 生效技能 + 任一模板（含与不含 `load_skill` 两种清单）→ 发出的 systemPrompt 都含两行目录（字典序）、tools 数组都含 `load_skill` 定义；无生效技能 → systemPrompt 无目录句、tools 仍含定义；模板清单已手写 `load_skill` 时 tools 数组**恰出现一次**（去重）；注入前后 `fixedOverheadTokens` 差值与目录文本一致增长。贴全绿输出

  > 实测（2026-11-07）：`flutter test test/integration/skill_catalog_injection_test.dart` 退出码 0，末行 `00:00 +3: All tests passed!`（日志 `%TEMP%\skill_apply_3.3.log`）。读数：有技能时 `tools=[read_file, write_file, load_skill]`、systemPrompt 含 `- alpha-skill: …` 与 `- pdf-tools: …`（字典序）；手写清单模板 `tools=[read_file, load_skill]`（恰一次）；无技能时 systemPrompt 无 `Available skills`、`tools=[read_file, write_file, load_skill]`；目录段 192 字节 ⇒ 提示词长度差 193、`fixedOverheadTokens` 386 vs 337（差 49）== 整段估算差 76−27=49。

## 4. C++ 加载工具（sidecar）

- [x] 4.1 新建 `sidecar/src/skill_tool.cpp/.h`：入参 JSON `{skill, file?, preview_chars?}`；`skill` 先按规范字符集校验（不合规不触文件系统，`ok:false` 带原因）；根路径 = `spill.cpp` 同款 `home_dir()` + `/.aliasagent/skills/`；读 `SKILL.md` 时按设计 D2 行切切除 frontmatter（只切第二个独立 `---` 行，不解析 YAML 语义）；`file` 参数拼接后 `canonical()` 并校验仍在技能目录内（参照 `tools.cpp` 的 `is_within_workspace` 同款前缀判定），越界 `ok:false` 带"超出技能目录"原因；文件不存在/技能目录不存在 = `ok:false` 带完整原因（技能名 + 路径），SHALL NOT 返回空内容冒充成功

  > 实测（2026-11-07）：`sidecar/src/skill_tool.h` + `skill_tool.cpp` 落地（`root()` / `set_root_for_tests` / `strip_frontmatter` / `is_valid_skill_name` / `load_skill`）。`home_dir()` 与 `spill.cpp` 逐字同源（`USERPROFILE` → `HOMEDRIVE` → `.`）；`canonical()` 用 `GetFullPathNameA`，`is_inside()` 与 `tools.cpp` 的 `is_within_workspace` 同款（前缀 + 下一个字符必须是分隔符，Windows 大小写不敏感）。`file` 先拒绝对路径（盘符/分隔符开头），再规范化比前缀。15 条 `[skills]` 用例全绿（见 4.5）。
- [x] 4.2 交付形状接共享实现：读到的完整内容调 `spill::shape_stream`（tag `skill`，`preview_chars` 缺省回落 `spill::kDefaultPreviewChars`），信封字段与 `web_fetch` 同形；**写盘失败且内容超过预览阈值 → `ok:false` 带写盘失败原因**（对齐 `tool-output-spill`「写盘失败必须可见」），写盘失败但短内容 → 内联全文

  > 实测（2026-11-07）：`skill_tool.cpp` 调 `spill::shape_stream(ctx, content, preview, ctx.name(), "skill", &written)`；成功结果 `{"ok":true,"content":shape.inline_text,"truncated":shape.truncated,"spill":{"skill":shape.envelope}}`（与 `web_fetch` 的 `spill.content` 同形）；`!written.ok` 且 `char_count(content) > preview*2` ⇒ `ok:false`（错误里带目录与系统原因），短内容 ⇒ `ok:true` 内联全文且不产生 spill 键。
- [x] 4.3 `sidecar_api.cpp/.h` 新增 `SIDECAR_API const char* load_skill(const char* handle, const char* request_json)`（`web_fetch` 同形，经 `context_api` 绑定当前上下文）

  > 实测（2026-11-07）：`include/sidecar_api.h` 声明（含请求/响应文档与越界语义）+ 头部导出清单 20→21；`sidecar_api.cpp` 转发 `context_api::load_skill(handle, request_json)`；`context_api.h/.cpp` 新增 `Lease` 绑定的 `Context&` 版与句柄版（新槽 `kSlotLoadSkill`，未注册句柄返回 `unknown_context`）。
- [x] 4.4 `sidecar/CMakeLists.txt` 注册 `sidecar/test/skill_tool_test.cpp`（tag `[skills]`）；用例至少：短正文内联且字节等于切除 frontmatter 后的预期切片、附属文件全文返回（不切）、**正文含独立 `---` 行的夹具与 Dart 侧同一份文本、C++ 切除结果等于 Dart 侧认定区间（跨侧互验，设计 D2）**、`../../` 穿越拒且原因在、大写/连字符非法技能名不触文件系统、未知技能名 `ok:false` 含名字、长正文信封总字节 == spill 文件实际大小且 `|head|+|tail|+omitted == total`、**spill 目录不可写 + 长内容 → `ok:false`（短内容 → 内联）**、落盘文件名形如 `<6 位序号>-skill.txt` 且与同上下文 `run_command` 序号共表自增

  > 实测（2026-11-07）：`sidecar/CMakeLists.txt` 在 `SOURCES` 与 `sidecar_tests` 两处加入 `src/skill_tool.cpp`、测试源加入 `test/skill_tool_test.cpp`、并新增编译宏 `SKILL_FIXTURE_DIR="${CMAKE_CURRENT_SOURCE_DIR}/test/fixtures/skills"`。`sidecar/test/skill_tool_test.cpp` 15 条用例覆盖上列全部条目，跨侧夹具用**同一个文件** `sidecar/test/fixtures/skills/edge-skill/SKILL.md`（305 字节、LF、无 BOM）：C++ 侧 `strip_frontmatter` 与真实 `load_skill` 都断言正文 == `kEdgeSkillBody`，Dart 侧 `kEdgeSkillBodyLines` 逐行相同。
- [x] 4.5 构建并跑：`cmake --build sidecar/build/windows --config Debug` + `sidecar/build/windows/Debug/sidecar_tests.exe "[skills]"`，贴真实输出（禁用 `ctest -R`，既有口径）

  > 实测（2026-11-07）：构建退出码 0（日志 `%TEMP%\skill_apply_4.5_build.log`，末行含 `sidecar.vcxproj -> …\Debug\sidecar.dll` 与测试可执行文件生成）。
  > `sidecar_tests.exe "[skills]"` 退出码 0：`All tests passed (97 assertions in 15 test cases)`（日志 `%TEMP%\skill_apply_4.5_tests.log`）。
  > 同轮回归（改动 C++ 后必跑）：`sidecar_tests.exe "[spill]"` 退出码 0：`All tests passed (264 assertions in 27 test cases)`（日志 `%TEMP%\skill_apply_4.5_spill.log`）。

## 5. 派发与结果组装（Dart）

- [x] 5.1 `lib/services/sidecar_bridge.dart` FFI 绑定 `load_skill`；`lib/services/agent.dart` 派发 `case 'load_skill'`：**先查生效技能集合（第一道闸，blocking-2）——技能名不在集合（含"目录存在但校验失败"）直接返回 `ok:false` 带"未生效：校验失败"原因，不调 FFI**；通过后请求带 `config.spillPreviewChars` 透传（`web_fetch` case 同形）

  > 实测（2026-11-07）：`ISidecar` / `SidecarBridge` 新增 `loadSkill(handle, requestJson)`（走 worker isolate，`_webWorkerMain` 的 `case 'load_skill'` 查 `load_skill` 导出；不设超时 —— 本地磁盘读不发网络请求，不发明新数值）；`test/integration/helpers/fake_sidecar.dart` 同步实现（`stubLoadSkill` / `lastLoadSkillRequest` / `loadSkillCallCount`）。`agent.dart` 的 `case 'load_skill'` 先查 `SkillCatalogService.instance.isActive(name)`：不在集合时按 `failureReasonFor` 分成"校验失败：<原因>"与"不在技能目录的生效集合里（当前生效技能：…）"两种，都带 `技能 "<name>" 未生效：` 前缀且**不调 FFI**；通过时请求 `{skill, file?, preview_chars: config.spillPreviewChars}`。
- [x] 5.2 `_postProcessToolResult` 组装给模型的文本：首行 `skill "<name>" (file: <相对路径>)`，正文为 C++ 形状文本，**末行** spill 引用说明（复用 `kSpillRefsMarker` 先例，含总字节与省略量、`read_spill` 取回参数——截断可见且可恢复）

  > 实测（2026-11-07）：`_composeSkillResultText` 组装（`load_skill` 且 `ok:true` 时替换 `content`）：第一行 `skill "<name>"`（无 `file` 参数时）/ `skill "<name>" (file: <相对路径>)`（有 `file` 时），随后是 C++ 形状正文，**最后一行**是 `[spill refs: skill=<ref> (<total> bytes, <omitted> omitted) — read any byte range back with read_spill(ref, offset, limit)]`（复用 `kSpillRefsMarker`，与 `web_fetch` 同一拼法）。5.3 的用例把这份字符串与"实际发给模型的 tool_result"逐字比对，并断言它出现在 `lines.last`。
  >
  > 备注（任务措辞的一处具体化）：任务写的首行形态带 `(file: <相对路径>)`；不带 `file` 时没有"相对路径"可写，故首行为 `skill "<name>"`（不编一个假的 `SKILL.md` 路径，免得说"整个文件"而实际给的是切除 frontmatter 后的正文）。两种形态都在 5.3 里有断言。
- [x] 5.3 `test/integration/load_skill_dispatch_test.dart`（FakeSidecar）：tool_use `load_skill` → 生效名走 FFI 且请求含 `preview_chars`、**校验失败名在 Dart 侧被挡（FakeSidecar 未收到调用且结果 `ok:false` 含原因）**、末行引用说明与省略量在结果文本中；贴全绿输出

  > 实测（2026-11-07）：`flutter test test/integration/load_skill_dispatch_test.dart` 退出码 0，末行 `00:00 +4: All tests passed!`（日志 `%TEMP%\skill_apply_5.3.log`）。读数：生效技能 → `loadSkill 调用次数=1 请求={"skill":"pdf-tools","preview_chars":1000}`，tool_result 首行 `skill "pdf-tools"`、末行 `[spill refs: skill=C:\spill\000001-skill.txt (200000 bytes, 198000 omitted) …read_spill(ref, offset, limit)]`；带 `file` → 首行 `skill "with-ref" (file: references/REFERENCE.md)`；校验失败技能 → `loadSkill 调用次数=0`、结果 `技能 "broken-skill" 未生效：校验失败：name 超过 64 字符（实际 65）`；未知技能名 → `调用次数=0`、结果含 `当前生效技能：known-skill`。

## 6. 既有守卫连锁更新与失败可见（不新增界面）

- [x] 6.1 **必改的计数断言（blocking-5，逐处贴改前改后）**：`test/integration/startup_tool_readiness_test.dart` 两处——未就绪清单 `11`→`12`（`load_skill` 定义在 base 同步注册即存在）、就绪后发出 `13`→`14`（装配追加），reason 文案同步改写；`test/unit/parallel_tools_docs_test.dart` 的 9/8/17 与 `tool_group_planner.dart` 两集合**不改**（`load_skill` 不入集合，不在集合的名字自动逐个段——设计 D9），该守卫在本 change 后必须仍绿（跑贴输出即回归证据）；`grep -r ToolCatalog test/ lib/` 与 `grep -rn 'kBaseToolNames' test/` 找其余钉"目录全集/基础清单"的用例逐一判定是否受影响并贴对照

  > 实测（2026-11-07）。改动逐处对照（改前 → 改后）：
  >
  > ① `test/integration/startup_tool_readiness_test.dart`
  > - 改前：`expect(unreadyNames.length, 11, reason: '未就绪那一刻恰好是"11 个本地工具"…');`
  > - 改后：`expect(unreadyNames.length, 12, reason: '未就绪那一刻恰好是"12 个本地工具"这种残缺状态（11 项基础 + load_skill；不是空清单、也不是完整清单）');`，并新增一条 `expect(unreadyNames, contains('load_skill'), …)`、把本地工具循环清单补上 `'load_skill'`。
  > - 改前：`expect(names.length, 13, reason: '完整清单 = 11 个本地工具 + web_search + web_fetch');`
  > - 改后：`expect(names.length, 14, reason: '完整清单 = 11 个本地工具 + web_search + web_fetch + 装配追加的 load_skill');`，并改写上方注释说明"模板仍写 13 项、多出来的是装配追加"。
  > - 判据不放松：两条仍是**精确等于**（不是 `greaterThan`），且新增了"未就绪时 load_skill 必须在场"这条更强的断言。
  >
  > ② `test/integration/agent_tool_filter_test.dart`（`grep` 查出来的、原先钉"请求工具全集"的两处）
  > - 改前：`expect(generalTools, ['read_file', 'write_file']);`
  > - 改后：`expect(generalTools, ['read_file', 'write_file', 'load_skill'], reason: …装配层无条件追加…);`
  > - 改前：`expect(opsTools, ['run_command', 'list_dir'], reason: '命令工具不依赖搜索或浏览器，模板允许就发送');`
  > - 改后：`expect(opsTools, ['run_command', 'list_dir', 'load_skill'], reason: …);`
  > - 改前：`expect(tools.length, ToolCatalog.kBaseToolNames.length);`
  > - 改后：`expect(tools.length, ToolCatalog.kBaseToolNames.length + 1, reason: …外加装配层无条件追加的 load_skill…);`
  > - 判据不放松：仍是精确列表/精确数（顺序也钉住），只是把"产品现在会多发一个定义"这件事写进期望值。
  >
  > ③ 其余 `ToolCatalog` / `kBaseToolNames` 命中点逐一判定（不改）：
  > - `lib/ui/setup_dialog.dart`、`lib/services/tool_catalog.dart` 的迁移目标、`test/widget/setup_dialog_test.dart`、`test/unit/subagent_docs_test.dart`、`test/integration/legacy_tool_migration_test.dart`：全部钉"基础清单 = 11 项"，`kBaseToolNames` 未动 ⇒ 不受影响（实际全绿）。
  > - `test/unit/tool_group_planner_test.dart` 与 `test/unit/parallel_tools_docs_test.dart`：已知工具集由 `kBaseToolNames`（11）+ 条件注册（6）拼出，不读 `ToolCatalog.instance.nameSet` ⇒ 不受影响。
  > - `test/integration/tool_parallelism_test.dart`：只用 `kBaseToolNames` 造目录定义，没有"发出几个"的断言 ⇒ 不受影响。
  > - `test/unit/agent_template_docs_test.dart`：只是遍历 `kBaseToolNames` 核对用户文档提到这 11 个名字 ⇒ 不受影响。
  > - `test/integration/agent_template_apply_test.dart`、`test/widget/*template*`：用自己 seed 的 `nameSet` 做编辑器候选，不吃产品的完整目录 ⇒ 不受影响。
  > - `integration_test/subagent_live_test.dart`、`integration_test/tool_parallelism_live_test.dart`：live 用例（8.x 范围），断言只到 `contains` / 抓取命中 ⇒ 本 change 不涉及。
  >
  > ④ 全量 `flutter test` 抓到、上面 grep 漏掉的两处（按同三条规矩改，改前/改后如下）：
  > - `test/integration/agent_runtime_real_bridge_test.dart`（真实 DLL + 本地 mock 服务端，直接断言"服务端收到的 tools 名单"）
  >   改前 `expect(…toList(), ['read_file']);` → 改后 `expect(…toList(), ['read_file', 'load_skill']);`
  >   改前 `expect(…toList(), ['list_dir']);` → 改后 `expect(…toList(), ['list_dir', 'load_skill']);`
  >   仍是精确列表（顺序也钉住），失败现场为 `Expected: ['read_file'] / Actual: ['read_file', 'load_skill']`。
  > - `test/unit/user_docs_test.dart`（文档↔代码名字一致性守卫）
  >   改前：`_toolDefinitionRegion()` 只切 `lib/main.dart` 的工具定义段，于是文档里的 `load_skill` / `skill` / `file` 判成"代码里找不到"。
  >   改后：该函数**多读一个来源** `lib/services/skills/skill_catalog_service.dart` 的 `kLoadSkillToolDefinition` 常量块（用标记切，不用行号），并新增 3 条 `_otherCodeNames`（`license` / `metadata` / `compatibility` → `lib/services/skills/skill_frontmatter.dart`，该清单本身有"每条都要在声称的文件里真实存在"的守卫）。
  >   判据不放松：工具定义来源从 1 处变 2 处（覆盖面变大）、新增的 3 条允许名各自被"到文件里核到"这条断言管着；实测 `注册的工具（18 个）=[…, load_skill, …]`、四类检查全绿（日志 `%TEMP%\skill_apply_userdocs.log`，末行 `00:00 +12: All tests passed!`）。
  > 
  > 运行读数（日志 `%TEMP%\skill_apply_6.1_guards.log`，7 个文件一次跑完，退出码 0，末行 `00:02 +42: All tests passed!`）：
  > - `[就绪门槛] 未就绪那一刻的工具清单（12 个）：[… , spawn_subagent, load_skill]`
  > - `[就绪门槛] 就绪后发出的工具清单（14 个）：[… , web_search, web_fetch, load_skill]`（load_skill 在尾部 = 装配追加）
  > - `[OBS] general 请求工具=[read_file, write_file, load_skill]`、`[OBS] ops 请求工具=[run_command, list_dir, load_skill]`
  > - `[OBS] 迁移后请求工具=12 项：[…, load_skill]`
  > - `[分组] 已知工具数=17 分类并集数=17 未归类={} 多出来的={}`（分组集合守卫仍绿；`parallel_tools_docs_test` 的 9/8/17 三条也全绿）
- [x] 6.2 `lib/main.dart`：启动初始化链（`_toolsReady` 置位前）调目录服务；校验失败汇总接入现有上屏提示通道（`ToolListMigration.notices` 同形的字符串提示，不新建任何界面），逐条同时进日志；文案 SHALL NOT 含密钥类串（复用既有迁移提示同款禁令）

  > 实测（2026-11-07）：`_initSearchAndTools()` 末尾 `ToolCatalog.instance.seed(base);` 之后、`_toolsReady` 置位之前 `await SkillCatalogService.instance.scan()`；`noticeLines` 逐条 `debugPrint('[AliasAgent] …')`，非空时 `setState(() => _skillFailureNotice = failureNotice)`；扫描自身抛异常时也产出一条 `技能目录扫描失败：…` 上屏提示并继续初始化。界面新增的只是一个 `Container`（`key: ValueKey('skill-failure-notice')`），文案只有"技能 \"x\" 未生效：原因"，不含任何密钥类串。6.4 的用例实测到日志行 `[AliasAgent] 技能 "broken-skill" 未生效：name 超过 64 字符（实际 65）…` 与屏幕上同一句。
- [x] 6.3 边界用例（钉「配置零改动」）：`test/unit/`——上一版 11 项默认形状与旧两项形状（`read_file`+`list_dir`）的既有模板加载后配置清单**都不含 `load_skill`**（旧两项按既有迁移升到 11 项基础清单，不升到 12）；同时其一轮请求 tools 含 `load_skill`（装配追加与配置无关）。贴全绿输出

  > 实测（2026-11-07）：`test/unit/skill_tool_config_untouched_test.dart`，`flutter test` 退出码 0，末行 `00:00 +3: All tests passed!`（日志 `%TEMP%\skill_apply_6.3.log`）。读数：`[零配置] 11 项形状：migrated=[] tools=11 含 load_skill=false`；`[零配置] 旧两项：migrated=[general] tools=11 含 load_skill=false`（迁移提示里也是 `11`）；`[零配置] 一轮请求 tools（12 个）=[…11 项…, load_skill]`，且 `agent.config.tools` 与 `registry.lookup('general')!.tools` 都不含 `load_skill`。
- [x] 6.4 `test/widget/`（或 unit，按现有测试基建就近）：有失败技能时提示字符串含技能名与原因、无技能目录时不产生任何提示。贴输出

  > 实测（2026-11-07）：`test/widget/skill_failure_notice_test.dart`，`flutter test` 退出码 0，末行 `00:00 +2: All tests passed!`（日志 `%TEMP%\skill_apply_6.4.log`）。读数：失败技能 → `[技能提示] 界面文本=技能 "broken-skill" 未生效：name 超过 64 字符（实际 65）…`（`find.byKey('skill-failure-notice')` 恰 1 个）；无技能目录 → `notice=null 提示组件=0`。扫描根由 `SkillCatalogService.rootPathOverrideForTests` 指到临时目录，不读用户主目录。
  >
  > 为了能在 `testWidgets` 的 FakeAsync 区里拿到确定结果，`SkillCatalogService.scan` 内部改用同步 IO（`listSync` / `readAsStringSync`）：真实异步 I/O 的完成事件在该区里不会被投递（实测第一次就是 `hasScanned=true` 但 `failureNotice=null`）。行为不变，2.3 的用例复跑仍绿。
- [x] 6.5 子 agent 继承（misleading-21 补任务）：`test/integration/` 经 FakeSidecar spawn 一个子 agent，断言其首轮 systemPrompt 含同一目录段、tools 含 `load_skill`。贴全绿输出

  > 实测（2026-11-07）：`test/integration/subagent_skill_inheritance_test.dart`，`flutter test` 退出码 0，末行 `00:00 +1: All tests passed!`（日志 `%TEMP%\skill_apply_6.5.log`）。读数：`父请求数=2 子请求数=1`；子首轮 systemPrompt 实拍里含 `Available skills (…)` + `- alpha-skill: …` + `- pdf-tools: …`；`子首轮 tools=[read_file, load_skill]`（`spawn_subagent` 仍被排除）。

## 7. 用户文档与守卫（与代码同一 change）

- [x] 7.1 新建 `Docs/user-guide/skills.md`：装在哪（`~/.aliasagent/skills/<name>/SKILL.md`，格式按 `Docs/AgentSkillsDoc.md` 引用的开放规范）、怎么算生效（放好文件重启即生效，**无需任何模板勾选或开关**）、出错会看到什么（校验失败提示行示例、未知/未生效技能报错形态、`../../` 越界报错形态）、长正文头尾预览与 `read_spill` 取回、**内联预览的换行归一与坏字节 U+FFFD 说明（与 `tools-command.md`/`tools-web.md` 同条款口径，spill delta 已点名本文档）**、已知限制（无热更新、无工作区级、无管理界面=目录约定即安装、附属文件非 ASCII 文件名与 `read_file` 同源的窄字符路径限制）
- [x] 7.2 `README.md` 功能文档索引加一行；`Docs/user-guide/configuration.md` 的 `spill.preview_chars` 行"适用工具"增补 `load_skill`；`Docs/user-guide/tools-file.md` 工具清单处加 `load_skill` 交叉引用（**不写进「并行执行」小节的名单**——该节被 `parallel_tools_docs_test` 钉住恰好 17 名）
- [x] 7.3 新建 `test/unit/skills_docs_test.dart`（能失败的守卫）：`skills.md` 存在且含 `~/.aliasagent/skills`、`重启`、`read_spill`、`U+FFFD` 字样；`configuration.md` 的 `preview_chars` 行同时含 `web_fetch` 与 `load_skill`；README 索引含 `Docs/user-guide/skills.md`；`tools-file.md` 并行小节不含 `load_skill`（写了就红——钉 D9 口径）。删任一处文档该用例即红；贴全绿输出

  > 实测（2026-11-07，主循环裁定后重跑）：`flutter test test/unit/skills_docs_test.dart` 退出码 0，末行 `00:00 +4: All tests passed!`（日志 `%TEMP%\skill_apply_7.3_rerun.log`）。读数：`skills.md 长度=2202 含 ~/.aliasagent/skills=true`；`configuration.md 的 preview_chars 行数=1` 且该行同时含 `web_fetch`、`load_skill`；`README 含 skills.md 索引=true`；`并行小节里 load_skill 出现次数=0`。
  >
  > **判据的放宽与收回（改前/改后，可溯源 / 不放松 / 留对照）**：
  > - 任务原文（改前）：`skills.md` 必须含字面量 `~/.aliasagent/skills`。
  > - 中途放宽（第一次实现）：当时已就位的 `Docs/user-guide/skills.md` 只写了 Windows 实写形态 `C:\Users\你\.aliasagent\skills\`，全文 0 次 `~/.aliasagent/skills`（同一机器实测 `Contains('~/.aliasagent/skills')` = `False`），于是改成"归一化分隔符后含 `.aliasagent/skills`，且 `~` 或 Windows 实写两种前缀之一"。
  > - **裁定与收回（主循环 2026-11-07）**：任务原文优先，文档配合任务而非相反；`skills.md` 已补回 `~/.aliasagent/skills/` 写法（同时保留 Windows 实写说明）。本用例随之改回**单形态字面量**断言（改后与改前同形，更严）：`expect(doc, contains('~/.aliasagent/skills'))`。
  > - 不放松的实测依据：同一条断言在文档补写前为 `False`（长度 2127）、补写后为 `True`（长度 2202）—— 它真的读那份文档、也真的能失败。其余三条（`重启` / `read_spill` / `U+FFFD`）全程逐字未动。
  > - 留对照：本条备注即对照；`test/unit/skills_docs_test.dart` 的文件头注释也记了这次"放宽 → 裁定 → 收回"的来由。

## 8. live 验证（真实模型）

- [x] 8.1 新建 `integration_test/skills_live_test.dart`：前置——`~/.aliasagent/skills/` 不存在则本用例创建并在结束后**删除整个本次新建**（若用户已有该目录则只加删本次夹具子目录，同名冲突停工如实报告）；临时配置：模型换 magpie 目录内真实模型、`agent_types.general.tools` 现值备份+SHA256 校验还原（**白名单不加 `load_skill` 也要跑一季**——无条件交付的实证；换模型段用完还原）。断言前必须输出：systemPrompt 目录段实拍、模型实际 tool_use（工具名+完整 input）、结果文本、spill 文件路径与字节数、`read_spill` 取回片段与原文一致

  > 主循环完成（2026-11-08）。两版返工记录：第一版夹具按"字节>2000"设计实为 ~1900 字符 ≤ 阈值——产品正确全文内联、`0 omitted`，用例断言必红（教训写进用例注释：判定基准是字符 `spill.cpp:621`）；第二版定长 200 字节窗口切进中文码点，`read_spill` 按规范正确报"区间末尾落在多字节字符中间"（产品行为=规范，读法越界=用例问题），改整行读（换行边界必是码点边界）。
- [x] 8.2 跑 `flutter test --tags live --run-skipped integration_test/skills_live_test.dart -d windows`（live 流程自带短暂窗口属用户批准范畴；除此之外禁止起窗）；`read_image` 读 `test/live_visual/skills_live.png` 做视觉验收并贴结论

  > 主循环实测（2026-11-08，第三跑 `00:08 +1: All tests passed!`，日志 `%TEMP%\skill_8.2_live3.log`）：工具卡序列 `[load_skill, read_spill]`（白名单 11 项不含 `load_skill` 仍被模型自主调用=无条件交付实证）；信封 `total=21356 omitted=16112` 与 spill 文件实际字节相等；暗号行整行读回 `ok=true offset=10834 len=41` 逐字节一致；最终回答 35 字符含暗号；无 `run_command`/`read_file` 卡（链路纯净）。视觉验收：截图见 `load_skill` Done 卡（首行 `skill "aliasagent-live-skill"`）、模型自述"middle section was omitted. Let me read it back"、`read_spill` Done 卡 ref 指向 `000001-skill.txt`，界面正常无白屏。配置已还原（SHA256 `3532699E…` 逐字节一致），夹具目录已清理（`Test-Path skills`=False）。

## 9. 全量验证与变异（主循环批次执行）

- [x] 9.1 `flutter analyze`（对照验证清单基线，改动文件零新增）；`scripts\sync_sidecar_dll.ps1` 后 `flutter test` 全量（贴 `+N All tests passed!`）；`ctest --test-dir sidecar/build/windows -C Debug` 全量

  > 主循环实测（2026-11-07，job pwsh-e68179ba2b4645a7，串行链 sync→VM→ctest→analyze）：① `flutter test` 全量 `01:47 +796: All tests passed!`（日志 `%TEMP%\skill_9.1_vm.log`）；② `ctest --test-dir sidecar/build/windows -C Debug` `100% tests passed, 0 tests failed out of 1`，Total 116.76s（`skill_9.1_ctest.log`）；③ `flutter analyze` `161 issues found.`（`skill_9.1_analyze.log`）——与基线 161 相等，本次改动文件零新增（我曾给 live 文件引入 2 error/3 噪声，已当场修至 `No issues`）；④ sync `SYNC-OK: sidecar.dll already current`（`skill_9.1_sync.log`）。
- [x] 9.2 变异 ≥2 处并贴各自变红证据后当场恢复：①断开 `skill_tool.cpp` 的 `shape_stream` 接线（长正文用例必须红）；②注释掉 `toolDefinitions` 的 `load_skill` 追加行（3.3 的"tools 数组含定义"用例必须红）。恢复后复跑相关测试全绿、`git diff` 零残留

  > 主循环实测（2026-11-07~08）：② 变异 `agent.dart` 追加行为 `return resolved` → `flutter test skill_catalog_injection_test.dart skill_tool_config_untouched_test.dart` 退出码 1、`-3`，读数 `Expected: contains 'load_skill'`、tools 实际 11 项缺该定义（`%TEMP%\skill_9.2_mutB_red.log`）→ 恢复 → `+6 All tests passed!`（`skill_9.2_mutB_restore.log`）→ 文件 SHA256 与变异前**逐位相同**（`CB209017…C507`）。① 变异 `skill_tool.cpp` 跳过 `shape_stream` 构造空信封假形状 → 重建（build 0）→ `sidecar_tests.exe "[skills]"` 退出码 3、5 条 FAILED + `json.exception.type_error.302`（空信封被读，`skill_9.2_mutA_red.log`）→ 恢复 → 重建 → `[skills]` `97 assertions in 15 test cases` 全绿、`[spill]` `264/27` 全绿（`skill_9.2_mutA_restore.log`/`skill_9.2_mutA_spill.log`）→ SHA256 逐位相同（`38D9E92D…E9F1`）→ `sync_sidecar_dll.ps1` 重同步（built 2026/11/8 16:22:18）。两文件哈希=变异前基线即"零残留"的最终证据（新文件不在 `git diff` 视野，哈希口径替代）。

## 10. 登记与归档准备

- [x] 10.1 `Docs/known-bugs.md` 追一条：附属文件非 ASCII 文件名在 C++ 窄字符路径 API 下的取不到风险（症状/根因方向=与 `read_file` 同源既有面、证据=4.4 用例只保 ASCII、重新考虑时机=统一修路径 API 的 change）

  > 主循环完成（2026-11-07）：条目「load_skill / read_file：附属文件的非 ASCII 文件名…」已追入 `Docs/known-bugs.md` 文末（症状/根因方向/证据=[skills] 夹具全 ASCII/重新考虑时机=统一宽字符化 change 四要素齐）。
- [x] 10.2 归档同步时（由归档轮主循环处理，非 apply）：主 spec `tool-output-spill` 的「工具输出先落盘」条**标题**改为三工具形态、`## Purpose` 范围句同步加 `load_skill`；本条与 delta 中括号注（标题更新）互为对照，处理完删除该注

  > 归档轮完成（2026-11-08，子 agent 实测）：新建 `openspec/specs/skills/spec.md`（`## ADDED Requirements` 下 6 个需求块逐字落地，标题改 `# skills Specification`、`## Purpose` 为自写、无 BOM、零 `## ADDED Requirements` 残留）；主 spec `tool-output-spill` 5 个 MODIFIED 块逐块替换为 delta 内容（标题已改三工具形态、`## Purpose` 范围句已改三工具），delta 里那条标题更新括号注**已删除**（主 spec 内 `归档同步时` 残留 0）；`openspec validate --specs` 59 → 60，0 失败。
- [x] 10.3 `openspec validate add-skill-mechanism` 通过并贴输出

  > 实测（2026-11-07）：`openspec validate add-skill-mechanism` 退出码 0，输出 `Change 'add-skill-mechanism' is valid`（日志 `%TEMP%\skill_apply_10.3.log`）。
