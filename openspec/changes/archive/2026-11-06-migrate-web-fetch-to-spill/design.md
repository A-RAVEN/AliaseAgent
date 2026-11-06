# Design: web_fetch 正文迁入 spill 交付通道

## Context

工具正文的"可见可恢复"截断已有完整机制（能力 `tool-output-spill`，由 change `spill-large-tool-output` 建立）：完整输出先原样落盘到 `~/.aliasagent/spill/<上下文>/<序号>-<流名>.txt`，模型收"头尾预览 + 省略量 + 引用"，中段用 `read_spill(ref, offset, limit)` 按字节读回。该机制目前只有一个调用方——`run_command`（`sidecar/src/command_tool.cpp` 的 `shape_stream`，匿名命名空间私有）。规范原文把其余工具的迁移明确留给另开的 change。

`web_fetch` 现状是这条规则的反例：C++ 侧（`web_fetch_impl`）返回**全文**正文；Dart 侧 `agent.dart` 的 `_formatSearchResultForDisplay` 把它切成 `content.substring(0, 2000)` 加三个点。2000 这个数字没有任何合法来源（不是配置项、不是用户要求、不是平台硬限、产品里没有引用它的常量）；标记不含略去量、不含取回途径；重放阶段的通用省略通道（`elideOversizedToolResult`，阈值 8000）因正文已被切到 2,013 而永远不触发，它精心准备的 `refetch via web_fetch "<网址>"` 尾注对 web_fetch 实际形同虚设。真机日志曾实测（提案时点观察，原始日志文件后续已轮转）：抓 19,806 字符，模型见 2,013，其余不可恢复。

## Goals / Non-Goals

**Goals:**
- `web_fetch` 的模型可见正文不再被无来源的 2000 硬切；超长正文按 spill 契约交付：头尾预览 + 省略字节数 + 总量 + 可按字节读回的引用。
- 头尾预览的规模沿用现有配置项 `spill.preview_chars`（默认 1000，内联上限 `preview_chars × 2`）——与现状"模型见约 2,000 字符"同量级，上下文负担不增加，但取回从不可能变成可能。
- C++ 侧"落盘+形状"逻辑一份实现，`run_command` 与 `web_fetch` 共用；三条不变量（原始字节切片、内联仅消毒、引用可读回）只维护一处。
- 界面卡片与用户文档如实反映新行为。

**Non-Goals:**
- `web_search` 的搜索结果拼装（`assembleSearchText`，预算取既有常量）不动。
- `grep_file` / `read_file` 的迁移不在本期（它们本就能按参数重读原文件，spill 收益不同，留待另行立项）。
- 抓取侧的体积与超时保护（`kMaxResponseBytes` 10MB 拒绝、15 秒超时）不动——那是"拒收"的保护，与本期"收到后如何交付"无关。
- 旧会话里已按旧形态存储的 web_fetch 结果不回填、不改写（历史事实）。

## Decisions

### D1 截断点从 Dart 移到 C++ 的 spill 通道

`web_fetch_impl` 成功返回前，把正文 `body` 走"落盘 + 形状"：全文写进本上下文的 spill 文件（流名 `content`），返回值里 `content` 字段为**形状后的内联文本**（短=全文；长=头 `preview_chars` + 省略说明 + 尾 `preview_chars`），并附 `spill` 信封（`ref` / `total_bytes` / `omitted_bytes`）。理由：`read_spill` 只认 spill 目录里的文件，落盘必须在 C++ 侧；且 `run_command` 已验证该形状。备选"Dart 侧自己写文件"被否——要复制目录布局、序号、清理时机全套机制，第二份真相。

### D2 `shape_stream` 提为共享实现

把 `command_tool.cpp` 匿名命名空间里的 `StreamShape` + `shape_stream` 原样提升到 `spill.h` / `spill.cpp`（签名不变：`(ctx, raw, preview_chars, session, tag, &written)`），`run_command` 与 `web_fetch` 各自调用。提升而非复制：三条不变量与省略说明的措辞只此一份。`web_fetch` 用 tag `"content"`；文件名 `<序号>-content.txt`，序号仍来自上下文原子计数器（并行段内多路 web_fetch 并发安全已由既有不变量保证）。

### D3 `preview_chars` 随请求传递

`web_fetch` 的请求 JSON 增加 `preview_chars` 字段，值取 Dart 配置 `config.spillPreviewChars`（顶层 `spill.preview_chars`，默认 1000，非法值回落在 `AppConfig.fromJson` 已有处理）——与 `run_command` 同形态（读请求字段、缺省回落）。缺省回落常量 `kDefaultPreviewChars = 1000` 现居 `command_tool.cpp` 的匿名命名空间（跨文件取不到），随形状实现一起提升到 `spill.h`（`spill::kDefaultPreviewChars`，用户原话与出处的注释同行），两个工具共读这一份。不新增配置键、不新增数字。

### D4 Dart 侧拼装：引用行保持在最后一行

`_postProcessToolResult` 的 web_fetch 分支改为：标题/网址行 + C++ 交付的正文（可能已含"省略说明"中段）+ **最后一行**的 `[spill refs: …]` 引用行（复用常量 `kSpillRefsMarker` 与 `composeCommandResultText` 同款拼法）。引用行置尾的理由既有规范背书：重放阶段通用省略只保头尾，放中间会被自己掐掉；且 `elideOversizedToolResult` 的 `bodyHasSpillRefs` 靠这个标记决定尾注说"可用 read_spill 读回"还是"请重新给出地址"。`_formatSearchResultForDisplay` 的 web_fetch 分支删除硬切，其余（空正文 `(fetched empty page)` 提示）保留。

### D5 写盘失败沿用既有规则

正文 ≤ `preview_chars × 2` 时落盘失败无所谓（全文已能内联）；超过阈值时落盘失败必须返回 `ok:false`，错误说明含目录与系统原因，SHALL NOT 只给一段冒充完整结果——`tool-output-spill` 的"写盘失败必须可见"要求原文，web_fetch 纳入适用范围后直接继承，不另立分支。

### D6 与既有通路的关系（逐条确认，无遗漏消费者）

- **并行执行**（能力 `agent-runtime` 并发组）：web_fetch 在只读集合内，可并发执行；`spill::write_for_context` 不经写闸门、序号原子，"同一上下文并发不撞序号"场景已覆盖，多路 web_fetch 与 run_command 混段并发共用同一份保证。
- **异步执行入口**：web_fetch 走 `sidecar.webFetch()`（`sidecar_bridge.dart` 内部 `_workerTool` → worker 线程，超时 120 秒既有值），并行段与串行同一条路；`requestJson` 原样传给 FFI（含新加的 `preview_chars`），无特殊处理。
- **界面卡片**：交付给卡片的文本与发给模型的正文是同一份字符串（`_buildResultSections` 的 web_fetch 分支与 `result['content']` 同源，迁移后自然同为"预览 + 省略说明 + 引用行"）；卡片结果行 `_buildItem` 仍显示前 200 字符折叠摘要、完整正文在工具调用记录 `activity.result`——既有 UI 机制，本期不改卡片排版，用户文档如实说明。
- **旧会话重放**：历史 `toolCallsJson` 里旧形态正文（≤2,013 字符）原样重放，不报错、不回填；它够不到通用省略阈值（8,000），不产生任何尾注——**历史数据被切掉的中段在本机制之前就已丢失，取不回来**，用户文档如实写明"spill 取回自本 change 起生效"，不许写成可找回。用户调大 `preview_chars` 后出现的大于 8,000 字符正文仍走通用省略，其取回尾注已有 url 回退（`refetchArg`，上一 change 修好）。

## Risks / Trade-offs

- **每次抓取都产生一个 spill 文件**：与 `run_command` 同价——目录按上下文隔离、`dispose_context` 排空在途后整目录删除（既有机制，无新增泄漏面）。长会话高频抓取时磁盘占用上升，量级为正文原样字节，可接受；不为它发明清理策略（现有生命周期已闭环）。
- **模型可见正文的字符数上限从 2,013 字符（2,000 字符加三个点）变为约 `preview_chars × 2` 字符加省略说明与引用行**：默认配置下规模相同（2,000 字符级），但用户把 `spill.preview_chars` 调大时 web_fetch 上下文占用随之增大——这是把隐藏常数换成受控配置项的预期后果，配置键文档已有"头尾各留多少字符"的说明，本 change 只需把适用范围补上 web_fetch。
- **curl 兜底路径与 Python 抓取器路径两条来源都要接同一个形状函数**：`web_fetch_impl` 里两条成功路径是**两个独立 return**（crawl4ai 成功在 `return parsed.dump()`，curl 成功在 `result["content"] = body; return result.dump()`），**不存在天然汇合点**（初稿误写为"汇合处"，自查时代码核实后改正）——形状函数必须在两个 return 前各调用一次，漏任何一个即该路径仍是静默截断/未落盘，测试任务对两条路径分别设可失败判据。
- **提升 `shape_stream` 触碰 `run_command` 既有行为**：纯移动不改语义，`run_command` 的既有 spill 测试（`[spill]` tag）是回归判据；红了就是搬错了。
