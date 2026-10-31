## Context

`sidecar` 是一个进程内的 C++ 动态库，Dart 通过 `dart:ffi` 直接调它的导出函数。它今天的所有**执行状态**都是进程级单例，因为整个应用只跑一条对话：

| 状态 | 位置 | 今天的形态 |
|---|---|---|
| 18 个结果缓冲 + 11 个 `err_static` | `sidecar/src/sidecar_api.cpp` | 每个导出把返回值写进 `static std::string` 再返回指针；`g_last_tool_result` 还被 `set_workspace` / `read_file` / `list_dir` 共用，11 个异常分支另有函数局部 `err_static` |
| 工作区根、文件版本表与暂存文件 | `sidecar/src/tools.cpp` | `g_workspace` / `g_observed` 进程级各一份；`write_atomically` 的暂存序号是非原子静态计数，清理会删同目标的全部 `.tmp-*`，跨上下文会互删 |
| spill 调用序号 | `sidecar/src/spill.cpp` 的 `g_call_seq` | `++g_call_seq`，非原子，且进程重启从 1 重来；会覆盖上次留下的同序号文件，旧引用读到新内容 |
| 模型网关与崩溃环形缓冲 | `sidecar/src/sidecar_api.cpp`、`model_gateway.cpp` | `g_gateway` 一个实例；`g_ffi_ring` 是指向该实例内部缓冲的进程级裸指针，析构后不清空，崩溃转储会解引用失效内存 |
| 浏览器 | `sidecar/src/browser.cpp`、`scripts/browser_worker.py` | C++ 只有一个 Python 子进程，但 Python 的每个 `BrowserSession` 自己 `chromium.launch()`，实例化多份就是多个 Edge。死亡通知也是进程级 |
| 搜索与抓取 | `search_provider.cpp`、各 provider、`web_fetch.cpp` | 初始化状态、provider 实例、凭据、限流计数与 Python 探测均共享；其中智谱请求已有 `g_zhipuai_mutex`，不能笼统说这些状态都不存在 |
| Dart 请求状态 | `lib/services/sidecar_bridge.dart` | `_chain`、`_lastRequestId`、`_pendingRequests` 都只有一份；`sendMessage` / `cancelRequest` 不带上下文 |

当前工具循环串行，界面也用 `_isStreaming` 限制同时只有一个会话在跑，所以这些单例大多尚未成为日常可见故障。本变更针对的是下一阶段：一旦同上下文只读工具并行、不同上下文或子 agent 同时执行，现有所有权就会失效。

## Goals / Non-Goals

**Goals:**

- 不同上下文的工作区、文件版本、spill、模型与浏览器状态互不可见；同一上下文并发调用也不会因共享缓冲、非原子序号或注册表竞争而串结果。
- 上下文创建、恢复、销毁都有完整生命周期；销毁不会在模型或工具仍在执行时释放资源。
- C++ 与 Dart 桥允许两个上下文各自发模型请求；同一上下文的请求仍按序执行。
- 启动恢复、切换、新建会话都能得到已初始化的上下文；机器级初始化不依赖先有上下文。
- 每一步都可编译、可测试，第一步的内部验收入口确实能触达被测状态。

**Non-Goals:**

- 不把工具循环改成并行；本期只保证并行发生时所有权与生命周期正确。
- 不开放界面层多会话同时发送，`_isStreaming` 的交互改造另立变更；本期「两个上下文并行」由底层与集成测试验收。
- 不做子 agent、不做进程隔离，也不要求句柄等于会话 id。
- 不改消息/摘要存储与界面布局。

## Decisions

### 决策 1 —— 句柄用原始名字，创建与销毁都返回 JSON

`create_context(const char* name)` 的句柄值就是调用方传入的原始字符串；注册表按原样、区分大小写保存，不要求它等于会话 id。返回类型统一为 `const char*`，内容是 JSON：

- 成功：`{"ok":true,"handle":"<原名>","created":true|false}`；`created` 让 Dart 知道要不要初始化工作区；
- 空名字：`{"ok":false,"code":"empty_context","error":"..."}`；
- `no-session` 与 `_it_` 前缀：`{"ok":false,"code":"reserved_context","error":"..."}`。前者与启动清理的历史目录同名，后者是测试专用目录前缀，允许它们当句柄就会被启动清理误删；
- 同名上下文正在销毁：`{"ok":false,"code":"context_disposing","error":"..."}`，不许新旧两份同名上下文并存。

`dispose_context(const char* handle)` 也返回 JSON；未知或已经销毁的句柄按幂等成功处理。两个函数的返回字符串同样遵守决策 4 的调用线程所有权。

**备选**：直接返回裸句柄字符串。它无法同时表达 `ok:false`、错误代码和 `created`，所以不采用。整数索引与裸指针也不采用：前者需要额外 id 分配与误用检查，后者销毁后有悬垂风险。

### 决策 2 —— 注册表加锁，调用先取租约；未知句柄不隐式创建

注册表是 `map<string, shared_ptr<Context>>`，所有查找、创建、标记销毁都在注册表锁内完成。每次上下文调用先取得一个 `shared_ptr` 租约并增加在途计数，返回前由局部对象自动扣减；这样销毁线程不会拿到正在使用的裸引用。

未知或已销毁句柄不得隐式创建。错误形状按返回类型区分：

- 返回 JSON 的工具：`{"ok":false,"code":"unknown_context","error":"..."}`；
- `set_workspace` 保持原有「成功空串、失败纯文本」的形状，未知句柄返回纯文本 `unknown_context: <handle>`，不伪装成成功空串；
- `send_message`：返回负数，并通过 `on_done` 交付 `unknown_context` 错误；这不是一次真实模型请求，不进入该上下文的请求队列；
- `cancel_request`：返回 JSON，未知名称同样给 `unknown_context`，不再静默忽略拼错的句柄。

`send_message` 的空或 null API key 继续走既有早退：`on_done(0, "", ...)` 并返回 1，不是「未知句柄」也不是这次要改的错误语义；主规范里原先写成负数的那句一并改回事实。

`ping`、`browser_available`、`ensure_search_infra`、`get_search_providers` 是机器/应用级接口，不需要句柄，也不做 unknown-context 检查。其余 19 个既有导出按本决策带句柄（含 `cancel_request`）。

### 决策 3 —— 状态按「会话 / 调用线程 / 机器」三类归属

| 状态 | 归属与同步责任 |
|---|---|
| 工作区根、文件版本表、spill 序号、模型网关、浏览器会话及其子进程代次 | **每上下文一份**；读写由该上下文的锁保护，写操作另有闸门；spill 序号用原子取号，创建时扫描目录续号 |
| 18 个 `g_*_result`、11 个 `err_static`，以及 create/dispose/cancel 的动态 JSON | **每调用线程一份**（`thread_local`）；理由见决策 4 |
| 上下文注册表 | 进程级一张表，但只存共享引用；由注册表锁与在途计数保护 |
| 暂存文件协议 | `write_file` / `edit_file` 共享进程级锁与原子计数器；跨上下文写同一文件时也不会互删 `.tmp-*` |
| 搜索初始化、provider 实例与凭据 | 应用级共享；由启动时的 `_toolsReady` 闸门保证任一 `web_search` / `web_fetch` 调用前已配置，执行期不重配。`dispatch_web_search` 另用一把进程级互斥串行，避免多个上下文同时碰 provider 的可变状态；智谱内部限流锁保留 |
| 浏览器 Python 子进程、唯一 `Browser`、`BrowserContext` 表、管道、job、生命周期锁、可用性探针 | 机器级共享；一个子进程只 `chromium.launch()` 一次，上下文只新建 `BrowserContext` |
| FFI 环形缓冲 `g_ffi_ring` | 进程级共享，但由独立锁保护：`execute` 登记、析构只在指针仍指向自己时清空、崩溃转储持锁读取；只用于诊断，多个并发请求时最新登记者被转储 |
| 全局请求 id 计数器 | 进程级共享且保持原子；它只保证跨上下文唯一，不代表请求归属 |
| 日志、崩溃设施、Python 探测 | 机器级共享；首次初始化需锁或 `call_once`，不能只凭「追加写天然安全」略过并发初始化 |
| 测试专用的 spill 根覆盖与失败注入 | 进程级共享，仅测试使用；相关测试不得并发执行 |

「共享」不再写成「只剩三样」这种不真陈述；每一类都要说清为什么共享、由哪把锁或哪种只读约束保证安全。

### 决策 4 —— 返回缓冲按调用线程分；上下文状态用短锁与写闸门保护

**返回缓冲不能简单搬进上下文。** 同一上下文也会并发调用；即使调用期间持锁，函数返回后锁就释放了，而 Dart 随后才执行 `toDartString()`，另一个线程仍可能在这段时间改写同一份 `std::string`。所以 18 个 `g_*_result` **与 11 个函数局部 `err_static`** 全部改成每导出函数一份 `thread_local` 存储。

抽一个很小的 `result_buffer` 源码单元（头 + cpp），由 `sidecar_api.cpp` 与 `sidecar_tests` **共同编译**；否则 `sidecar_tests` 不链接 `sidecar_api.cpp`，验收根本碰不到返回缓冲。`sidecar_api` 的异常分支也写同一槽，不准再留局部 `err_static`。Dart 保持返回后立即同步复制，不保存指针备用。

**上下文内部也不能只搬变量不加锁。**

- `state_mutex` 保护工作区与文件版本表的读写；spill 序号改用每上下文原子取号，不走这把锁。`tools::workspace()` 改为按值返回，禁止把锁内引用带出临界区；锁不覆盖子进程或网络等待。
- spill 序号用该上下文的 `std::atomic<unsigned>` 取号，创建上下文时扫描其目录已有 `NNNNNN-*.txt` 的最大值后继续，避免重启从 1 覆盖旧文件；不再依赖 `state_mutex` 串行序号。
- 同一上下文的 `set_workspace` / `write_file` / `edit_file` / `run_command` 走写操作闸门；只读工具可并行。
- `write_file` / `edit_file` 的暂存文件另用**进程级** staging 锁与原子计数器包住「清理旧暂存 → 生成新暂存 → 改名」，因为两个上下文可能写同一个目标文件；只靠每上下文写闸门会互删对方正在写的 `.tmp-*`。
- 文件版本表必须按上下文分：甲读 v1、乙写 v2 后，若共享，乙会把表也更新成 v2，甲没读过却被 `edit_file` 放行；分开后甲得到 `stale`。同一上下文内的版本表访问仍要 `state_mutex`，否则 `std::map` 本身就是数据竞争。
- 模型请求由每上下文自己的 `request_mutex` 串行；不同上下文不共用这把锁。浏览器同一上下文的多步操作另有序列约束，不同上下文不共享页面。

**备选**：所有工具都按上下文串行。它能满足正确性，但会把下一阶段只读工具并行重新堵死；返回指针在锁释放后也仍有问题，所以不采用。

### 决策 5 —— 销毁按「关闭入口 → 取消 → 排空 → 清理」执行

`dispose_context` 不允许直接 erase 后析构。顺序固定为：

1. 在注册表锁内把上下文标为 `disposing`，此后新调用与同名创建分别得到 `unknown_context` / `context_disposing`；旧对象仍留在表里直到清理完，避免同名新旧并存。
2. 对该上下文的网关发起取消，并等待它的真实 done；不再发起新的模型请求。
3. 等待在途调用计数归零（不计 dispose 自身）。计数覆盖工具、模型和浏览器调用，不能只等 Dart 的 `_chain`。
4. 关闭该上下文的 `BrowserContext`，删除该上下文的 spill 目录，再从注册表移除并释放对象。重复销毁等待同一次清理结束后幂等返回。

Dart 侧还要覆盖「已排队但尚未进入 C++」与「C++ 已 done、Dart 尚未处理回调」两层：`disposeContext` 先标记关闭并拒绝新调用，取消该上下文模型请求，等待它的 `_chain`、工具 Future 与回调处理全部结束，再通过 worker isolate 调 C++ `dispose_context` 完成底层排空和清理，最后才删队列与计数。不能在界面线程同步阻塞。

删除会话时先让界面停止该会话的新发送，再取消并等待该会话的**整轮 Future**：它必须覆盖 `_sendMessage` 里 `sendMessage` 返回后的 `insert` / `touch` / `updateToolCalls`，以及后台压缩写摘要节点。桥的 `_chain` 只包 `_sendMessageInner`，回调里也只给标量赋值，单等它不能证明数据库写入已结束。整轮 Future 与 dispose 都结束后，才删数据库与更新列表。

`ChatScreen` 因此要按会话登记在跑的整轮 Future（含后台压缩），删除时 await；不能沿用今天「先删数据库/清 spill、后 `_endStreaming`」的顺序。这样数据库删除既不会早于 C++ 在途调用结束，也不会早于外层轮次的数据库写入。

**不新增销毁超时魔数**：模型有既有取消路径，`run_command` 与浏览器调用已有自己的超时；销毁如实等待它们结束，若路径失效就暴露问题，不伪造成功。

### 决策 6 —— 模型网关每上下文一个，取消只打本上下文

`g_gateway` 的单实例 `request_mutex` 让全进程只有一个请求在飞。改成每上下文一个 `ModelGateway`：同一上下文仍由自己的 `request_mutex` 串行，两个上下文的执行区间可以重叠；curl 句柄、`pending_strings` 与取消状态都随网关归属。

`send_message` 首参加句柄；`cancel_request` 改成带句柄与请求 id，并返回决策 2 规定的 JSON。`ModelGateway::Impl::next_request_id` 继续保持共享原子计数，确保跨上下文 id 唯一。

进程级 `g_ffi_ring` 要补生命周期：用独立锁保护这个裸指针；`execute` 在锁内登记自己的环形缓冲，网关析构前在锁内判断「仍指向自己才清空」，崩溃转储在锁内读取。它不是按上下文分的东西，但也不能让两个上下文并发覆盖或留下悬垂指针。

**主规范必须同步**：`model-gateway` 的「全局 request mutex」改为「该上下文的 request mutex」，`thinking-streaming` 的回调字符串清理条件也改成同一上下文的前一个请求已结束且 done 已处理。只改 design 会让归档后的规范互相打架。

### 决策 7 —— 浏览器共享子进程，但会话有归属、子进程有代次

`scripts/browser_worker.py` 不能再让每个 `BrowserSession` 自己 `chromium.launch()`：那会为每个上下文各起一个 Edge，和决策相反。改成 worker 持一个 `Browser`，`sessions[ctx]` 只保存该 Browser 下新建的 `BrowserContext`、页与观察字段。每条命令带 `ctx`；`open` 显式创建或重开，`close` 只关闭该 `ctx`；新增 `stats` 返回 `browser_pid` 与上下文数，供测试证明两个上下文共用同一浏览器进程。其它命令遇到未知 `ctx` 必须返回 `dead:true` 与可区分错误，**不得隐式 new_context**。

C++ 仍共享一个子进程。上下文首次使用浏览器、或死亡提示后允许显式重试时，C++ 先向子进程发 `open`，成功后再发原命令；Dart 工具面不新增 `open`。每次 `start_worker` 成功都推进 `worker_generation`，每个上下文记录自己浏览器会话所属的代次：

- 上下文已有浏览器会话，而当前代次不同 ⇒ 先返回一次「页面已消失」的 `dead:true`，把是否允许重开的状态记在该上下文上；
- 只有该上下文的下一次显式重试才能发 `open` 并记录新代次；
- 因此即使甲先把子进程重启，乙随后调用仍会因代次不符收到失败，不会在新页上静默得到 `ok:true`；销毁时的 `close` 若发现子进程已死，只清本地记录，不得为了清理再启动子进程。

`g_cmd_mutex` 只包 `send_command`，真实 `run_browser_op` 在锁外检查存活并 `start_worker`/`stop_worker`，会并发改写 `g_proc` / 管道 / `g_job`。新增一把 worker 生命周期锁，固定加锁顺序「生命周期锁 → 命令锁」，覆盖存活性检查、启动、停止、发送与代次推进；不允许在生命周期锁外改这些句柄。

「每个上下文一个独立 Edge 进程」不采用；一个进程内多个 `BrowserContext` 就能隔离 cookie/storage。窗口增多的问题仍由非当前会话最小化缓解，不在本变更引入新的数量上限。

### 决策 8 —— spill 以句柄为键，读回也限制在本上下文

`run_command` 删除 `spill_session` 字段，直接用首参句柄计算目录与序号；`dispose_context` 在排空后删除同一键的目录，同时删除 Dart 的 `deleteSessionSpill` 函数及其调用点。`read_spill` 除了现有的「必须在 spill 根内」，还必须落在**该句柄对应的本上下文目录**内；用乙的句柄读甲的绝对路径引用要返回 `ok:false`。判断前必须先把引用规范化：Windows 用 `GetFullPathName`，POSIX 用 `realpath`（目标存在才读），不能只做字符串前缀比较，否则 `乙/../甲/文件` 会过检查而 `fopen` 解析到甲。引用不存在时要先解析父目录再拼文件名，保留「引用不存在」这条可区分错误，不能因为 `realpath` 失败误报成越界。

目录名保留集收紧到 `[a-z0-9_-]`，其余字节（含大写、`.`、`%`、非 ASCII）统一写成 `%XX`（大写十六进制）：既消除旧下划线映射的有损碰撞，也避免 `..` 出根与 Windows 大小写撞目录。`create_context` 必须拒绝 `no-session` 与 `_it_` 前缀，否则合法上下文会与启动清理的无主目录撞名；`no-session/` 只作旧数据清理。

**序号必须跨进程续号**：现有 `unsigned g_call_seq` 只存内存，重启从 1 开始，`MoveFileExW(REPLACE_EXISTING)` 会覆盖上次的 `000001-stdout.txt`，使旧引用读到新内容。上下文创建时扫描自己的 spill 目录里 `NNNNNN-*.txt` 的最大序号，从最大值 +1 继续；目录不存在则从 1 开始。

**升级兼容**：生产会话 id 由 `SessionRepository` 的 UUID v4 生成，字符都在保留集内，所以现有真实会话的目录名不变；加上续号后旧引用仍可读取。旧版其它有损目录名无法可靠反推原始会话名，不做猜测性迁移；跨目录读回会明确报错而不是静默读别人的文件。C++ 与 Dart 的编码样例合并为一份共同读取的 `sidecar/test/spill_session_names.tsv`。

### 决策 9 —— 上下文接口不保留旧签名，机器级接口不强行加句柄

19 个上下文相关导出一次性换签名，Dart 与测试同步修改，不留「忘了传句柄就走默认上下文」的兼容入口。`ping`、`browser_available`、`ensure_search_infra`、`get_search_providers` 不需要上下文，保持原签名，避免伪造一个应用级默认上下文。

启动顺序不假装是同步的：`initState` 里 `_initSearchAndTools()` 与 `_loadSessions()` 都不 await，搜索配置还排在 `browserAvailable()` 之后。恢复会话可以更早建好上下文，这没关系；真正的要求是**发送入口等到 `_toolsReady`**，因此任一 `web_search` / `web_fetch` 调用前搜索配置已完成。不要写成「搜索初始化先于会话加载」。

### 决策 10 —— Dart 用 ensureContext 贯通启动、工具、模型与取消

`SidecarBridge` 增加幂等的 `ensureContext(sessionId)`：调用 `create_context`，仅在返回 `created:true` 时设置缺省工作区；`created:false` 表示 C++ 状态仍在，不得重复覆盖工作区。`disposeContext` 要解析两个函数的 JSON 返回，不能只解析创建那一半。启动恢复、`_selectSession`、`_newChat` 和每次模型/工具调用前都可重复调用。`setWorkspace` 移到上下文建立之后；搜索配置与浏览器探测仍各自独立初始化，由 `_toolsReady` 保证发送前完成。

所有上下文工具方法都带句柄，`_executeTool` 从 `_callModel` 显式接收 `sessionId`，不能读取可变的 `_currentId` 冒充本次调用的归属。

`sendMessage` 同样带句柄；`_chain`、`_lastRequestId`、`_pendingRequests` 全改成按句柄分。`cancelRequest` 带句柄，超时路径用「句柄 + 本次 requestId」，不能只改 `_chain` 而留下全局取消。`SummaryProvider`、`ModelSummaryProvider`、`SeamSelector` 及其调用方也要传会话 id，否则后台摘要会落进无上下文或错误上下文。`disposeContext` 完成排空前，对应队列与计数不得提前删除。

**取消失败的兜底必须改**：现有 30 秒 fallback 会合成 done、完成 Future 并放行闸门，正好违反本变更的字符串寿命前提。改成：不再调用模型的 `onDone`，让等待的 Future 以错误结束；把该句柄标为 `context_poisoned`，拒绝后续请求；不关闭仍可能被 curl 线程使用的 callable；销毁时如实尝试取消与排空，若无法排空就保留资源并报错，直到进程退出。测试要用可控的无 done 路径覆盖这条分支；只允许测试注入缩短兜底等待，生产常量不变。

`ChatScreen` 还要按会话登记整轮 Future（含模型循环、工具、`insert` / `touch` / `updateToolCalls` 与后台压缩写库），删除会话时 await 它们；桥的 `_chain` 不覆盖这些外层写入。

界面 `_isStreaming` 仍按现状，不把它伪装成已经支持多会话同时聊天；本决策验收的是 bridge、C++ 与数据写入排空能力。

### 决策 11 —— 两步迁移，但第一步就提供能触达状态的内部验收入口

- **第一步**：保留现有导出面与**现有 spill 目录名/返回引用**不变，内部引入 `Context`、注册表、线程本地返回缓冲与各锁；把 `err_static` 一并迁进 `result_buffer`，该源码同时编进库与 `sidecar_tests`。新增 `context_api` 作为显式接收 `Context&` 的内部包装层，正式导出与测试都走同一实现；测试不能直接拿 `tools::read_file` 的按值返回去断言 FFI 缓冲地址。
- **第二步**：导出 create/dispose，19 个上下文导出换签名，机器级 4 个保持不变；同一步再改 spill 键、目录编码、续号与 `read_spill` 本上下文限制；Dart 与测试同步接上。

第一步结束要求现有导出行为不变、现有测试全绿；目录编码属于公开引用，必须和 spill 键一起放到第二步，不能提前。这样每一步都能独立定位是状态搬错还是接口接错。

## Risks / Trade-offs

- **19 个签名更换导致中间态不可运行** → 决策 11 两步走；机器级 4 个接口不变，减少启动顺序破坏面。
- **线程本地返回指针被调用方缓存** → 接口文档明确「返回后立即复制、不得保存指针」，并用两个 OS 线程同时调用同一上下文的用例证明不会互相覆盖。
- **销毁等待暴露既有取消缺陷** → 不伪造完成、不新增超时数字；用删除中流式请求和长命令的测试证明会等真实结束。若取消本身失效，应修取消路径，不能让 dispose 假装成功。
- **共享搜索 provider 的线程安全不一致** → 执行期不得重配，逐项核实真实 provider 的共享可变状态并在需要处加锁；假 provider 只证明并发分派与结果封装，不冒充真实 provider 的验证。
- **跨上下文写同一文件互删暂存** → 进程级 staging 锁 + 原子计数器，并用两上下文写同一目标的并发用例检验；发现 `.tmp-*` 被别的上下文删掉即失败。
- **重启覆盖旧 spill 引用** → 每上下文创建时扫描已有最大序号续号，用「先写 1 号、重启重建上下文、再写一次」的用例证明旧引用不被覆盖。
- **浏览器子进程重启丢全部页面** → 一个 `Browser` + 多 `BrowserContext`，用 `stats` 证明没有多起 Edge；用代次与未知上下文错误保证每个上下文都先收到失败。
- **取消失败兜底毒化上下文** → 不伪造 done，不做静默重试；用无 done 的测试覆盖 poisoned 状态，并接受该上下文需要销毁/重启才能恢复。
- **底层已并行、界面仍单路** → 在 proposal 与验收中明确区别，避免把 bridge 的测试通过说成产品已支持多会话同时发送。

## 未决问题

- **子 agent 的上下文名字与父子关系**：本变更只保证句柄不必等于会话 id；子 agent 是否是真会话、何时建销，由后续子 agent 变更决定。
- **浏览器窗口形态**：每个 `BrowserContext` 是独立窗口还是同窗口标签，由后续实测决定；本变更只钉状态隔离与死亡可见性。
- **环境变量**：`run_command` 缺省 cwd 随上下文工作区走，但进程环境变量仍共享，本期不做环境隔离。
