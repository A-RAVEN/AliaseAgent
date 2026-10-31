## 1. 第一步：建立正确的所有权与内部验收入口（导出面与 spill 引用不变）

- [ ] 1.1 新建 `sidecar/include/context.h`、`sidecar/src/context.cpp`、`sidecar/src/result_buffer.h/.cpp` 与 `sidecar/src/context_api.h/.cpp`：上下文注册表用 `shared_ptr` 租约与在途计数；`result_buffer` 提供按导出函数/调用线程的 `thread_local` 槽；`context_api` 是接收 `Context&` 的内部包装层，导出函数与测试都走它；另提供 `reset_registry_for_tests()`（只清注册表、不删 spill 目录，供重启续号用例）。三个 `.cpp` 同时加入库和 `sidecar_tests` 的源清单，两个头加入包含路径。
  - **验收（能失败）**：`sidecar_tests.exe "[context]"` 能跑；两个线程并发取同一名字必须得到同一对象、不同名字不同对象；`result_buffer.cpp` 不在测试二进制里时 1.2 的用例链接/运行失败。去掉注册表锁或用裸指针表时线程检查失败。
- [ ] 1.2 把 `sidecar/src/sidecar_api.cpp` 的 18 个 `g_*_result` 与 **11 处函数局部 `err_static`** 改成使用 `result_buffer` 的线程本地槽；异常分支写同一个槽。`context_api` 提供接收 `Context&` 的测试入口，导出函数委托给同一实现，测试不能绕过它另测一份临时字符串。
  - **验收（能失败）**：用测试屏障固定交错：A 已拿到返回指针、B 完成调用后 A 才复制，A 内容必须仍是 A；改回进程级或每上下文一份时 A 被覆盖成 B。另用一个异常分支制造动态错误，证明 `err_static` 不再共享；扫描 `static std::string err_static` 必须零命中。
- [ ] 1.3 把 `g_workspace` 搬进上下文，`tools::workspace()` 改为按值返回；`set_workspace`、`write_file`、`edit_file`、`run_command` 接入该上下文写闸门。`write_atomically` 的暂存序号改为原子，并用**进程级 staging 锁**包住清理旧暂存、生成新暂存、改名三步。
  - **验收（能失败）**：甲设工作区、乙不设，乙的读文件与缺省 cwd 不落到甲目录。两个上下文用屏障同时写同一文件：都成功后文件内容等于其中一次完整写入，且任何一方正在写的 `.tmp-*` 不被另一方清掉；删除 staging 锁或改回非原子计数器时该用例红。
- [ ] 1.4 把 `g_observed` 搬进上下文，所有查找/插入/清空都受该上下文 `state_mutex` 保护；`reset_observation_state_for_tests` 改为按上下文重置。
  - **验收（能失败）**：甲读 v1、乙写 v2、甲再编辑得到 `code:"stale"`；改回共享表时被放行。同上下文两个线程反复读/写版本表，去掉锁时必须由断言或线程检查检出。
- [ ] 1.5 把 spill 序号改成每上下文一个 `std::atomic<unsigned>`；`run_command` 仍走写闸门，但取号本身不依赖闸门串行。
  - **验收（能失败）**：两个线程**直接调用内部 spill 写入入口**（绕开写闸门）取号，序号必须不同、文件互不覆盖；把序号改回非原子 `unsigned` 或用错上下文的计数器时，用屏障放大交错后必须检出。另有一条经 `run_command` 的同上下文并发用例，验证业务入口结果也正确。
- [ ] 1.6 把 `g_gateway` 改成每上下文一个 `ModelGateway`；`Impl::next_request_id` 保持共享原子。给 `g_ffi_ring` 增加独立锁：`execute` 登记、析构时仅当仍指向自己才清空、崩溃转储持锁读取。
  - **验收（能失败）**：用本地 HTTP 夹具证明同一上下文请求串行、两个上下文执行区间重叠、取消甲不影响乙、乙启动不清甲的回调字符串。两个上下文各跑一次后销毁最后一个网关，再调用 `dump_ffi_ring_buffer()` 不得解引用已释放内存（ASan/崩溃日志路径验证）；去掉锁或析构清零时对应用例/ASan 红。
- [ ] 1.7 给搜索执行加进程级互斥：`dispatch_web_search` 与 provider 配置初始化不得并发；`ensure_log` / `ensure_debug_infra` 的首次初始化改为线程安全。假 provider 只用于验证分派，不冒充真实 provider。
  - **验收（能失败）**：两个上下文并发 `web_search` 时假 provider 每次只观察到一个在跑，两个结果完整不混；去掉搜索互斥时屏障用例红。另用两个线程并发首次调用日志初始化，不得出现未初始化访问；`ensure_search_infra` 仍由启动的 `_toolsReady` 保证先于发送。
- [ ] 1.8 改 `scripts/browser_worker.py`：一个 `Browser`（只 `chromium.launch()` 一次）+ `sessions[ctx]` 里各一个 `BrowserContext`；命令带 `ctx`，`open` 显式建/重开，`close` 只关指定上下文，新增 `stats` 返回 `browser_pid` 与上下文数；未知 `ctx` 返回 `dead:true`，不得隐式创建。
  - **验收（能失败）**：甲、乙各 open/navigate/snapshot 各读各页；`stats` 两次的 `browser_pid` 相同、上下文数为 2；对未 open 的 `ctx` 发 navigate 失败且上下文数不增；改回每上下文一个 `BrowserSession` 时 `browser_pid` 不同，红。
- [ ] 1.9 改 `sidecar/src/browser.cpp`：先发 `open` 再发首次命令；每次成功 `start_worker` 推进 `worker_generation`，上下文记录所属代次与是否允许重开；新增 worker 生命周期锁，按「生命周期锁 → 命令锁」覆盖存活检查、启停、句柄替换与代次推进；销毁 close 不重启死进程。
  - **验收（能失败）**：甲、乙**同时**首次调用只产生一个子进程/一个代次，两个上下文都拿到该代次。子进程死亡后甲先收到 dead 并重启，乙随后调用仍收到 `dead:true`。销毁时子进程已死，close 不新增进程。去掉生命周期锁时并发启停用例失败。
- [ ] 1.10 第一步收尾：公开导出签名与 spill 目录/引用格式不变。
  - **验收（能失败）**：`git diff sidecar/include/sidecar_api.h` 为空；`sidecar_tests` 全绿；同一命令产生的 spill 路径与改动前完全相同。提前改编码、加句柄或让机器级接口要求上下文时，这条失败。

## 2. 第二步：公开句柄接口并贯通 Dart

- [ ] 2.1 导出 `create_context(name)` / `dispose_context(handle)`，按 design 返回 JSON：成功含 `handle` 与 `created`，空名 `empty_context`，`no-session` / `_it_` 前缀 `reserved_context`，销毁中重建 `context_disposing`，重复销毁幂等。两项返回都遵守线程本地所有权。
  - **验收（能失败）**：覆盖首次/重复创建、空名、两个保留名、销毁中重建、销毁后重建为空状态、重复销毁；直接返回裸句柄、缺少 `created` 或接受 `no-session` 时用例红。
- [ ] 2.2 实现销毁排空：标 `disposing` 后拒绝新调用，取消模型请求，等待模型/工具/浏览器在途计数归零（不含 dispose 自身），再关浏览器上下文、删 spill、移除注册表。同名旧对象在清理完成前不消失。
  - **验收（能失败）**：慢响应模型与长命令各一条：销毁后新调用立即失败，旧调用有真实结束记录，资源只在最后一个在途调用结束后释放；同名创建在清理前返回 `context_disposing`。毒化且无法排空时销毁返回 `ok:false` 并保留资源。直接 erase/析构或把未排空报成成功时用例红。
- [ ] 2.3 19 个上下文相关导出换签名；`cancel_request` 带句柄与请求 id 并返回 JSON；`send_message` 未知句柄返回负数并经 `on_done` 报错，空 api_key 仍返回 1 且 `on_done(0)`；`set_workspace` 保持纯文本返回，未知句柄给 `unknown_context: <handle>`。`ping` / `browser_available` / `ensure_search_infra` / `get_search_providers` 保持原样。
  - **验收（能失败）**：`sidecar_api.h` 逐一列出 19 个改名与 4 个不变；未知句柄覆盖 JSON 工具、`set_workspace`、`send_message`、`cancel_request` 四类，都不执行实际操作；空 api_key 的既有早退有单独断言。隐式创建、静默 no-op 或把空 key 改成失败时红。
- [ ] 2.4 spill 改用首参句柄：删除 `spill_session`；目录名改成只保 `[a-z0-9_-]`、其余 `%XX`；上下文创建时扫描本目录已有最大序号续号；`read_spill` 先按平台规范化再只接受本上下文目录，拒绝直接跨目录和 `<乙>/../<甲>`；销上下文删目录，删除 Dart `deleteSessionSpill` 函数与调用，保留启动清理 `no-session/`。
  - **验收（能失败）**：C++ 与 Dart 共读 `sidecar/test/spill_session_names.tsv`，含中文、`.`、`..`、空串、大小写、UUID；两侧一致且 UUID 编码前后相同。用测试钩子清空注册表但保留 spill 目录模拟进程重启：先写 1 号、重建同名上下文、再写必须得到更大序号，旧 1 号内容不变。乙读甲直接路径与 `乙/../甲` 都必须拒绝；不存在的引用仍返回“引用不存在”，不能被 POSIX `realpath` 失败误报成越界。只做字符串前缀、退回下划线、从 1 重来或保留 `no-session` 为合法句柄时各自红。
  - **测试夹具迁移**：现有 `spill_envelope_test.dart` 用 `_it_envelope` 作为会话名，必须改成不触发保留前缀的名字（如 `it-envelope`），并在 tearDown 自己删目录；不得靠启动清理删除自己的数据。
- [ ] 2.5 Dart 桥新增 `ensureContext` / `disposeContext`，**创建与销毁两种 JSON 返回都要解析**（含失败形状）；只在 `created:true` 时设缺省工作区，`created:false` 不覆盖；`disposeContext` 先等桥内队列/工具 Future/回调，再走 worker isolate 等 C++ 排空，不阻塞界面线程。
  - **验收（能失败）**：`test/unit/` 用真 DLL 覆盖两种返回、首次/重复 ensure、空名与保留名、销毁后再建，并证明第二次 ensure 不重置工作区；`test/integration/` 用**真实 `SidecarBridge` + 本地延迟 SSE** 证明 dispose 未完成前不会提前删桥内队列，界面线程没有被同步 FFI 堵住（不能用 `FakeSidecar` 冒充桥内部）。只解析 create 那一半时对应用例红。
- [ ] 2.6 所有 Dart 工具方法带句柄；`_executeTool` 从 `_callModel` 显式接收 `sessionId`。启动恢复、`_selectSession`、`_newChat` 调用 `ensureContext`；`setWorkspace` 从会话加载前移到上下文建立后，`_initSearchAndTools` 保持可提前执行并仍由 `_toolsReady` 挡发送。同步 `test/integration/helpers/fake_sidecar.dart`。
  - **验收（能失败）**：`test/integration/` 覆盖重启恢复、切换既有会话、新建会话，工具都不报 `unknown_context`；构造「轮次属甲、界面已切乙」，请求仍带甲。恢复只赋 `_currentId`、用 `_currentId` 顶替或提前设工作区时对应用例红。
- [ ] 2.7 `ISidecar.sendMessage` 带句柄；`_chain`、`_lastRequestId`、`_pendingRequests` 按句柄分。`cancelRequest` 带句柄，超时传「句柄 + 本次 requestId」。取消后无真实 done 时**不合成 `onDone`**：等待 Future 报错、上下文标 `context_poisoned`、拒绝新请求、保持 callable 打开，直到销毁或进程重启。
  - **验收（能失败）**：用**真实 `SidecarBridge` + 本地延迟 SSE HTTP 服务**证明两个上下文请求区间重叠、同上下文仍排队、甲乙互不误取消、超时用本上下文句柄；用可注入的取消失败路径与**缩短兜底等待的测试钩子**证明无 done 时走 poisoned 且不调用 onDone。`FakeSidecar` 只用于上层，不用于验桥内部字段；恢复全局 `_chain` / `_lastRequestId` / `_pendingRequests` 或恢复 30 秒假 done 时用例红。
- [ ] 2.8 摘要链路带句柄：`summary_provider.dart`、`model_summary_provider.dart`、`seam_selector.dart` 的 `summarize` / `summarizeText` / `ensure` 及 `lib/main.dart` 调用点都显式带 `sessionId`，fake 同步。
  - **验收（能失败）**：`test/integration/` 记录后台摘要与分缝请求的句柄，必须等于被压缩会话；两个会话交替压缩时不得都用最后句柄。漏传或改读全局 `_currentId` 时红。
- [ ] 2.9 删除会话前等待整轮：`ChatScreen` 按会话登记在跑的整轮 Future（模型循环、工具、`insert` / `touch` / `updateToolCalls`、后台压缩写库）；`_deleteSession` 先停新发送，await 这些 Future 与 `disposeContext`，再删数据库与更新列表。
  - **验收（能失败）**：`test/integration/` 在流式请求、长命令、后台压缩写库三种时点删除会话，断言数据库删除不早于最后一个写库完成，且没有删除后到达的写入；恢复今天「先删库、后 `_endStreaming`」或只等 `_chain` 时红。
- [ ] 2.10 第二步收尾：旧上下文全局、旧返回缓冲与旧字段清干净，所有调用点用新契约。
  - **验收（能失败）**：在 `sidecar/src` 按**标识符**扫描 `g_gateway`、`g_workspace`、`g_observed`、`g_call_seq`、18 个具名 `g_*_result`、`err_static` 全部零命中（不写 `static` 前缀，匿名命名空间里的旧声明也必须被检出）；搜索凭据、探针频道等**设计保留**的 `g_*` 不得出现在这份名单里。`spill_session` 在排除归档与本次工件后零命中；`tool_call_test.dart` 请求含正确句柄且无旧字段。

## 3. 全量验收与文档

- [ ] 3.1 C++ 全量：`cmake --build sidecar/build/windows --config Debug` 后运行 `sidecar_tests.exe` 与 `ctest --test-dir sidecar/build/windows -C Debug`。
  - **验收（能失败）**：贴真实输出，断言数不低于改动前 4369；同上下文并发、staging、销毁、FFI 环形缓冲或浏览器代次任何一条失败都不得跳过。
- [ ] 3.2 Dart 静态检查：`flutter analyze`。
  - **验收（能失败）**：问题总数与去行号差集不超出干净基线 173 条；新增接口的未实现方法、漏改调用点必须清零。
- [ ] 3.3 Dart 全量：先 `powershell -NoProfile -File scripts\sync_sidecar_dll.ps1`，再 `flutter test`。
  - **验收（能失败）**：贴 `All tests passed` 与实际用例数（基线 493，只能增加）；出现 `Failed to lookup symbol` 或接口未实现都算失败。
- [ ] 3.4 真 DLL 端到端：新增 `integration_test/context_handle_test.dart`，覆盖两个上下文与同一句柄并发 `run_command`、跨上下文 `read_spill` 拒绝、`乙/../甲` 拒绝、长命令中销毁、恢复会话后的工具调用；进程重启续号由任务 2.4 的 C++ 测试钩子覆盖，不在 Dart 层伪造重启。
  - **验收（能失败）**：断言每个输出、序号、旧引用内容与释放顺序；返回缓冲改回共享、允许跨目录读回、直接析构或恢复会话不 ensure 时对应场景红。打印每次句柄、序号、结果摘要与文件路径。
- [ ] 3.5 真桌面浏览器：新增 `integration_test/context_browser_test.dart`，用 `flutter test integration_test/context_browser_test.dart -d windows` 运行；两个上下文导航不同页面并读快照。死亡代次与并发启停已分别在任务 1.9 的 C++/Python 协议测试里覆盖，不在这一层重复注入。
  - **验收（能失败）**：两份快照 URL/标题不同；用 `desktop-screenshot` 的 OS 全屏截图留证并 `read_image` 验收，不用 Flutter `captureLiveShot` 代替。若两份页面相同，失败。
- [ ] 3.6 文档与接口说明：`sidecar_api.h` 写清 19 个改名、4 个不变、返回指针线程本地寿命、`context_poisoned` 与保留名；`Docs/user-guide/tools-command.md` 更新 spill 目录规则、序号续号与跨上下文读回限制，并放三列样例表（名字/目录名/说明，含中文、大小写、`..`）。
  - **验收（能失败）**：`test/unit/spill_config_test.dart` 解析文档样例表并逐行调用 `spillSessionDirName` 比对；改代码不改文档或改编码不改表格都红。文档不得再写「按会话 id 清理」或暗示可跨上下文读引用。
- [ ] 3.7 既有规范纠偏的守卫：为 `command-tool` / `tool-execution-tests` 的新条文补用例：`preview_chars=4000` 时允许整段超 8000 但引用必须在截断后的尾部；超时/非零退出码追加后引用仍可见；小输出写盘失败仍内联全文。
  - **验收（能失败）**：对应 `test/unit` 或 `test/integration` 用例在把引用移出尾部、恢复无条件「整段不超 8000」或让小输出失败时报错时红。
- [ ] 3.8 工件自检：proposal 的 Capabilities 与实际 delta 一一对应，所有 MODIFIED 标题与主规范逐字一致，ADDED 不要求主规范已有同名标题。
  - **验收（能失败）**：`openspec validate add-context-handles` valid；只取各 delta 的 MODIFIED 块，逐条确认主规范存在完全相同标题并贴输出；`openspec validate --specs` 仍为 54 passed / 0 failed。漏任一 delta 或标题不一致时失败。
