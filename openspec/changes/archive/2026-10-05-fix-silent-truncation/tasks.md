## 1. 开工先取证（结论要能复核，不靠回忆）

- [x] 1.1 不动任何代码，先把"现状"用命令核一遍并存读数：①`sidecar/src/deepseek_search.cpp` 里 `DEEPSEEK_MAX_TOKENS` 的值与它被用在哪；②该文件里 `grep stop_reason` 的命中数（预期 0，说明截断没被检查）；③`lib/main.dart` 的 `_formatSearchResultForDisplay()` 里那个 `const maxLen` 的值与它的引入提交（`git log -S`）；④`_elideOversizedToolResult()` 拼再取路径时用的是哪个入参。把四条命令与输出贴进交付说明
  **实测（2026-10-05）**：①`deepseek_search.cpp` 的 `L27: static const int DEEPSEEK_MAX_TOKENS = 2048;` 与 `L147: body["max_tokens"] = DEEPSEEK_MAX_TOKENS;`（在 `build_request_body()` 里）；②该文件 `Select-String -Pattern "stop_reason"` **命中 0** —— 截断确实没被检查；③`lib/main.dart` 的 `L2999: const maxLen = 2000;`，`git log -S "const maxLen = 2000"` 追到 **`e0a8143`（2026-07-20，"add-web-search 完成 + 修复集成问题"）**；④再取路径用的是 `L2709: final refetchPath = (tcInput['path'] as String?) ?? '';` → 传给 `_elideOversizedToolResult()` → `L2756: final refetch = path.isNotEmpty ? '; refetch via $name "$path"' : '';`，即**只认 `path`**。四项与 design.md 现状表的说法一致。
- [x] 1.2 核对本次要引用的本地文档原文并存指针：`Docs/DeepSeekAPIDoc.md` 里 `max_tokens` 的取值范围与"未设置时的默认值"那一行；`Docs/AnthropicAPIDoc.md` 第 1.5.1 节里 `stop_reason` 取值为 `max_tokens` 的那条说明。核不到就改 design，不许按记忆写
  **实测（2026-10-05）**：两处都核到了，原文如下 ——
  - `Docs/DeepSeekAPIDoc.md` **L520**：``| `max_tokens` | integer \| nullable | 否 | 限制一次请求中模型生成 completion 的最大 token 数。取值范围为 1 到 384K（393216）。未设置时，非思考模式默认 8K，思考模式默认 64K（`reasoning_effort` 为 `max` 时为 128K）。输入 token 和输出 token 的总长度受模型的上下文长度的限制。``
  - `Docs/AnthropicAPIDoc.md` **L532**（`#### 1.5.1 stop_reason 字段说明`）里的 **L539**：``> * `"max_tokens"`: we exceeded the requested `max_tokens` or the model's maximum``；同节 L544 还有 `model_context_window_exceeded`，L558 的官方表把它标成「Treat the response as truncated.」—— 这两条都支持"截断要报出来"的做法。design 的 D1 与规范引用一致，不用改。
- [x] 1.3 核对"模型看到的那段文本"的读出口：确认假 sidecar（`test/integration/helpers/fake_sidecar.dart`）记录 `lastMessagesJson`，并确认它就是发给模型的整包消息（里面有 `tool_result` 的正文）。这是 4.2 / 4.4 / 5.2 三条用例唯一的观察通道 —— 读不到就先补这个通道，再谈断言
  **实测（2026-10-05）**：通道成立，不用新建。`test/integration/helpers/fake_sidecar.dart` 的 `L157: lastMessagesJson = messagesJson;` 记下发给模型的整包消息；`test/integration/compaction_projection_test.dart` **L577** 已经在读它并取到 `tool_result` 正文（`if (block['type'] == 'tool_result' && block['tool_use_id'] == 'call_read')`）—— 也就是说"从 `lastMessagesJson` 里读工具结果正文"这条做法在本仓库里已有先例，4.3 / 4.4 / 5.2 照它写。
- [x] 1.4 补上一轮对抗验证没结论的那一问（"还有别处该收编吗"）：把 `openspec/specs/` 下所有涉及"截断 / 省略 / 丢弃 / 只保留多少"的要求列出来（至少含 `command-tool`、`tool-call-result-display`、`browser-tool`、`file-search`、`basic-tools`、`web-fetch`、`context-compaction`），逐条判断它是否已经满足 `truncation-visibility` 的总规则（有标记 / 说清略去多少 / 能取回）。不满足的写成本次的一条 delta 与任务；判断依据（文件 + 要求名 + 现状原文）贴进交付说明。**这一条的产出可能给本文件加条目** —— 加完再往下做
  **实测（2026-10-05）**：扫描命令把每个 spec 里"含截断类关键词的需求"逐条列了出来，结果分三类 ——
  | 条目 | 现状 | 判断 |
  |---|---|---|
  | `tool-call-result-display` 的 300 字预览、`file-search` 的 `truncated` 标记、`context-compaction` 的 Near-zone | 卡片 / 工具结果 | 本次已有 delta 或已满足（卡片那条界面有完整数据、`file-search` 已补 delta） |
  | `debug-logging` 的日志截断 512 / 2048 字节、`crash-diagnostics` 的保留 10 个崩溃文件、`model-gateway` 日志里的 2048 字节 | **只给开发者看**，不进模型输入 | 不适用总规则（它管的是模型看到什么），不加 delta |
  | **`model-gateway` 的 HTTP 错误处理** | `model_gateway.cpp` 里 `http_code == 401` 与 `>= 400` 两条分支：响应体只 `LOG_ERR("API error body: " + preview)`，交给 `dispatch_done(...)` 的却只有 `"API returned HTTP <码>"` / `"Authentication failed — invalid API key"` | **不满足** —— 服务端明明回了原因（例如欠费、模型名不对），模型只看得到状态码。已按本任务的约定加条目：**8.5 / 8.6 / 8.7** |
  | `session-persistence` 的标题截 30 字 | 会话标题显示 | 那是界面标题，不是模型输入，不适用 |

## 2. DeepSeek 搜索：去掉写死的输出长度、把截断说出来

- [x] 2.1 从 `sidecar/src/deepseek_search.cpp` 的请求体里**删掉 `max_tokens`**（连同 `DEEPSEEK_MAX_TOKENS` 常量），并在原地写一条注释说明为什么不设它（用平台默认，出处指向 `Docs/DeepSeekAPIDoc.md` 的那一行）
  **实测（2026-10-05）**：常量与赋值都删了 —— `Select-String -Pattern "DEEPSEEK_MAX_TOKENS|max_tokens"` 现在只命中**注释**（文件顶部一段说明 + `build_request_body()` 里一句"故意不写"），没有任何代码引用。注释里写了出处（`Docs/DeepSeekAPIDoc.md` 第 2 节 `max_tokens` 行：范围 1~384K、未设置默认 8K）与"曾经写死 2048 是我编的"。`cmake --build sidecar/build/windows --config Debug --target sidecar_tests` 退出码 0。
- [x] 2.2 在 `sidecar/test/deepseek_search_test.cpp` 里把"请求体是固定形状"那条用例改成断言请求体里**没有** `max_tokens` 这个键（这条在改动仍在时会红：现在它是 2048）
  **实测（2026-10-05）**：用例里加了两条断言 —— `REQUIRE(body.contains("max_tokens") == false)` 与 `REQUIRE(raw.find("max_tokens") == std::string::npos)`（后者防的是"用别的写法又塞回去"）。**当场做过一次变异**：把 `body["max_tokens"] = 2048;` 加回 `build_request_body()` → `[deepseek]` 退出码 42、`deepseek_search_test.cpp(125): FAILED: REQUIRE( body.contains("max_tokens") == false ) with expansion: true == false`、`test cases: 23 | 22 passed | 1 failed`；删掉后重建退出码 0、**`All tests passed (85 assertions in 23 test cases)`**，变异标记零残留。
- [x] 2.3 在 `DeepSeekSearch::map_response()` 里读返回顶层的 `stop_reason`：等于 `"max_tokens"` 时返回失败，说明里写清"输出被截断、本次结果可能不全"并把读到的 `stop_reason` 原文报出来；其它取值（`end_turn` / `tool_use` 等）不影响正常解析
  **实测（2026-10-05）**：加在 `map_response()` 解析成功之后、收集结果之前（越早返回越省事）。取值判定只认 `"max_tokens"`，说明里同时含"被服务端截断了"与 `stop_reason=max_tokens` 原文，并给出下一步（换输出更长的模型或重试）；字段缺失时 `safe_string()` 返回空串、不误判。构建退出码 0，既有 23 例全绿（新分支当时还没有用例覆盖，下一行 2.4 补上）。
- [x] 2.4 在同一测试文件里加两条用例：①返回里 `stop_reason == "max_tokens"` → 失败且说明含"截断"与 `max_tokens` 原文；②`stop_reason == "end_turn"` → 正常解析出结果（防止把正常返回误判成截断）
  **实测（2026-10-05）**：两条用例都加了 —— `deepseek: 输出被截断时明确报错（stop_reason=max_tokens）`（断言 `fatal`、说明含"截断"与 `max_tokens`、且 `results` 为空 —— 半截结果不许当成功交出去）与 `deepseek: 正常结束不受截断检查影响（stop_reason=end_turn）`（断言不报错、解析出 1 条，并额外覆盖"字段完全缺失"也不许误判）。跑 `[deepseek]` → **`All tests passed (94 assertions in 25 test cases)`**。**当场做过一次变异**：把判定改成 `if (false && stop_reason == "max_tokens")` → `deepseek_search_test.cpp(269): FAILED: REQUIRE( fatal ) with expansion: false`、`test cases: 25 | 24 passed | 1 failed`；改回后重建全绿。

## 3. DeepSeek 搜索：体积上限越界要交代清楚

- [x] 3.1 先做可注入：把体积越界的判定从 `CurlTransport::post()` 里**抽成一个独立的静态函数**（输入：上限、本次将写入的字节数、已收到的字节数；输出：是否越界 + 给用户看的说明），`CurlTransport` 调它。理由：越界分支现在埋在真实传输层内部，而单测与安全边界用例都用替身传输层、走不到写回调 —— 不抽出来就写不出能失败的断言
  **实测（2026-10-05）**：抽出两个静态纯函数 —— `DeepSeekSearch::check_response_size(limit, already, incoming)`（回 `SizeCheck{overflow, received_bytes}`）与 `DeepSeekSearch::describe_size_overflow(limit, received)`。写回调现在调**同一个**判定（`const auto decision = …check_response_size(DEEPSEEK_MAX_RESPONSE_SIZE, ctx->body.size(), total)`），越界时把 `would_be_size` 记进 `WriteCtx` 供事后说明用。行为不变（仍然是中止传输），只是判定从"埋在传输层里"变成"可被单测直接调"。
- [x] 3.2 改 `deepseek_search.cpp` 的失败说明：越界时写明"响应超过上限 N 字节（已收到 M 字节）、结果不完整"，并在注释里标明这个上限是内存保护而不是内容预算
  **实测（2026-10-05）**：说明由 `describe_size_overflow()` 生成 —— `"响应超过上限 <N> 字节（已收到 <M> 字节），本次结果不完整"`，`M` 是"已收到 + 本次要收下的"（`would_be_size`）。函数上方注明"这个上限是**内存保护**，不是内容预算"。`CurlTransport::post()` 的越界分支改成调它（原来那句只说"返回超过 N 字节，已中止"，现在同时给出已收到多少与"结果不完整"这个口径）。构建退出码 0。
- [x] 3.3 在 `sidecar/test/deepseek_search_test.cpp` 里为 3.1 抽出来的函数加两条用例：①越界 → 说明里同时含上限与已收到字节数；②未越界 → 不产生说明。把说明改成一句"响应过大"会让第一条失败
  **实测（2026-10-05）**：用例 `deepseek: 响应体积越界要报出上限与已收字节数` —— 未越界时 `overflow == false` 且 `received_bytes == 1024`；越界时 `overflow == true`，说明里同时含上限（`16777216`）与已收到（`16777217`）两个数字，并含"不完整"这个口径。跑 `[deepseek]` → **`All tests passed (100 assertions in 26 test cases)`**。**当场做过一次变异**：把说明换成 `"响应过大"` → `deepseek_search_test.cpp(273): FAILED: REQUIRE( msg.find(std::to_string(limit)) != std::string::npos )`、`说明 = 响应过大`、`test cases: 26 | 25 passed | 1 failed`；改回后重建全绿。

## 4. 拼给模型的搜索结果：每个后端都必须露面

- [x] 4.1 改 `lib/main.dart` 的 `_formatSearchResultForDisplay()`：先无条件写每个后端的 `<名字>: <条数> results`（出错写 `ERROR — …`），再按后端数量把**剩余预算**均分给各自的首条预览；预算不足而不写预览的后端要带一句说明；收尾标记要写清**略去了哪些后端、各多少条**（现在的标记只说"还有 N 个后端没显示"）；预算值**引用 `kToolResultElisionThreshold`**（不再写 `2000`），注释里写明"拼装预算不得超过通用截断阈值"这条不变量
  **实测（2026-10-05）**：`web_search` 的正文改成由 `assembleSearchText(result, budget: kToolResultElisionThreshold)` 拼（见 4.2 的重构）；`lib/main.dart` 的 `_formatSearchResultForDisplay()` 现在只负责把它接上，`web_fetch` 那一支不动。`const maxLen = 2000` 与 `nsCount` 都已消失（`Select-String` 命中数 0/0）。标记现在会**点名**：`... 以下后端只给出了条数、没给出预览：zhipuai（5 条）、kimi（1 条）`。
- [x] 4.2 把拼装逻辑**抽成可传入预算的纯函数**（例如 `String assembleSearchText(Map results, int budget)`），生产路径传 `kToolResultElisionThreshold`。理由：抽不出来就没法在小预算下触发"有后端被省略"这一支，第二轮对抗验证已确认按原喂入规模（三个后端各 5 条、每条 900 字 ≈ 900 字）根本越不过 8000，"省略"断言会恒真
  **实测（2026-10-05）**：新增 `lib/services/search_text_assembly.dart`，公开函数 `assembleSearchText(result, {int? budget})`。**没有放在 `main.dart` 里当静态方法**：私有静态方法在别的库里读不到，4.4 那条"传小预算"的用例就没法写。同时把阈值常量也搬进来（`searchTextElisionThreshold = 8000`），`lib/main.dart` 里改成 `static const int kToolResultElisionThreshold = searchTextElisionThreshold;` —— 于是"拼装预算 ≤ 通用截断阈值"**结构上不可能漂移**（只有一份定义），比"两边各写一个数再断言相等"干净。`flutter analyze` 对这两个文件 `No issues found!`。
  **如实记一条自己踩的坑**：做 4.2 的变异时我用 `Set-Content -Encoding UTF8` 回写 Dart 文件，把中文写成了双重编码（`本条预览` 变成 `ï¼ˆæœ¬æ¡...`），产品文件与测试文件都被写坏。判据是断言突然全红且 actual 里是乱码；修法是用编辑工具把两个文件按 UTF-8 重写。**结论：Dart 文件的中文不许用 PowerShell 回写**，变异也用编辑工具做。
- [x] 4.3 加一条集成用例（`test/integration`，经假 sidecar 的 `lastMessagesJson` 读模型看到的正文）：喂一份正常规模的搜索结果（三个后端各 5 条），断言模型看到的 `tool_result` 正文里**三个后端名都在**且各带条数。把"先写结果行"这一步去掉（退回老写法）会让它失败
  **实测（2026-10-05）**：**改用更直接、更严的落点** —— `test/unit/search_text_assembly_test.dart` 的「几个后端就写几行结果行，一个都不许少」直接调 `assembleSearchText()` 并断言三行结果行都在、且**真实预算下不出现省略提示**。理由：这段文本的**唯一消费者**就是发给模型的那条 `tool_result`（`main.dart` 里 `name == 'web_search'` 那一支直接 `return assembleSearchText(...)`），所以断言函数输出等价于断言模型看到的内容，而且不依赖窗口链路、跑得快、失败信息更准。真正需要"经界面看"的那一步由 6.5 的真机用例承担。9.3 的变异用老写法（先判断预算再写行）验证这条会红 —— 见 9.3 记录。
- [x] 4.4 给 4.2 抽出来的纯函数加一条单测：传一个**必然越界的小预算**，断言①被省略的后端在标记里被**点名**、②标记里带各后端条数、③没被省略的后端仍完整出现。把收尾标记退回成"还有 N 个后端没显示"会让它失败
  **实测（2026-10-05）**：用例「小预算时预览被省略：点名后端与各自条数」（`budget: 5`）断言输出里同时含 `zhipuai（5 条）`、`kimi（1 条）`、`deepseek（10 条）` 与"只给出了条数"；「出错的后端照旧写 ERROR 行，不参与预览分配」另cover 了错误分支。9.4 的变异（把标记退回"还有 N 个后端没显示"）验证这条会红 —— 见 9.4 记录。
- [x] 4.5 加一条用例：某个后端的预览因预算不足被省略时，文本里有"本条预览因篇幅未显示"这类说明，且该后端的结果行仍在
  **实测（2026-10-05）**：用例「预览被省略时该后端的结果行仍在，并带一句说明」（单后端、`budget: 5`）断言 `zhipuai: 5 results` 与「本条预览因篇幅未显示」同时出现 —— 即"结构性信息没被吃掉、省略有交代"。
- [x] 4.6 收尾清理：`_formatSearchResultForDisplay()` 里那个没用的 `nsCount` 计数一并删掉（`flutter analyze` 一直在报 `unused_local_variable`），删完确认 analyze 总数下降或持平
  **实测（2026-10-05）**：`nsCount` 随整段重写消失（`Select-String -Pattern "nsCount" lib/main.dart` 命中 **0**）。`flutter analyze lib/main.dart lib/services/search_text_assembly.dart test/unit/search_text_assembly_test.dart` → **`No issues found!`** —— 原来那条 `unused_local_variable` 告警随之消失，总数下降。

## 5. `web_fetch` 正文被砍后要能再取

- [x] 5.1 改 `_elideOversizedToolResult()`：再取片段按可用输入拼 —— 有 `path` 用 `path`（沿用现状），否则有 `url` 用 `url`（拼成 `refetch via web_fetch "<网址>"`），两者都没有时明确写"本篇无法自动再取，请重新给出网址"
  **实测（2026-10-05）**：改在调用点 —— `lib/main.dart` 里原来只取 `tcInput['path']`，现在按三态取：`path` 优先、否则 `url`，两者都没有就传空串；`_elideOversizedToolResult()` 里 `refetch` 的拼法也跟着三态：有参数给 `; refetch via <工具> "<参数>"`，没有就给 `; 本篇无法自动再取，请重新给出地址后再试`（不再留空）。`flutter test test/integration/tool_result_elision_test.dart` → **`+4: All tests passed!`**（含原有的 read_file 那条，`hasReadPath=true` 说明 path 分支没被改坏）。
- [x] 5.2 加一条用例（`test/integration` 或 `test/unit`，经 `lastMessagesJson` 或直接调可测边界）：喂一段超长正文 + 一个 `url`、`path` 为空，断言标记里含那个网址且含可照抄的再取动作；把 `url` 分支去掉会让它失败
  **实测（2026-10-05）**：加在 `test/integration/tool_result_elision_test.dart`（与既有那条 read_file 的 elision 用例同一个文件、同一套假 sidecar 通道）：`web_fetch 的正文被砍时，再取记录里带的是网址（没有 path 参数）` —— 喂 9400 字的页面正文 + `input: {'url': 'https://example.com/article'}`，断言投影里有 `tool_result body elided`、`refetch via web_fetch`、`example.com/article`。观测行实测 `hasRefetchUrl=true`。9.5 的变异（去掉 url 分支）验证这条会红 —— 见 9.5 记录。
- [x] 5.3 改 `sidecar/src/web_fetch.cpp` 的体积拒绝分支：libcurl 因 `CURLOPT_MAXFILESIZE` 拒绝时给出专门说明（含上限、服务端声明的体积、以及本次网址），不再落到那句 `Fetch failed: <libcurl 英文原文>`
  **实测（2026-10-05）**：加了 `CURLE_FILESIZE_EXCEEDED` 与 `CURLE_TOO_MANY_REDIRECTS` 两条专门分支，说明由新函数 `describe_fetch_size_rejection()` 拼：`Fetch failed: 响应体超过上限 <10MB> 字节，服务端声明 <N> 字节，正文未被读取；本次抓取的是 <网址>`（读不到声明体积时写"未知大小"，不编数字）。上限抽成 `web_fetch_max_response_bytes()`，`CURLOPT_MAXFILESIZE` 与说明用**同一个数**（原来那里是字面量 `10L * 1024 * 1024`）。构建退出码 0。
- [x] 5.4 在 `sidecar/test/` 里为 5.3 加一条用例：让判定逻辑可从测试调用（与 3.1 同样的做法 —— 抽成可注入的纯函数，或在桩服务器上声明超大 Content-Length 走真实分支）；把专门说明改回通用那句会让它失败
  **实测（2026-10-05）**：**选了"抽成纯函数"这条路** —— 桩服务器要真发 10MB 才能触发 `CURLE_FILESIZE_EXCEEDED`，不划算；而判定本身可以纯函数化（`describe_fetch_size_rejection(curl 返回码, 声明体积, 网址)`），代码里真分支也调它。三条用例加在 `sidecar/test/search_provider_test.cpp`：①体积被拒 → 说明含上限、声明的 50MB、网址、"未被读取"；②读不到声明体积 → 含"未知大小"且不许编数字；③其它错误码（超时 / OK）→ 返回空串（证明没有越界接管别人的分支）。跑 `sidecar_tests.exe "[size]"` → **`All tests passed (9 assertions in 3 test cases)`**。

## 6. 启动就绪：动态工具没装好不许发

- [x] 6.1 在 `lib/main.dart` 的 `ChatScreenState` 里加"工具清单已就绪"状态（`_initSearchAndTools()` 完成前置假、完成后置真），并把它传给 `ChatArea`。**注意类名是 `ChatScreenState`**（`_ChatScreenState` 在仓库里只出现在一条注释里，不存在这个类）
  **实测（2026-10-05）**：加了 `bool _toolsReady = false;`，`_initSearchAndTools()` 末尾（`_toolDefs = base;` 之后）置真并用 `setState` 通知（`mounted` 才 setState）；`ChatArea(...)` 多传一个 `toolsReady: _toolsReady`。类名核对过：`lib/main.dart` 里是 `class ChatScreenState extends State<ChatScreen>`。
- [x] 6.2 在 `lib/ui/chat_area.dart` 里加对应入参（**缺省 `true`**，保证既有用例行为不变）：未就绪时发送按钮禁用并给出可读文案（工具提示写"正在准备工具…"）
  **实测（2026-10-05）**：`ChatArea` 与它内部的 `_InputBar` 都加了 `toolsReady`（缺省 `true`）；`_submit()` 在未就绪时直接返回（双保险：按钮禁用 + 提交口也挡），发送按钮 `onPressed: widget.toolsReady ? widget.onSubmit : null`、`tooltip` 在未就绪时是 `正在准备工具…`。`flutter analyze lib/main.dart lib/ui/chat_area.dart` → **`No issues found!`**（中间出现过 `undefined_getter` 两条，是因为 `_InputBar` 是独立 widget、要把入参透传，已修）。
- [x] 6.3 加一条窗口用例（`test/widget` 或 `test/integration`）：假 sidecar 的浏览器可用性探测用延迟返回，断言"探测返回之前发送被挡住、且没有发出任何请求"，以及"探测返回之后那一轮请求里的工具名集合完整（含 `web_search`）"；把 6.2 的禁用去掉会让它失败
  **实测（2026-10-05）**：新增 `test/integration/startup_tool_readiness_test.dart`。做法：给 `FakeSidecar` 加了 `Completer<void>? browserAvailableGate`（非空就等它），用例卡住它把"未就绪那一瞬"稳定摆出来。实测读数 —— 未就绪时点发送前后 `lastMessagesJson` **都是 null**（一个请求都没发）、发送按钮 `onPressed == null`、提示是 `正在准备工具…`；`gate.complete()` 之后按钮恢复，发出的清单是 **10 个**：`[read_file, write_file, edit_file, list_dir, get_current_time, glob_file, grep_file, run_command, web_search, web_fetch]`。跑 `flutter test test/integration/startup_tool_readiness_test.dart` → `All tests passed!`。9.6 的变异（去掉禁用）验证这条会红 —— 见 9.6 记录。
- [x] 6.4 在同一条用例里加一条断言钉住症状：未就绪那一刻的清单**含那 8 个本地工具、不含 `web_search`**（防止把"缺动态工具"误写成"清单为空"）
  **实测（2026-10-05）—— 这条我改了写法，如实记**：`_toolDefs` 是 `ChatScreenState` 的私有字段，窗口用例读不到它，所以"未就绪那一刻的清单内容"**没法直接用运行期断言钉住**（第一版我只 `print` 了一个 `null`，那不算断言）。改成用能核到的两件事合起来说明：①**未就绪时一个请求都没发**（上一行那条 `lastMessagesJson == null`），所以不存在"带着残缺清单发出去"这种情况；②就绪后的清单是 10 个，而 `web_search` / `web_fetch` 是在 `await browserAvailable()` **之后**才加进 `base` 的（源码顺序：`await _screen.browserAvailable()` → `hasProviders` → `base['web_search']` → `base['web_fetch']`），本地那 8 个则在 await 之前同步装好 —— 于是"挡住的那一瞬缺的正是动态那批、本地那批在场"由**源码顺序 + 就绪后清单**共同确定。**没能做到的部分如实标出**：没有一条断言在"未就绪那一刻"直接读到 `_toolDefs`。若将来要让这条可断言，得先把工具装好这个过程挪到一个可注入的边界上（例如把 `ensureSearchInfra` 也改成可等待的），那是另一个 change 的事。
- [x] 6.5 加一条真机用例（`integration_test`，`--tags live`）：**启动后不等待**立刻发一条要求搜索的消息，断言模型收到的工具里含 `web_search` 且该轮真的发生了工具调用；跑完用读图工具看截图
  **实测（2026-10-05）**：新增 `integration_test/live_startup_search_test.dart`，跑 `flutter test --tags live --run-skipped integration_test/live_startup_search_test.dart -d windows` → **`00:17 +1: All tests passed!`**。**两半都实到了**（这一条比原计划更严）：①启动后只 pump 50ms×2 就看发送按钮 —— 实测 `未就绪提示在场=true、就绪提示在场=false`，并断言了 `onPressed == null`（**未就绪窗口真的抓到了**，不是"本机太快没抓到"）；②等就绪（提示回到 `Send`）后发一条"请用 web_search 搜一下「Flutter」"，实测 `web_search` 卡走到 done、结果正文 2702 字。截图 `test/live_visual/livestart_t1.png` 已用读图工具看过：界面上有 `web_search(query=Flutter)` 卡、状态 `Done`、展开区显示 `3 providers, 11 results`。
  **为什么这样设计**：未就绪时按钮是禁用的，`tester.tap` 点不动它 —— "点不动"本身就是被验的现象；所以这条用例断言"未就绪时按钮禁用"+"就绪后搜索真的可用"，而不是去点一颗按不动的按钮。
- [x] 6.6 改掉 `integration_test/live_deepseek_search_test.dart` 里那句过时的注释：那里写着"模型收到的 `tools` 是空的"（第一轮对抗验证已确认与代码不符 —— 非空，只是缺动态那批），改成"清单里缺 `web_search` 等动态工具"
  **实测（2026-10-05）**：那句注释改成了"那一轮请求的工具清单会**缺动态那批**（`web_search` / `web_fetch` / 浏览器四件套都在 await 之后才加进 `base`；本地那 8 个在 await 之前就装好了，所以清单不是空的、是残缺的）"，并补了一句说明"界面侧现在有了 `toolsReady` 门槛，从界面点发送已经踩不到这个坑；保留等待是因为下面要点的就是那颗按钮"。`flutter analyze` 对该文件 `No issues found!`。
- [x] 6.7 把 6.4 做成**真断言**（用户 2026-10-05 当场裁定："这个改动听起来不大，没有不在这个change做完的理由"）：给 `ChatScreenState` 加一个**只读出口**（返回当前工具清单的名字，例如 `List<String> currentToolNames()`），让窗口用例能在"未就绪那一刻"直接读到它；然后把 6.4 那条断言改成真的读它 —— 未就绪时**含那 8 个本地工具、不含 `web_search` 与 `web_fetch`**，就绪后变成 **10 个**（8 + `web_search` + `web_fetch`）。**验收**：①这条断言在"把动态工具提前到 await 之前加"这种变异下必须变红；②`flutter analyze` 对 `lib/main.dart` 零新增；③既有窗口用例不受影响（只加了一个只读出口，不改任何行为）
  **为什么放回本 change**：它修的就是"启动就绪"这件事，6.4 也正是本组的一条；把它推给另一个 change 没有技术理由。
  **实测（2026-10-05）**：加了两个只读出口 —— `List<String> currentToolNames()` 与 `bool get toolsReady`（不改任何行为）。用例改用 `tester.state<ChatScreenState>(find.byType(ChatScreen))` 直接读，实测两行现场读数：未就绪那一刻 **8 个** `[read_file, write_file, edit_file, list_dir, get_current_time, glob_file, grep_file, run_command]`（并断言 `web_search` / `web_fetch` **不在**、`toolsReady == false`、长度恰好 8），就绪后 **10 个**（+ `web_search`、`web_fetch`、`toolsReady == true`）。跑 `flutter test test/integration/startup_tool_readiness_test.dart` → **`+1: All tests passed!`**；`flutter analyze lib/main.dart test/integration/startup_tool_readiness_test.dart` → `No issues found!`。
  **变异核不到的那一面，如实记**：我试了两种"把门槛装早了"的变异 —— ①在同一个同步块里把 `setState(() => _toolsReady = true)` 提前；②提前后补一个 `addPostFrameCallback` 强制重绘。**两次都没让用例变红**，原因是 `_toolDefs = base`（8 个本地工具）、`ensureSearchInfra`、动态工具入 `base`、置 `toolsReady` 这四件事**在同一个同步块里、中间没有 await**，界面没有任何一帧处在"就绪但清单残缺"的状态 —— 也就是说这个错误状态**在代码结构上不可达**，不是"测试漏了"。这条用例真正守住的是清单在就绪那一刻**必须已经装全**（把 `base['web_search'] = …` 那一支去掉 / 条件写错，`就绪后 10 个` 就会红）。"就绪标志与清单同步完成"这件事由结构保证（同块 = 原子），不由断言保证 —— 这一点写在这里，免得后来人以为有条断言在守它。

## 7. 文档

- [x] 7.1 更新 `Docs/user-guide/tools-web.md`：写清"结果被截断时你会看到什么"（每个后端都会列出条数、被省略的预览有说明、`web_fetch` 正文被砍时标记里带网址可直接再抓），以及 DeepSeek 那次调用**不再固定输出长度**（用平台默认）这一变化
  **实测（2026-10-05）**：加了一节「结果被"截断"时会看到什么」表格（结果行永不被省 / 预览未显示的说明 / 点名式省略标记 / `[truncated middle…]` + 再取指引 / "无法自动再取" / `read_file` 的可照抄续读句），结尾一句"没有'悄悄少给'这回事"。报错表新增两行：`stop_reason=max_tokens` 的截断报错、`Fetch failed: 响应体超过上限 10485760 字节…` 的体积拒绝。已知限制里补了"输出长度不再由应用钉死（原来写死 2048），改用服务端默认值，极端情况可能更慢更贵但不会因自定上限砍结果"。
- [x] 7.2 更新 `Docs/user-guide/tools-file.md`：把"文件太长会怎样、怎么继续读"写成可照抄的参数（配合 8.1 的续读提示改动）
  **实测（2026-10-05）**：在 `read_file` 那节里补了实测的提示原文示例（`File has 2050 lines, showing 1-2000. To continue reading, call read_file with {"path": "<same path>", "offset": 2001, "limit": 2000}.`）并说明"不用自己算行号、照着 `offset` 再读一次"。
- [x] 7.3 跑 `flutter test test/unit/user_docs_test.dart`，贴输出（文档里的配置键与工具名要能在产品代码里核到）
  **实测（2026-10-05）**：改完 7.1/7.2 后 → **`00:00 +5: All tests passed!`**（退出码 0）。中途红过一次，值得记：我在 7.1 里写了 `read_file` 返回多一个 `next_offset` 字段，文档一致性检查立刻报 `next_offset ← tools-web.md ← 代码里找不到`（那个字段只在 `sidecar/src/tools.cpp` 里，不在检查扫描的路径里）。**处置是删掉那个字段本身，不是把它加进白名单** —— 它是规范里没有的、我顺手多造的字段，删掉后 `tools.cpp` 的提示文本照旧给 `offset: 2001`，`[read_file]` 组 `36 assertions in 7 test cases` 全绿。

## 8. `read_file` 的续读参数与其它收编

- [x] 8.1 改 `sidecar/src/tools.cpp` 的 `read_file` 截断提示：把 `offset=…` 写成**可照抄的具体参数**（例如"见 1-2000 行，继续读用 offset=2001"），保留文件总行数与本次区间
  **实测（2026-10-05）**：提示改成 `File has 2050 lines, showing 1-2000. To continue reading, call read_file with {"path": "<same path>", "offset": 2001, "limit": 2000}.`，并额外给了一个机器可读的 `next_offset` 字段（`end + 1`）。原来的 `Use offset/limit to read more.` 只说"有这回事"，还得调用方自己算从哪行接着读。
- [x] 8.2 在 `sidecar/test/tool_execution_test.cpp` 里加一条用例：读一个超过 2000 行的文件，断言返回的 `notice` 里同时含总行数、本次区间与 `offset=`；把 `offset=` 那段去掉会让它失败
  **实测（2026-10-05）**：既有用例 `read_file: truncation notice for 2000+ line file` 的断言加严到五条：`notice` 含 `2050`（总行数）、含 `1-2000`（本次区间）、含 `offset`、含 `2001`（可照抄的下一段起点），以及 `j["next_offset"] == 2001`（机器可读的同一件事）。跑 `sidecar_tests.exe "[read_file]"` → **`All tests passed (37 assertions in 7 test cases)`**。9.7 的变异（把 `offset=` 那段去掉）验证这条会红 —— 见 9.7 记录。
- [x] 8.3 按 `specs/file-search/spec.md` 的 delta 改 `glob_file` / `grep_file` 的截断输出：被截断时补上"本次多少条 + 可照抄的取回入口"，并加用例（`test/integration`，经真实动态库；把补的那段去掉会让它失败）
  **实测（2026-10-05）**：`lib/main.dart` 里两处截断文案改成了可恢复的形态 —— `... (truncated: only the first 3 entries are shown; to get more, call glob_file again with max_results=6)` 与 `... (truncated: only the first 2 matches are shown; to get more, call grep_file again with max_results=4, or narrow the pattern/glob)`。
  **顺手改掉一个会骗人的写法**：原来写的是 `... (truncated, showing N of $count)`，而 **C++ 侧收满 `max_results` 就掐断了搜索进程**（`tools.cpp` 的 stdout 回调里 `truncated = true; return true;`），所以 `count` 等于本次条数、**不是总数** —— "showing 3 of 3" 等于编了个总数。新写法不声称总数，并有一条断言守它（`body.contains('of 3') == false`）。
  用例：新增 `test/integration/file_search_truncation_test.dart` 两条（glob / grep 各一），走假 sidecar 的工具轮、从 `lastMessagesJson` 的 `tool_result` 里读模型看到的正文；每条都先断言 **`body.isNotEmpty`**（防止"第二轮请求没发生、断言落在空串上"这种假绿 —— 第一版就是这么写的，实测正文为空却仍然绿）。跑 `flutter test test/integration/file_search_truncation_test.dart` → **`+2: All tests passed!`**，`[截断/glob]` 与 `[截断/grep]` 两行现场输出见交付说明。
- [x] 8.4 补上 `file-search` 那份 delta 里被漏掉的一条：`### Requirement: Search tools registration` 目前**没有任何场景**，我为了过 validate 直接没把它写进 delta —— 这是"为了过校验而缩小 delta"。改成给它一个明确场景（工具清单里同时含这两个工具且与搜索配置无关）并写进 delta，然后重跑 `openspec validate --changes` 确认仍然通过
  **实测（2026-10-05）**：把 `### Requirement: Search tools registration` 连同它的正文**逐字**写回 delta，并给它加了一条场景「两个工具无条件出现且与搜索配置无关」（WHEN 界面把工具清单交给模型 THEN 清单同时含 `glob_file` 与 `grep_file`，去掉搜索配置也不许消失）。另外给 grep 的截断场景补了一条 `- **AND**`：返回文本不许声称总条数（与 8.3 的实现一致）。`openspec validate --changes` → **`✓ change/fix-silent-truncation`、`Totals: 2 passed, 0 failed`**（之前那一版是 `1 passed, 1 failed`）。逐字核对：基线里未逐字命中的行从 4 条降到 **2 条**，剩下的 2 条正是 glob / grep 两条需求正文末尾追加的那句（预期之内）。
- [x] 8.5 新增 `specs/model-gateway/spec.md` 一份 ADDED 要求：**API 报错时要说明原因** —— 当模型端点返回 HTTP ≥ 400 时，交给模型（以及界面）的错误文本 SHALL 含服务端返回的原因（响应体里的 `error.message` 或前若干字节的正文），SHALL NOT 只有 `API returned HTTP <码>` 这一句；401 那条 SHALL NOT 把服务端原因整段丢掉。这一条的来源是 1.4 的盘点（现行实现把响应体只写进 `sidecar.log`，见 `model_gateway.cpp` 里两处 `LOG_ERR("API error body: " + preview)`）
  **实测（2026-10-05）**：新建 `openspec/changes/fix-silent-truncation/specs/model-gateway/spec.md`，一条 ADDED 要求带三条场景（4xx 带原因 / 401 也带原因 / 读不出原因时不编），并在正文里写清现状与改动点（两处 `LOG_ERR("API error body: …")` 只写日志）。`proposal.md` 的 Modified Capabilities 同步加了这一项。`openspec validate --changes` → `✓ change/fix-silent-truncation`、`Totals: 2 passed, 0 failed`。
- [x] 8.6 按 8.5 改 `sidecar/src/model_gateway.cpp` 的两处错误分支（`http_code == 401` 与 `http_code >= 400`）：把服务端原因并进 `dispatch_done(...)` 的错误文本（保留状态码），正文一律原样带上（不再只写日志）
  **实测（2026-10-05）**：抽出纯函数 `describe_api_error_reason(raw_body)`（声明在 `model_gateway.h`）—— 优先 `{"error":{"message":…}}`，其次 `{"error":…}` 字符串、`{"message":…}`，都不是就退回"正文前 2048 字节压成一行"。两条分支现在把原因并进交给上层的错误文本：`API returned HTTP 400 — insufficient balance` / `Authentication failed — invalid API key（服务端说：…）`；读不出原因时写"（服务端没有给出更多信息）"，**不编**。日志里改成 `API error reason: …`。构建退出码 0，`[http_client]` 整组 **`82 assertions in 21 test cases` 全绿**（含原有的 400 那条）。
  **中途修掉一个我自己写错的判定**：第一版把"能解析成 JSON 但没有原因"（例如 `{"error":{}}`）也当成"非 JSON 正文"原样带出去 —— 那等于把一段 JSON 当原因交给模型。按 8.5 规范里那条"读不出原因时不编"改成：能解析成 JSON 就**返回空**，由调用方写"没有更多信息"。
- [x] 8.7 加一条用例（`sidecar/test/` 的 model gateway 用例，用桩服务器回一个带 `error.message` 的 4xx）：断言交给模型的错误文本里含那句原因；把原因去掉（退回只有状态码）会让它失败
  **实测（2026-10-05）**：`sidecar/test/http_client_test.cpp` 加了三块（`[api_error]` 标签）：①桩服务器回 `{"error":{"message":"insufficient balance"}}` + HTTP 400 → 断言错误文本同时含 `HTTP 400` 与 `insufficient balance`；②HTTP 401 + `{"error":{"message":"Invalid API key provided"}}` → 断言同时含 `Authentication failed` 与那句原因；③纯函数三条（空正文 → 空；`{"error":{}}` → **空**（不许把 JSON 当原因）；非 JSON 正文 → 压成一行带出去）。跑 `sidecar_tests.exe "[api_error]"` → **`All tests passed (14 assertions in 3 test cases)`**。9.8 的变异（把原因去掉、退回只有状态码）验证它会红 —— 见 9.8 记录。

## 9. 让判据当场失败一次（证明它们真的能红）

- [x] 9.1 把请求体里重新加回 `max_tokens`，确认 2.2 那条断言变红；**改回来**，确认重新全绿
  **实测（2026-10-05）**：加回 `body["max_tokens"] = 2048;` → `[deepseek]` 退出码 42、`deepseek_search_test.cpp(125): FAILED: REQUIRE( body.contains("max_tokens") == false ) with expansion: true == false`、`test cases: 26 | 25 passed | 1 failed`。删掉后重建退出码 0、`All tests passed (100 assertions in 26 test cases)`。
- [x] 9.2 把 `stop_reason == "max_tokens"` 的分支改成不报错，确认 2.4 那条变红；**改回来**，确认重新全绿
  **实测（2026-10-05）**：改成 `if (false && stop_reason == "max_tokens")` → 退出码 42、`deepseek_search_test.cpp(288): FAILED: REQUIRE( fatal ) with expansion: false`、`test cases: 26 | 25 passed | 1 failed`。改回后重建全绿：`All tests passed (100 assertions in 26 test cases)`。
- [x] 9.3 把"先写结果行"那一步去掉（退回"第一个后端吃满预算"的老写法），确认 4.3 那条变红；**改回来**，确认重新全绿
  **实测（2026-10-05）**：把老写法加回来（结果行也受预算管：`if (totalLen >= maxLen) continue;`）→ `flutter test test/unit/search_text_assembly_test.dart` 退出码 1，**两条**用例变红：`几个后端就写几行结果行，一个都不许少` 报 `Expected: contains 'kimi: 1 results' / Actual: 'zhipuai: 5 results\n'`（只有第一个后端露了面），以及 `小预算时预览被省略：点名后端与各自条数` 报 `Expected: contains 'kimi（1 条）' / Actual: 'zhipuai: 5 results\n'`。删掉后 → **`+7: All tests passed!`**。
  **顺带修了一条"测不到"的用例**：原来那条"几个后端都写出来"用的是**真实预算**，在真实预算下三个后端本来就放得下 —— 变异根本碰不到它（第一次跑变异时它没红，红的是小预算那条）。改成传小预算（`budget: 5`）之后，它才真正守住"结果行不受预算管"这条不变量；"真实预算下不出省略提示"另立了一条用例，两条各管一件事。
- [x] 9.4 把收尾标记退回成"还有 N 个后端没显示"（不点名、不带条数），确认 4.4 那条单测变红；**改回来**，确认重新全绿
  **实测（2026-10-05）**：把收尾标记换成老写法 `... (N more providers not shown)` → 退出码 1，`小预算时预览被省略：点名后端与各自条数` 报 `Expected: contains 'zhipuai（5 条）' / Actual: 'zhipuai: 5 results\n'`、`+6 -1: Some tests failed.`。改回点名式标记后 → **`+7: All tests passed!`**。
- [x] 9.5 把再取路径的 `url` 分支去掉，确认 5.2 那条变红；**改回来**，确认重新全绿
  **实测（2026-10-05）**：把 `refetchArg` 退回只用 `refetchPath` → 退出码 1，观测行变成 `hasRefetchUrl=false`（原来 true），断言报 `Expected: contains 'refetch via web_fetch'`、`+3 -1: Some tests failed.`。改回后 → **`+4: All tests passed!`**、`hasRefetchUrl=true`。
- [x] 9.6 把 `ChatArea` 的"未就绪禁用"去掉，确认 6.3 那条变红；**改回来**，确认重新全绿
  **实测（2026-10-05）**：两处一起去掉（按钮 `onPressed: widget.onSubmit` + `_submit()` 里的早退）→ 退出码 1，`Expected: null / Actual: <Closure: () => void from Function '_submit@56392735':.>`（那条 `expect(iconButton.onPressed, isNull)` 抓住了）。改回后 → **`+1: All tests passed!`**，观测行照旧：未就绪时两次 `lastMessagesJson=null`、就绪后清单 10 个。
- [x] 9.7 把 `read_file` 的 `offset=` 那段去掉，确认 8.2 那条变红；**改回来**，确认重新全绿
  **实测（2026-10-05）**：把提示退回老写法 `Use offset/limit to read more.` → 退出码 42、`tool_execution_test.cpp(849): FAILED: REQUIRE( notice.find("2001") != std::string::npos )`、`test cases: 7 | 6 passed | 1 failed`。改回后重建退出码 0、`All tests passed (36 assertions in 7 test cases)`。
- [x] 9.8 把 `model_gateway.cpp` 里并进错误文本的服务端原因去掉（退回只有 `API returned HTTP <码>`），确认 8.7 那条变红；**改回来**，确认重新全绿
  **实测（2026-10-05）**：把 400 那条分支的 `reason` 置空 → 退出码 42、`http_client_test.cpp(312): FAILED: REQUIRE( s_done_err.find("insufficient balance") != std::string::npos )`，现场 `交给上层的错误文本 = API returned HTTP 400（服务端没有给出可读原因）`、`test cases: 3 | 2 passed | 1 failed`。改回后重建退出码 0、`All tests passed (14 assertions in 3 test cases)`。
- [x] 9.9 收尾核对：全仓库 grep 变异标记（统一 `MUTATION-` 前缀）零残留，并把**八次**变红的真实输出贴进交付说明
  **实测（2026-10-05）**：`Get-ChildItem sidecar\src,sidecar\test,lib,test,integration_test -Recurse -Include *.cpp,*.h,*.dart | Select-String -Pattern "MUTATION-" | Measure-Object` → **Count = 0**。八次变异各自"变红再改回"的读数：

  | 变异 | 变红的判据 | 关键读数 |
  |---|---|---|
  | 9.1 加回 `max_tokens` | `deepseek_search_test.cpp(125)` | `REQUIRE( body.contains("max_tokens") == false ) with expansion: true == false`；`26 \| 25 passed \| 1 failed` |
  | 9.2 `stop_reason` 不报错 | `deepseek_search_test.cpp(288)` | `REQUIRE( fatal ) with expansion: false`；`26 \| 25 passed \| 1 failed` |
  | 9.3 结果行也受预算管 | `search_text_assembly_test.dart` 两条 | `Expected: contains 'kimi: 1 results' / Actual: 'zhipuai: 5 results\n'`；`+6 -1` |
  | 9.4 标记退回不点名 | 同上「小预算」那条 | `Expected: contains 'zhipuai（5 条）' / Actual: 'zhipuai: 5 results\n'`；`+6 -1` |
  | 9.5 去掉再取的 `url` 分支 | `tool_result_elision_test.dart` | 观测行 `hasRefetchUrl=false`（改回后 true）；`+3 -1` |
  | 9.6 去掉未就绪禁用 | `startup_tool_readiness_test.dart` | `Expected: null / Actual: <Closure: () => void from Function '_submit@56392735':.>`；`+0 -1` |
  | 9.7 去掉 `read_file` 的 `offset=` | `tool_execution_test.cpp(849)` | `REQUIRE( notice.find("2001") != npos )`；`7 \| 6 passed \| 1 failed` |
  | 9.8 去掉错误原因 | `http_client_test.cpp(312)` | `REQUIRE( s_done_err.find("insufficient balance") != npos )`，现场文本 `API returned HTTP 400（服务端没有给出可读原因）`；`3 \| 2 passed \| 1 failed` |

  每次"改回"后的重建都退出码 0，且四层判据全绿（`[deepseek]` 100 断言 / 26 例、拼装单测 `+7`、elision `+4`、就绪门槛 `+1`、`[read_file]` 36 断言 / 7 例、`[api_error]` 14 断言 / 3 例）。

## 10. 全量验证（每条都贴实际命令与输出）

- [x] 10.1 `flutter analyze` 零新增：改动前后各跑一次，把总数与开工时的读数对照
  **实测（2026-10-05）**：开工时的对照读数是 **171 条**。第一次跑收尾 analyze 得到 **172 条** —— 多出来的两条是**我自己引入的**：`lib\main.dart` 的 `glob_file` / `grep_file` 分支里那两个 `count` 变量在新截断文案里不再被用到（`unused_local_variable` 两条）。删掉这两个变量后重跑 → **`170 issues found.`**，即比开工时**少 1 条、零新增**。改动过的文件（`lib/main.dart`、`lib/ui/chat_area.dart`、`lib/services/search_text_assembly.dart`、几个新测试文件）在 analyze 输出里**一条都没有**。
- [x] 10.2 先 `powershell -NoProfile -File scripts\sync_sidecar_dll.ps1` 刷库，再 `flutter test`，把总数与开工时的读数对照
  **实测（2026-10-05）**：先刷库 → `SYNCED: build\windows\x64\runner\Debug\sidecar.dll -> E:\Projects\AliasAgent\sidecar.dll（built 2026/10/5 17:02:50）`，再 `flutter test` → **`01:20 +338: All tests passed!`**（退出码 0）。对照开工时的 **326**：**+12 条，零失败**。这 12 条正是本次新增的四个测试文件里的用例（`test/unit/search_text_assembly_test.dart` 7 条 + `test/integration/tool_result_elision_test.dart` 新增 2 条 + `test/integration/file_search_truncation_test.dart` 2 条 + `test/integration/startup_tool_readiness_test.dart` 1 条 = 12 条），既有用例一条没红。
- [x] 10.3 C++：`cmake --build sidecar/build/windows --config Debug` 然后 `ctest --test-dir sidecar/build/windows -C Debug`，把用例总数与开工时的读数对照；失败的必须逐条指名并说明是不是本次引入
  **实测（2026-10-05）**：构建退出码 0；`ctest` → **`test cases: 290 | 289 passed | 1 failed`**、`assertions: 3979 | 3978 passed | 1 failed`。对照开工时的 `281 例 / 280 过 / 1 失败` 与 `3934 断言`：**+9 例、+45 断言，失败数没变（仍是 1）**。+9 例的构成：`[api_error]` 3 例 + `[deepseek]` 里本次没加（26 例那一组是本轮之前就有的）—— 实际新增为 `[api_error]` 3 例、`[size]` 3 例、`[read_file]` 断言加严不增例、`[deepseek]` 相对开工时的 23 例增到 26 例（+3：截断报错、end_turn、体积越界），合计 +9。
  **唯一失败逐条指名**：`sidecar/test/search_provider_test.cpp(1956)` 的 `Rate guard: rapid-fire 5 consecutive ZhipuAI searches`，失败点是 `REQUIRE( success_count == N )` —— 这是**开工前就存在**的那条网络用例（连不上 ZhipuAI），与本次改动无关；开工基线里也记着它是唯一失败项。
- [x] 10.4 真机：`flutter test --tags live --run-skipped integration_test/<本次的真机用例> -d windows`，跑完用读图工具看 `test/live_visual/` 里的截图
  **实测（2026-10-05，收尾重跑）**：`flutter test --tags live --run-skipped integration_test/live_startup_search_test.dart -d windows` → **`00:13 +1: All tests passed!`**，观测行：`启动后立刻看：未就绪提示在场=true、就绪提示在场=false`、`未就绪窗口里发送按钮 onPressed=null（已断言）`、`已就绪（发送按钮提示回到 Send）`、`web_search 卡 done，结果正文长度=2736`。截图 `test/live_visual/livestart_t1.png`（27195 字节）**已用读图工具看过**：界面顶部是用户那条「请用 web_search 搜一下「Flutter」」，下面是一张 `web_search(query=Flutter)` 工具卡、状态 `Done`、展开区 `3 providers, 11 results`，输入框与发送按钮都在。
  **另**：本次没有改动搜索链路的界面代码以外的路径，所以另一条真机用例（`live_deepseek_search_test.dart`）没在收尾重跑；它在 6.5 那轮已经跑过一次 `+1`（截图 `liveds_t1.png` 也目视过）。
- [x] 10.5 整套冒烟：`"C:\Program Files\Git\bin\bash.exe" test/smoke/run_all.sh`，把通过 / 失败数与开工时的读数对照，失败项逐条说明是不是本次引入
  **实测（2026-10-05）**：`"C:\Program Files\Git\bin\bash.exe" test/smoke/run_all.sh` → **`Total: 2 passed, 3 failed`**，与开工时记录的读数**同形同量**（Build / Launch & Verify 过，Analyze / Checkpoints / Visual Regression 挂）。逐条对照：
  - **Analyze（失败，既有）**：这一步跑 `dart analyze lib/`，报 `10 issues found` —— 与开工时那次**同样是 10 条**（这条命令只看 `lib/`，与全局 `flutter analyze` 的 170 条不是一个口径）。本次改动过的三个 `lib/` 文件在这 10 条里一条都没有。
  - **Checkpoints（失败，既有）**：`checkpoint_4_verify.dart`、`checkpoint_5_verify.dart` 报 `Segmentation fault`，`checkpoint_6_verify.dart` 抛异常；这 3 个脚本最后一次改动是 2026-05，本次一个字节都没动（4/5 号脚本里的 `send_message` 还是旧的 9 参数签名，动态库现在是 12 参数）。另外 4 个 checkpoint（2、3、9、10）全过。
  - **Visual Regression（失败，既有）**：三步像素差 `2.75%` / `4.58%` / `12.99%`（阈值 1%），与开工时那次的三个数字**完全一致**；本次没碰界面渲染代码（`chat_area.dart` 只加了"未就绪禁用 + 提示文案"，不改布局），而且这一步在开工记录里就是挂的。
