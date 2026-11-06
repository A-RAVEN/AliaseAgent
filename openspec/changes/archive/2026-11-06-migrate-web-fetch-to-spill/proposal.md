# Proposal: web_fetch 正文迁入 spill 交付通道

## Why

`web_fetch` 抓到正文后，Dart 侧在 `_formatSearchResultForDisplay`（`lib/services/agent.dart`）里把它裸切成前 2000 个字符加三个点（`content.substring(0, 2000)` + `'...'`）。这个 2000 是**没有出处的魔数**（不属于四类合法来源：无配置键、非用户要求、非平台硬限、产品里没有第二处引用它的常量），且切出来的标记**只说"有省略"、不说"略去了多少、去哪取回"**——直接违反用户钉死的双硬要求"砍内容必须可见、可见之后必须可恢复"。真机日志曾抓到实例（提案时点观察，原始日志文件后续已轮转）：一次抓取正文 19,806 字符，模型只看到 2,013，其余 17,793 字符无任何取回途径。

而产品里已经有解法：`tool-output-spill` 能力（`run_command` 在用）——完整输出先原样落盘，模型收头尾预览加引用，中段用 `read_spill` 按字节读回。该能力的规范原文预留了本 change 的位置：「`web_fetch` / `grep_file` / `read_file` 的迁移**不在本期**、另开 change」——本 change 只接其中 `web_fetch` 一个，另外两个仍另行立项。

## What Changes

- `web_fetch` 成功结果的正文交付从"Dart 侧 2000 字符硬切"改为 spill 通道：C++ 侧把**完整正文**先落盘到本上下文的 spill 目录（流名 `content`），再按既有规则交付——全文不超过 `preview_chars × 2` 时内联全文，超过时只内联头尾各 `preview_chars` 个字符并写明省略字节数、总量与 `read_spill` 取回参数。
- 删除 Dart 侧的 2000 硬切；Dart 改为把 spill 引用行拼在正文**最后一行**（与 `run_command` 的 `composeCommandResultText` 同一手法，保证重放阶段的通用省略掐不到取回入口）。
- `spill.preview_chars` 随 `web_fetch` 请求传给 C++（与 `run_command` 同形态），不发明新配置键、新数字。
- 写盘失败沿用既有规则"写盘失败必须可见"：正文不超阈值仍可内联，超阈值必须报错。
- C++ 侧把 `run_command` 私有命名空间里的"落盘+形状拼装"逻辑（`shape_stream`）提为共享实现，`web_fetch` 与 `run_command` 用同一份，不变量只维护一处。
- 界面与用户文档同步：交付给卡片的文本与发给模型的正文是同一份字符串（卡片结果行仍按既有 UI 机制显示前 200 字符折叠摘要，完整正文在工具调用记录里，用户文档如实说明）；`Docs/user-guide/tools-web.md` 里 web_fetch 的截断描述改写为 spill 取回办法。

## Capabilities

### New Capabilities

（无。本 change 全部落在既有能力上。）

### Modified Capabilities

- `tool-output-spill`：适用范围从"只在 `run_command` 实现"扩展到含 `web_fetch`（落盘、按长度决定内联/头尾、信封带量、`read_spill` 读回、写盘失败可见五条要求全部覆盖 web_fetch；Purpose 与"本能力目前只在 run_command 上实现"的范围限定段相应改写）。
- `web-fetch`：结果正文的交付形态要求变更——删除"前 2000 字符"式静默截断，改为 spill 交付；原"通用截断的再取入口带网址"场景升级为 spill 引用场景（网址回显、SSRF、体积保护等其余要求不动）。

## Impact

- `sidecar/src/web_fetch.cpp`：成功路径接入落盘与形状拼装（需 ctx 与会话键；`web_fetch_impl` 签名调整）。
- `sidecar/src/command_tool.cpp` / `sidecar/src/spill.cpp` / `sidecar/include/spill.h`：`shape_stream` 从 run_command 私有命名空间提为共享函数，两条流（stdout/stderr 与 content）走同一实现。
- `lib/services/agent.dart`：`_formatSearchResultForDisplay` 的 web_fetch 分支删除硬切；`_postProcessToolResult` 拼接 spill 引用行（保末尾）；web_fetch 请求 JSON 加 `preview_chars`；`_buildResultSections` 展示同步。
- 测试：C++ `sidecar/test`（形状与不变量、并发序号沿用既有 tag）、Dart `test/unit` + `test/integration`（假 sidecar 全链）、真实 sidecar 用例（本地 HTTP 长页面，验落盘与 `read_spill` 读回）。
- 文档：`Docs/user-guide/tools-web.md`（截断与取回行为）、`Docs/user-guide/configuration.md`（`spill.preview_chars` 适用工具范围）；归档时同步 `openspec/specs/tool-output-spill/spec.md` 与 `openspec/specs/web-fetch/spec.md`。
- 数据兼容：旧会话重放时，历史 web_fetch 正文是旧形态（前 2,000 字符加三个点），无 spill 引用——原样交付、不报错、不回填；**历史数据被切掉的中段在本机制出现前就已丢失，无法按它取回**，这一点在用户文档如实写明（spill 取回自本 change 起生效），不许写成"重放也能找回"。
