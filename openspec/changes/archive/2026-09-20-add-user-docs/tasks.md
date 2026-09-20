## 1. 先把校验写出来（此时必然红）

- [x] 1.1 新增 `test/unit/user_docs_test.dart`，实现 design D4 的三类检查：①`Docs/user-guide/` 下的每份 `.md` 都在 `README.md` 的索引里被链接、且索引里链的每个文件都存在；②文档里出现的配置键都能在产品代码的解析路径里找到；③文档里出现的工具名都能在代码注册的工具清单里找到。检查要逐条打印现场（找到几份文档、索引里有几条、每个键/工具名在哪找到的），断言前先打印。
  **判据**：现在还没有 `Docs/user-guide/`，跑 `flutter test test/unit/user_docs_test.dart` 必须**红**，把红的实际输出贴出来（这就是本变更的 red，也是这条校验可失败的证据）。

## 2. 逐份写功能使用文档（照代码写，不照记忆写）

> 每份文档都按 design D3 覆盖六件事：这是什么 / 在哪用 / 怎么操作 / 参数或配置 / 出错时会看到什么 / 有哪些限制。取值一律按 design D5 那张来源表**读代码取原话**。
> 每份写完跑一次 `flutter test test/unit/user_docs_test.dart`，确认这一份没有引入"键/工具名对不上"的问题（此时索引还没加，第①类检查仍然红，属预期）。

- [x] 2.1 `Docs/user-guide/configuration.md`：配置文件 `~/.aliasagent/config.json` 在哪、长什么样；供应商侧（`api_key` / `base_url`）；每个 agent 类型能配什么（`provider` / `model` / `system_prompt` / `tools` / `max_context_tokens` / `thinking_effort` / `standing_requirements` / `compaction_threshold_percent`），以及缺省值是什么；首次启动的欢迎对话框只问两项（`API Key`、`Max Context Tokens`）；配置写错时会看到什么（缺 key 的提示、非法百分比回落缺省并打印一行提示）。
  **判据**：文里提到的每个键都能在 `lib/models/agent_type_config.dart`、`lib/models/provider_config.dart`、`lib/services/config_service.dart` 里 grep 到（贴 grep 输出）。
- [x] 2.2 `Docs/user-guide/chat.md`：怎么开会话、怎么发消息、流式回复长什么样、工具调用卡片与思考卡片分别表示什么、会话标题怎么来的、怎么删会话。
  **判据**：文里引用的界面文案（`New Chat`、`Send`、`Delete session`、输入框提示语）都能在 `lib/main.dart` / `lib/ui/chat_area.dart` 里 grep 到（贴输出）。
- [x] 2.3 `Docs/user-guide/real-context-view.md`：「对话视图 / 真实上下文」两个标签页的区别；真实上下文那一屏看到的是什么（真正发给模型的内容：System Prompt / Tools / 各条消息）；`Copy 原始 JSON` 是干什么的；什么时候这一屏是空的。
  **判据**：两个标签页的文案与 `Copy 原始 JSON` 都能在 `lib/main.dart` / `lib/ui/context_view.dart` 里 grep 到（贴输出）。
- [x] 2.4 `Docs/user-guide/context-compaction.md`：什么时候会压缩（阈值 = 模型能装下的总量 × 百分比，缺省 25%；攒够就压，不等窗口装满）；压缩后原文去哪了（仍在磁盘上，只是这次不发）；两级的含义（一段对话压成一条摘要 / 多条摘要再合成一条更粗的）；界面上怎么认出来（`## 更早上下文…` 标记）；想调就改 `compaction_threshold_percent`；压缩花的是模型调用（会花钱）。
  **判据**：阈值算法与两个标记字符串都能在 `lib/services/compaction/compaction_plan.dart`、`lib/services/compaction/summary_provider.dart` 里 grep 到；文里对阈值的描述与 `CompactionEngine.thresholdTokens` 的实际算式一致（读代码核对，把算式原话贴出来）。
- [x] 2.5 `Docs/user-guide/tools-file.md`：`read_file` / `write_file` / `edit_file` / `list_dir` / `glob_file` / `grep_file` 各干什么；**这六个由模型自动调用，用户不直接点**；**工作区边界**（路径相对工作区解析，而工作区是用户主目录；越界会被拒并返回什么错）；大文件怎么读（offset/limit、截断）；`edit_file` 的批量替换与"改不动就整批不改"。
  **判据**：六个工具名与"越界被拒"的错误文案都能在代码里 grep 到；工作区的取值来源（`setWorkspace(ConfigService.homeDir)`）贴出来。
- [x] 2.6 `Docs/user-guide/tools-web.md`：`web_search`（要付费搜索服务的 key；没有可用服务时是什么结果）与 `web_fetch`（抓一个 URL 的正文；对本地/内网地址会拒绝）；`get_current_time` 一并在这里说明或就近说明。
  **判据**：工具名与两类失败文案（无可用搜索服务、拒绝内网地址）都能在代码里 grep 到。
- [x] 2.7 `Docs/user-guide/tools-browser.md`：`browser_available` / `browser_navigate` / `browser_click` / `browser_type` / `browser_snapshot` 各干什么；会用本机真实的 Edge/Chromium 窗口（**用户看得见**）；点开会新标签页的链接会**跟随**过去；下载与权限请求会被拦；浏览器栈不可用时是什么结果。
  **判据**：五个工具名与"跟随新标签页"的行为都能在 `lib/main.dart`、`scripts/browser_worker.py`、`openspec/specs/browser-tool/spec.md` 里 grep 到。
- [x] 2.8 `Docs/user-guide/troubleshooting.md`：只写**代码里确实会出现的现象**及其含义与下一步 —— 例如配置缺 key、模型报错（界面上以 `Error:` 开头的回复）、文件越界被拒、搜索无可用服务、浏览器栈不可用、上下文超限时的表现；以及"日志在哪"（`%USERPROFILE%\.aliasagent\logs\sidecar.log`）。**不写猜测**，不写"可能是网络问题"这类没有代码依据的话。
  **判据**：每条现象都能指到代码里产生它的那一处；给不出出处的条目一律删掉（贴出你逐条核对的 grep 输出）。

## 3. README 变成总入口

- [x] 3.1 `README.md` 新增一节「功能文档索引」：每个功能一行（一句话说它是什么 + 链接到 `Docs/user-guide/<功能名>.md`）；并在"配置"一节附近补上两条最容易踩的前提：**文件类工具只能碰工作区（用户主目录）内的路径**、`web_search` **需要付费搜索服务的 key**。
  **判据**：`flutter test test/unit/user_docs_test.dart` 第①类检查转绿（索引与目录双向一致），贴输出。

## 4. 验证

- [x] 4.1 反例构造（防"假绿"）——证明三类检查各自能失败：①临时从 README 索引里删掉一条 ⇒ 应红；②临时在一份文档里写一个不存在的配置键（例如 `max_context_tokenz`）⇒ 应红；③临时在一份文档里写一个不存在的工具名（例如 `read_files`）⇒ 应红。三次都贴出红的实际输出，每次改完立刻还原并确认恢复绿。
- [x] 4.2 `flutter analyze`：改动文件不得新增问题；再跑一次 `flutter test test/unit/user_docs_test.dart` 确认绿。贴输出。（本变更不开窗口、不连网络，**不要**跑全量 `flutter test` —— 全量里含会开浏览器窗口的用例，与本变更无关。）
- [x] 4.3 内容准确性抽查：从 8 份文档里各挑一句**关于行为**的话，逐句给出它在代码里的出处，并现场用 grep 核一遍，贴输出。**核对不上的句子当场改掉或删掉** —— 这一条是防"照记忆写"的最后一道闸。
