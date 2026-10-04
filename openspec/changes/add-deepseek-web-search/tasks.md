## 1. 开工先取证（结论要能复核，不靠回忆）

- [ ] 1.1 开工第一件事：不改任何代码，先跑一次 C++ 全量单测并存下读数 —— `cmake --build sidecar/build/windows --config Debug` 然后 `ctest --test-dir sidecar/build/windows -C Debug`，把用例总数与通过数贴进交付说明；这就是后面比对的对照（本机上一次的读数是 **237 例 / 236 过 / 1 失败**，失败项是既有的网络用例，但要以你这次实跑为准）
- [ ] 1.2 把参考实现的两处依据抄进 design 的引用里并逐条核对（文件：`C:\Users\76956\AppData\Roaming\npm\node_modules\@deepseek-ai\dsh\node_modules\@deepseek-ai\dsh-web-search-deepseek\lib\index.js`）：①请求体形状（`search()` 方法里的 `messages` 与 `tools`）；②返回映射（`mapAnthropicResponse()` 只挑 `web_search_tool_result`、`citationSnippets()` 只读 `text` 块的 `citations`）。核对不到就改 design，不许按记忆写
- [ ] 1.3 用你配置里那把 DeepSeek 密钥手动发一次最小请求（就是探索阶段那次探针，命令与读数已记在 design 的实测表里），确认：`HTTP 200`、返回里有 `web_search_tool_result` 块、结果条目带 `url` 与 `title`。**这次实测的读数要贴进交付说明**；如果这次发不出来（网络、额度），停下来如实报告，不许跳过
- [ ] 1.4 核对本地文档的对应章节并写进 design 的依据里：`Docs/DeepSeekAPIDoc.md` 里 `server_tool_use` 与 `web_search_tool_result` 标为支持的那张表（连同行号与原文），以及它另外提到的"chat-completions 那套接口的 `tools[].type` 仅支持 function"这一条（用来说明本变更用的是另一个端点，不是自相矛盾）

## 2. 后端本体（C++）

- [ ] 2.1 新增 `sidecar/src/deepseek_search.cpp` 与 `deepseek_search.h`，实现 `ISearchProvider`：名字 `deepseek`、一句人能看懂的说明、`is_configured()`、`search(查询, 深度, 条数上限)`。凭据按规范里的顺序解析，`model` 可配、缺省 `deepseek-v4-flash`，`max_uses` 固定 1
- [ ] 2.2 用 `libcurl` 实现那次 POST（照 `zhipuai_search.cpp` 的写法：`curl_easy_init` + 一次请求 + 自己解析整包 JSON，不流式），带 `x-api-key` 与 `anthropic-version: 2023-06-01`，并设超时
- [ ] 2.3 实现返回映射：只从 `web_search_tool_result` 块取结果（`url` / `title` / `page_age`），按网址去重；`text` 块的 `citations[].cited_text` 按网址对应成正文；没有引用时**用标题兜底**并在代码注释里写明这是"没有摘要"；`page_age` 为空当正常
- [ ] 2.4 实现失败路径：拿不到密钥 → 报告不可用；网络/HTTP/超时失败 → 可读说明 + **本次实际使用的地址**；`HTTP 200` 但没有结果块 → 明确报错"这次调用没有触发服务端搜索"（不许回退成把 `text` 当结果、也不许当 0 条）
- [ ] 2.5 处理坏字节：标题里的非法 UTF-8 SHALL 不导致解析失败（替换成替换字符即可，仓库里已有同类做法可参考）
- [ ] 2.6 把 `src/deepseek_search.cpp` 加进 `sidecar/CMakeLists.txt` 的**两份源码列表**（`sidecar.dll` 目标与 `sidecar_tests` 目标），构建一次确认两份都真的编到了

## 3. 注册与接线

- [ ] 3.1 在 `sidecar/src/search_provider.cpp` / `.h` 里注册新后端：解析 `search.deepseek` 段（`api_key` / `base_url` / `model`，都可选），把它加进 `get_configured_providers()` 与可用清单；照现有写法处理"没配就不出现"
- [ ] 3.2 让凭据能"复用会话模型那把"：`ensure_search_infra_impl` 收到的搜索配置里 SHALL 能带上会话模型的密钥与地址（Dart 侧组装），C++ 侧按规范里的顺序解析。**这条要写清字段名**（在 design 或代码注释里），否则 3.3 没依据
- [ ] 3.3 在 `lib/main.dart` 里把会话模型当前 provider 的密钥与地址一起交给搜索初始化（与现有把 `search` 段编码成 JSON 传下去的那行同一个位置），并保证：`search` 段里单独配了 `deepseek` 时以它为准
- [ ] 3.4 核对工具可见性这条行为真的变了：改之前"没配搜索密钥就没有 `web_search`"，改之后"有 DeepSeek 模型配置就有"。这条要在 4.1 的集成用例里被断言到（不许只靠肉眼）

## 4. 测试（本组是全部判据；每条判据怎么跑写在这里）

- [ ] 4.1 C++ 单测 `sidecar/test/deepseek_search_test.cpp`，按 `deepseek-search-provider-tests` 那份规范逐条覆盖：请求形状（**在不起网络的层上核对构造出的请求体**，例如把"构造请求体"抽成一个可单测的函数）；结果映射与去重；引用片段按网址对应；没有引用时标题兜底；标题坏字节不崩；`page_age` 为空不丢结果；`max_results` 按顺序截断；没有结果块时明确报错；失败说明带实际地址。加进 `sidecar/CMakeLists.txt` 的测试源码列表
- [ ] 4.2 C++ 单测的离线做法要写明：**不许在单测里真的联网**（构造响应文本喂给解析函数即可）；跑的时候用 `sidecar_tests.exe "[deepseek]"`（标签按文件里实际的写）单独跑这一组并贴输出
- [ ] 4.3 Dart 集成测试（经仓库根真实动态库）：把带 DeepSeek 凭据的搜索配置交给初始化 → 读可用后端清单 → 断言含 `deepseek`；再把凭据去掉 → 断言不含。**断言前先打印本次实际的清单内容**。
- [ ] 4.4 跑全量 Dart 测试：先 `powershell -NoProfile -File scripts\sync_sidecar_dll.ps1` 刷库（否则会被"动态库不是最新"那条守卫判红，也会看到 `Failed to lookup symbol` 的假回归），再 `flutter test`，把总数与 1.1 的对照贴出
- [ ] 4.5 跑一次完整的两套 C++ 读数：`ctest --test-dir sidecar/build/windows -C Debug`，把用例总数与 1.1 的对照贴出；唯一允许继续存在的失败是既有的那条网络用例（要指名道姓说是哪一条）
- [ ] 4.6 `flutter analyze` 零新增：改动前后各跑一次、拿总数对照（本机上一次是 **171 条**）

## 5. 让判据当场失败一次（证明它们真的能红）

- [ ] 5.1 把 `max_uses` 从 1 改成 5，确认请求形状那条用例变红；**改回来**，确认重新全绿
- [ ] 5.2 把"没有结果块"的分支改成返回 0 条成功，确认那条用例变红；**改回来**，确认重新全绿
- [ ] 5.3 去掉按网址去重，确认去重那条用例变红；**改回来**，确认重新全绿
- [ ] 5.4 把正文来源改成"用 `text` 块那篇回答的摘要"，确认"模型写的回答不作为结果内容"那条用例变红；**改回来**，确认重新全绿
- [ ] 5.5 收尾核对：全仓库 grep 变异标记（统一 `MUTATION-` 前缀），确认零残留；把四次变红的真实输出贴进交付说明

## 6. 用户文档与索引

- [ ] 6.1 更新 `Docs/user-guide/tools-web.md`：搜索现在也可以走 DeepSeek 自己的（**不需要额外密钥**）、它的代价（一次搜索等于一次完整模型调用，实测 5.4 秒、按 token 计费）、它的限制（结果条数由服务决定、摘要可能为空、日期常缺）、以及出问题时先看哪（错误说明里带着本次实际使用的地址）
- [ ] 6.2 检查 `README.md` 的功能文档索引是否仍与 `Docs/user-guide/` 双向一致（本次没新增文档文件，正常不需要改；如果一致就把结论写进交付说明，不要为了"改过"而乱动）
- [ ] 6.3 文档里出现的配置键（`search.deepseek.api_key` 等）与工具名 SHALL 能在产品代码里核到：跑 `flutter test test/unit/user_docs_test.dart` 并贴出输出
- [ ] 6.4 把文档里写的手动验证命令真的跑一遍（见第 7 组），把输出贴进交付说明

## 7. 真实环境验收（这一条是本变更的钱袋子，必跑）

- [ ] 7.1 用现有配置真的搜一次：经应用界面（或直接调 `web_search` 的入口）发一次查询，确认拿回**真实的网页结果**（标题 + 网址），并把这一次的读数（条数、耗时、是否截断）贴进交付说明
- [ ] 7.2 同一次观察里记录代价：从 `sidecar.log` 或请求记录里读出这次调用的输入/输出 token（如果有），如实贴出；读不到就写"读不到"，不许估
- [ ] 7.3 边界各来一次并贴输出：①把 `search.deepseek.base_url` 指到一个不可达地址 → 错误说明里应带那个地址；②把密钥清空（两处都清）→ 后端不出现在清单里、`web_search` 工具不出现
- [ ] 7.4 整套冒烟：`"C:\Program Files\Git\bin\bash.exe" test/smoke/run_all.sh`（从 PowerShell 直接 `bash` 会落到另一个环境里并因缺 `USERPROFILE` 中断），把通过 / 失败数与 1.1 那次的对照贴出，失败项逐条说明是不是本次引入
