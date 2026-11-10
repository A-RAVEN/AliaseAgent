# Tasks: add-slash-commands

按物理顺序执行。数字与判据回链：判定规则=首字符 `/` + 首段逐字等于当轮生效技能名（design D2，空白集合=U+0020/U+0009/U+000A，U+3000 不算）；展开点在 `_buildApiMessages` 的 user 文本块构造处（D1）；模板=固定前缀句+两个换行+余下正文（D3）；接口返回单个 String、未命中原样返回（D4）。落库/标题/对话视图气泡保持原文是硬判据；既有「真实上下文」屏显示展开后文本是既有规范的如实披露，不是缺陷。

## 1. 纯函数服务（Dart）

- [x] 1.1 新建 `lib/services/slash_commands.dart`：`String expandSlashCommand(String text, List<String> activeSkillNames)`——命中返回模板拼接结果，未命中原样返回入参。规则（design D2）：**text 为空串（length==0）时直接原样返回，不做首字符判定**（对应只有图片附件的历史消息）；首字符必须是 `/`；首段=斜杠后到首个空白（U+0020/U+0009/U+000A）或文本末尾；逐字命中当轮集合才展开（大小写不一致不命中；全角空格 U+3000 不算空白，所以 `/edge-skill　正文` 不命中）；余下正文跳过一个空白、可为空。模板形态钉死：**固定前缀句 + "\n\n" + 余下正文**，空正文时文本止于前缀句后的两个换行。前缀句精确措辞（以此为准，写进代码注释并注明出处=本任务）：`已按斜杠命令展开技能 "<技能名>"：请先调用 load_skill(skill: "<技能名>") 读取该技能说明并严格遵循其中的指令，然后处理下面的请求：`。零 IO 零状态
- [x] 1.2 新建 `test/unit/slash_commands_test.dart` 全覆盖：命中带正文——**整段逐字断言** `expect(expandSlashCommand('/edge-skill 把这段文字按技能要求处理', names), '已按斜杠命令展开技能 "edge-skill"：请先调用 load_skill(skill: "edge-skill") 读取该技能说明并严格遵循其中的指令，然后处理下面的请求：\n\n把这段文字按技能要求处理')`（期望串在测试里硬编码，禁止引用实现常量拼期望）；命中空正文——断言文本止于前缀句后的两个换行且技能名正确、且 `isNot('/edge-skill')`；未命中清单（`/` 单独、首段不匹配、大小写不一致如 `/Edge-Skill x`、前导空格、消息中段出现 `/name`、`/edge-skill正文` 无空白分界、`/edge-skill　正文` 全角空格、**空串**、`activeSkillNames` 为空）——逐一断言返回值与入参逐字相同。贴全绿输出

## 2. 装配面接线（Dart）

- [x] 2.1 改 `lib/services/agent.dart` 的 `_buildApiMessages(List<Message>)`：在逐条循环外取一次 `final activeNames = SkillCatalogService.instance.activeSkillNames;`（禁止缓存到 Agent 字段或构造期快照），在构造 user 正文文本块处（`if (msg.content.isNotEmpty) content.add({'type': 'text', 'text': msg.content})`）改为：仅当 `msg.role == 'user'` 时写入 `expandSlashCommand(msg.content, activeNames)` 的返回值，非 user 消息原样。**禁止**在 `_callModel` 工具轮或装配后的 apiMessages 层做替换（那里 role=='user' 的条目可能是 tool_result 块列表）。注释写明：`_callModel` 与压缩投影 `_buildCompactionProjection` 共用本入口，投影里的历史 user 消息一并按当轮集合展开；落库/标题/对话视图气泡早于装配、天然是原文。`flutter analyze` 改动文件零新增
- [x] 2.2 新建 `test/integration/slash_command_expansion_test.dart`（FakeSidecar + `setRootForTests` 临时根，夹具技能固定为 `edge-skill`：临时根下建 `edge-skill/SKILL.md`，frontmatter `name: edge-skill` + 非空 description）：①发送 `/edge-skill 把这段文字按技能要求处理` → 记录到发往模型的 user 文本**逐字等于**任务 1.2 的整段期望（防接线截断后仍"含指示"而误绿）、`messageRepo` 落库的 user 消息逐字是手打原文；②发送普通消息 → 模型文本=原文；③**双向用例（当轮集合语义专属，缺实现即红）**：第一轮发送 `/edge-skill 干活` 并断言该轮请求里是展开版 → 轮间删掉该技能 → 第二轮发普通消息，断言历史里那条原样不展开；④技能未删时第二轮重新装配，断言历史那条仍是展开版、新消息逐字原文（spec「历史消息逐条展开」场景）。贴全绿输出

## 3. 界面、文档与守卫

- [x] 3.1 新建 `test/widget/slash_command_display_test.dart`：setUp 用 `SkillCatalogService.instance.setRootForTests(临时根)` 摆合法 `edge-skill`（tearDown 恢复默认根并 `resetForTests`）；输入框键入 `/edge-skill 正文` 点发送，聊天气泡显示的 user 文本逐字是手打原文（展开对对话视图不可见）。贴全绿输出
- [x] 3.2 新建 `Docs/user-guide/slash-commands.md`（用户视角：怎么用、命中规则逐字匹配、空白分界说明含全角空格不生效、未命中静默透传、零界面；**必须含一段「怎么核实」**：发 `/技能名 正文` 后切「真实上下文」视图，那条 `[n] user` 消息的文本即模型实际收到的展开版——聊天气泡、标题、落库仍是原文；该屏只显示最近一次实际发出的内容，见 real-context-view.md）；`README.md` 功能索引加一行；文档守卫（`test/unit/skills_docs_test.dart` 旁新建或扩展）断言：文档存在 + 含「真实上下文」与 `real-context-view.md` 交叉引用 + README 索引行存在（能失败的判据）
- [x] 3.3 不需要 README 条目 allowlist 同步：`test/unit/user_docs_test.dart` 的「README 的功能索引与 Docs/user-guide/ 双向一致」用例（目录扫描 + 正则抽链接双向比较）在 3.2 落地后自然满足；注意其链接匹配范围是整份 README、不限索引小节，所以 3.2 自己那条索引行断言仍要保留。若 slash-commands.md 用反引号写出既非工具名/参数名/配置键的小写代码名导致 `user_docs_test` 的 `_otherCodeNames` 变红，再点名补白名单并贴改前红证据；无此情形的说明为什么不改

- [x] 3.4 文档缺口修复（apply 阶段发现）：`Docs/user-guide/skills.md` 末行「`/斜杠命令` 式的显式触发是后置的另一期」在本 change 落地后已不成立——「助手什么时候用它」节改指 [slash-commands](slash-commands.md)，「已知限制」末条改为如实写未命中静默透传的规则（apply 阶段由主循环当场修，守卫 skills_docs_test / slash_commands_docs_test 复跑绿）

## 4. 全量验证与变异（主循环批次执行）

- [x] 4.1 `scripts\sync_sidecar_dll.ps1` 后 `flutter analyze`（基线 161——出处：`openspec/changes/archive/2026-11-08-add-skill-mechanism/tasks.md` 9.1 记录的 `161 issues found.`，日志 `%TEMP%\skill_9.1_analyze.log`；本 change 开工复跑 HEAD `df6edda` 仍为 161，审查轮 15:11 有独立复跑留档——改动文件零新增）+ `flutter test` 全量贴 `+N All tests passed!`
- [x] 4.2 变异：把 `expandSlashCommand` 改成恒返回入参（未展开）→ 1.2 的命中断言与 2.2 的①③④必须红（③④红来自各自的第一轮"已展开"前置断言，②不受影响是透传正向用例）；贴红证据后当场恢复，复跑全绿、`lib/services/slash_commands.dart` 与 `lib/services/agent.dart` 哈希与变异前逐位相同
- [x] 4.3 `openspec validate add-slash-commands` 通过贴输出
