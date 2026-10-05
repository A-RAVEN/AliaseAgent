## Why

上一轮（`add-deepseek-web-search`）真机验收暴露出一件事：**好几处"内容被砍"都是悄悄发生的** —— 砍了不标记、标记了又拿不回来，模型和我都看不出信息缺了一块。

用户 2026-10-05 的原话：「你似乎很喜欢在我没有提过任何需求的情况下设很保守的上限，之前 webfetch 时也是，这个行为非常糟糕」「2000 字预算好像从来不是我的要求」。据此已立下规矩：设计里不许出现无出处的上下限魔数，砍内容必须可见、可见之后必须可恢复（规则在 `~/.dsh/AGENTS.md` 第 9 节）。

这个变更把那批已经查实的实例一次改掉。

## What Changes

- **`deepseek` 搜索请求里的 `max_tokens`**：现在写死 2048（我编的），改成不设该参数、由服务端按文档默认值执行（`Docs/DeepSeekAPIDoc.md`：取值范围 1~384K，**未设置时非思考模式默认 8K**），并读返回里的 `stop_reason`：被截断时不许沉默，要写进错误说明。
- **`deepseek` 搜索响应体上限**：现在 16MB 超限直接中止、不说明丢了多少，改成超限时写明"响应超过上限、已中止"并给出实际收到的字节数，且不再把"中止"混同于网络失败。
- **`web_search` 拼给模型的那段结果**：现在第一个后端的预览一旦把 2000 字预算吃满，**后面的后端整段消失**（真机实测：3 个后端、11 条结果，模型只看到其中一个后端）；那条"还有 N 个后端没显示"的标记**说不出丢的是谁、各丢了多少条**。改成每个后端先无条件写自己的结果行，剩余预算按后端数量均分给首条预览，收尾标记说清略去了哪些后端、各多少条。
- **`web_fetch` 正文被砍后的标记**：现在标记里 `refetch via` 是空的（`web_fetch` 没有 `path` 参数），模型拿不回全文。改成标记里带上原网址，模型能自己再抓一次。
- **界面启动时的工具清单时序**：现在界面在动态那批工具装好之前就能发消息，那一轮模型收到的清单里**缺 `web_search` / `web_fetch` / 浏览器四件套**（本地工具那 8 个是在 `await` 之前同步装好的，所以不是空清单）。改成"动态工具装好之前不许发"，或者"首轮请求发出前必须已经装好"。
- **统一规则落成一条能力**：新增 `truncation-visibility`（砍必须有标记、标记必须说清略去了什么与多少、必须能取回），并给三条已有规范补 delta —— `context-compaction`（它的 Near-zone elision 已经要求"截断标记 + 再取记录"，取回形态要统一）、`file-search`（`glob_file` / `grep_file` 现在只回 `truncated:true`）、`deepseek-search-provider`（它写着请求体必须含 `max_tokens`，与本次删掉该参数直接冲突）。

## Capabilities

### New Capabilities
- `truncation-visibility`: 一切"内容被砍"的处置总规则 —— 砍必须有标记、标记必须说清略去了什么、被略去的内容必须能通过某个入口取回；禁止静默降级。
- `startup-tool-readiness`: 界面启动到"可以发消息"之间的就绪条件 —— 工具清单未装好时不许发起那一轮请求（或必须先把清单补上）。

### Modified Capabilities
- `web-fetch`: "Curl fallback size protection" 那条由"限大小"扩展到"限大小 + 越界必须可见且可恢复（带原网址）"。
- `basic-tools`: `read_file` 的行数上限与截断提示要并入统一规则（缺省 2000 行、`limit` 上限 100000；现在的提示只说"Use offset/limit to read more."，给不出可照抄的续读参数）。
- `context-compaction`: `Near-zone oversized tool_result body elision` 已经要求"截断标记 + 再取记录"，本次把"再取记录"的形态写清并纳入统一规则（不另立一套形态）。
- `file-search`: `glob_file` / `grep_file` 的截断现在只有 `"truncated":true`，补上"略去了多少 + 取回入口"。
- `deepseek-search-provider`: 请求体 SHALL NOT 再要求 `max_tokens`；补上"输出被截断时必须报错"（读 `stop_reason`）这条要求。
- `model-gateway`: 新增一条要求「API 报错时要说明原因」—— 现在端点返回 4xx 时，响应体只写进 `sidecar.log`，交给模型与用户的只有一句 `API returned HTTP <码>`（401 那一支连状态码都换成固定话术），服务端给的原因整段丢掉。

## Impact

**代码**
- `sidecar/src/deepseek_search.cpp`：`DEEPSEEK_MAX_TOKENS`、`DEEPSEEK_MAX_RESPONSE_SIZE`、`CurlTransport::post()` 的写回调与错误分支、`search()` / `map_response()` 里对 `stop_reason` 的读取。
- `lib/main.dart`：`_formatSearchResultForDisplay()`（模型看到的那段结果）、`ChatScreenState` 与 `_initSearchAndTools()` 之间的就绪条件、`_elideOversizedToolResult()` 的再取路径拼法。
- `lib/ui/chat_area.dart`：发送入口的"工具未就绪"禁用与提示文案。
- `sidecar/src/tools.cpp`：`read_file` 的续读提示（把 `offset=…` 写成可照抄的参数）。
- `sidecar/src/web_fetch.cpp`：体积被拒时的专门错误分支。

**测试**：`sidecar/test/deepseek_search_test.cpp`（消息体无 `max_tokens`、`stop_reason` 截断、体积越界）、`sidecar/test/` 里 `read_file` 的续读提示用例、`test/integration/`（用假 sidecar 的 `lastMessagesJson` 断言模型看到的那段文本）、`test/widget/` 或 `test/integration/`（启动未就绪时发送被挡）、`integration_test/` 一条真机用例（启动后立刻发送）。

**文档**：`Docs/user-guide/tools-web.md`（截断时会看到什么、怎么取回全文）、`Docs/user-guide/tools-file.md`（文件太长怎么继续读）。

**不改变**：`web_search` / `web_fetch` 对模型暴露的参数与返回结构；已配好的搜索后端与凭据闸门规则。
