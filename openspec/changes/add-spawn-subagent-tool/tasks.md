## 1. 按上下文读取工作区

- [x] 1.1 在 `sidecar/include/sidecar_api.h`、`sidecar/src/sidecar_api.cpp`、`sidecar/src/context_api.h` 与 `sidecar/src/context_api.cpp` 增加 `get_workspace(handle)`，使用既有线程本地结果缓冲返回成功 JSON 或 `unknown_context`，不隐式创建上下文、不修改任何上下文状态。在 `sidecar/test/context_lifecycle_test.cpp` 与 `sidecar/test/context_ownership_test.cpp` 覆盖双上下文不同工作区、未知/已销毁句柄、空工作区和查询前后 spill 序号不变。验收：`cmake --build sidecar/build/windows --config Debug` 后运行 `& sidecar/build/windows/Debug/sidecar_tests.exe "[context]"`，直接按 Catch2 的 `[context]` 标签执行，输出必须给出实际运行的测试用例与断言数；新增断言在返回固定主目录或固定空串时必须失败。不得改用 `ctest -R context`，因为已注册测试名是 `sidecar_tests`，该过滤匹配不到任何用例。

- [x] 1.2 在 `lib/services/sidecar_bridge.dart` 的 `ISidecar` 与 `SidecarBridge` 增加 `getWorkspace`，解析并立即复制 `get_workspace` 返回值；把原始 JSON 解析放入生产与测试共用的可独立测试入口。同步更新 `test/integration/helpers/fake_sidecar.dart`，使假 sidecar 能按句柄记录查询并返回不同工作区。扩展 `test/unit/sidecar_bridge_test.dart`，真实 DLL 覆盖成功、未知句柄和句柄透传，共用解析入口覆盖非 JSON。验收：先运行 `powershell -NoProfile -File scripts/sync_sidecar_dll.ps1` 刷新仓库根 DLL，再运行 `flutter test test/unit/sidecar_bridge_test.dart test/integration/agent_runtime_test.dart`；把桥实现改成读取错误句柄、吞掉 `unknown_context` 或对非 JSON 返回成功时相关用例必须失败。

## 2. 子运行记录与会话迁移

- [x] 2.1 在 `lib/models/session.dart`、`lib/services/session_repository.dart` 与 `lib/services/database_service.dart` 增加可空 `parent_session_id`，数据库版本从 7 升到 8；新建与升级路径同时加列，保留所有旧行。扩展 `test/integration/schema_migration_test.dart`，用真实版本 7 数据库预置会话、消息、摘要与附件后升级。验收：`flutter test test/integration/schema_migration_test.dart`，断言旧数据数量和内容不变、旧会话父 id 为 `NULL`、新子记录父 id 正确；漏写 `_onCreate` 或 `_onUpgrade` 任一处时对应场景必须失败。

- [x] 2.2 在 `SessionRepository` 增加按父 id 查询子记录的只读入口，把普通 `list` 改为只返回顶层会话；确认父会话删除会实际删除子记录及其消息、摘要，若真实 SQLite 证明外键未生效，则在同一任务修正连接配置并覆盖既有删除行为。扩展 `test/integration/schema_migration_test.dart` 与 `test/integration/delete_session_round_test.dart`，直接通过真实 `SessionRepository.list` 验证父子过滤和排序。验收：`flutter test test/integration/schema_migration_test.dart test/integration/delete_session_round_test.dart`，把 `list` 改回无 `parent_session_id` 过滤时真实仓库用例必须失败；直接查询数据库行数验证父子数据确实删除且其它会话不受影响，不能只断言外键文本存在。

- [x] 2.3 让启动恢复继续只遍历顶层会话，子记录不出现在侧栏、不自动创建运行 Agent。新建 `test/integration/subagent_session_restore_test.dart`，用真实 SQLite `SessionRepository` 预置父子会话，实际 `pumpWidget` 启动 `ChatScreen`，检查真实列表、侧栏和 `AgentRegistry`；不得用直传列表的纯 `SessionSidebar` 用例或只调用工厂的用例冒充启动验收。验收：`flutter test test/integration/subagent_session_restore_test.dart`，恢复成旧版“列出全部 sessions”时子标题和子句柄必须使该用例失败，父会话仍按自己的模板恢复。

## 3. Agent 结构化运行结果

- [x] 3.1 在 `lib/services/agent.dart` 增加不可变 `AgentRunResult` 与计量快照，将 `Agent.send` 改为返回完成、失败、取消、实例忙四类结果；最终文本只由无工具调用的最终模型轮产生，未预期异常进入失败结果，现有界面消息和错误写库不得重复。新建 `test/integration/agent_run_result_test.dart`，覆盖中间工具轮后成功、模型错误、取消、空最终文本、忙实例和未预期异常。验收：`flutter test test/integration/agent_run_result_test.dart`，用假 sidecar 输出的独特文本断言每个来源，改成读取最后一条历史消息或把错误当成功时用例必须失败。

- [x] 3.2 核对 `lib/main.dart` 与既有 Agent 调用点对返回值的兼容性，普通会话仍只产生原有用户/助手消息和事件。扩展 `test/integration/agent_runtime_test.dart` 与 `test/integration/session_agent_switch_test.dart` 覆盖普通发送和模板切换中的自然结束。验收：`flutter test test/integration/agent_runtime_test.dart test/integration/session_agent_switch_test.dart`，统计消息行和回调事件，出现重复错误消息或切换提前取消时失败。

## 4. 工具目录、默认迁移与子运行核心

- [x] 4.1 在 `lib/main.dart` 注册 `spawn_subagent` 定义与输入 schema，在 `lib/services/tool_catalog.dart` 加入首启基础工具；既有十项和其它自定义模板不自动添加，旧两项首启迁移继续升级到当前清单。更新 `test/unit/tool_catalog_test.dart`、`test/integration/startup_tool_readiness_test.dart`、`test/integration/legacy_tool_migration_test.dart`、`test/integration/agent_tool_filter_test.dart` 和 `test/widget/agent_template_editor_test.dart`，专门覆盖“用户删除后恰好呈旧十项形状，重新加载仍保持删除”。验收：`flutter test test/unit/tool_catalog_test.dart test/integration/startup_tool_readiness_test.dart test/integration/legacy_tool_migration_test.dart test/integration/agent_tool_filter_test.dart test/widget/agent_template_editor_test.dart`，断言首启与就绪清单包含新工具、既有模板不被覆盖、编辑器显式添加/移除生效且密钥不进入提示。判据对照：改前 `tool_catalog_test` 钉死 10 项、`startup_tool_readiness_test` 钉死未就绪 10 项和完整 12 项；改后按新增一个基础工具更新为 11 项与 13 项并增加 `spawn_subagent` 内容断言，依据是本 change 明确增加首启工具，未降低其它工具与动态工具的就绪检查。

- [x] 4.2 新建 `lib/services/subagent_runner.dart`，并在 `lib/services/agent_factory.dart`、`lib/models/resolved_agent_config.dart`、`lib/services/agent.dart` 与 `lib/main.dart` 接入延迟运行器回调和子实例创建参数。实现任务/模板校验、父工作区读取、子会话创建、无界面回调创建、子角色说明和子工具清单排除 `spawn_subagent`。新建 `test/unit/subagent_runner_test.dart`，覆盖空任务、非法模板、工作区读取失败均无子会话/上下文，缺省继承父模板，子实例冻结配置且父模板与父实例不被改写。验收：`flutter test test/unit/subagent_runner_test.dart`，逐项核对副作用计数和实际配置，而非只检查返回文本。

- [x] 4.3 新建 `test/integration/subagent_tool_test.dart`，用假 sidecar 驱动真实父子模型—工具循环：父模型调用 `spawn_subagent`，子模型执行工具后给出结论，父模型收到工具结果再继续。实现并验证独立子历史、父工作区继承、无父界面回调、无嵌套工具、指定模板模型/推理强度和最终回复来源。验收：`flutter test test/integration/subagent_tool_test.dart`，父后续请求必须含最终结论且不含子中间消息/思考/工具独特标记，子首次请求必须不含父历史；任一标记串用时失败。

- [x] 4.4 完成同步成功结果与错误映射：返回 `child_session_id`、实际模板、模型和子计量，在 `lib/models/tool_call_activity.dart` 与父 `toolCallsJson` 持久化这些不含密钥的元数据，但父模型内容仍只有结论；模型失败、取消、空回复、实例忙和未预期异常均返回可区分 `ok:false`。修改 `Agent._buildApiMessages`，仅对 `spawn_subagent` 的历史结果跳过通用 `elideOversizedToolResult`，其它工具规则不变。在 `test/integration/subagent_tool_test.dart` 增加对应端到端用例，在断言前打印工具输入、结果和父子请求记录；在 `test/unit/tool_call_activity_test.dart` 覆盖元数据序列化往返。验收：`flutter test test/integration/subagent_tool_test.dart test/unit/tool_call_activity_test.dart test/integration/tool_result_elision_test.dart`，直接读取父记录断言元数据；用超过既有通用阈值的结论逐字比较即时结果、父再次发送和从数据库恢复后的重建请求，出现通用省略标记或丢失元数据时失败，其它工具的超长结果仍按原规则省略。

## 5. 取消、销毁与资源边界

- [x] 5.1 在子运行服务登记父子活动关系，接通子单独取消、父 `cancel`/`dispose` 先取消子、父 `retire` 不取消在途子调用；所有出口经 `finally` 等待子整轮、销毁子上下文、移除实例并解除关系，同时保留子数据库记录。新建 `test/integration/subagent_lifecycle_test.dart`，覆盖子单独取消、父取消、父销毁、模板切换、清理失败和成功后的记录保留。验收：`flutter test test/integration/subagent_lifecycle_test.dart`，用事件日志断言取消与销毁顺序、活动关系清空、父 `retire` 期间零取消调用；清理失败不得返回成功。

- [x] 5.2 验证父会话删除和应用销毁都经过父子取消与清理，不只取消父句柄；扩展 `test/integration/delete_session_round_test.dart` 与 `test/integration/subagent_lifecycle_test.dart`，同时观察另一个无父子关系的 Agent。验收：`flutter test test/integration/delete_session_round_test.dart test/integration/subagent_lifecycle_test.dart`，父子上下文均在删库/销毁前完成最后一次写库，另一个 Agent 的请求、消息和上下文保持不动。

- [x] 5.3 新建 `test/integration/subagent_spill_preservation_test.dart`，使用真实 sidecar 与临时工作区让父子各产生 spill，子结束后验证子上下文资源按契约清理，父引用仍可读且父后续输出不覆盖旧文件。验收：先按项目入口同步最新 `sidecar.dll`，再运行 `flutter test test/integration/subagent_spill_preservation_test.dart`；断言真实文件内容、父 `read_spill` 结果和父子序号，删除父文件或跨句柄读取子引用时必须失败。

## 6. 父会话界面行为

- [x] 6.1 复用现有工具卡片展示 `spawn_subagent` 的任务、可选模板、等待状态、最终结论或错误，不为子中间流式事件创建父聊天项，也不提供子记录普通聊天入口。扩展 `test/widget/tool_call_card_test.dart`，并在 `test/integration/subagent_tool_test.dart` 核对父回调只收到父自己的事件；子记录过滤与启动恢复由任务 2.2、2.3 的真实仓库和 `ChatScreen` 用例负责，不用纯展示侧栏用例代替。验收：`flutter test test/widget/tool_call_card_test.dart test/integration/subagent_tool_test.dart`，卡片须显示完整结论/错误，子独特流式文本或子中间事件进入父回调时测试失败。

## 7. 用户文档与真实模型验收

- [x] 7.1 新建 `Docs/user-guide/agent-subagents.md`，说明如何在 Agents 菜单配置 `spawn_subagent`、任务与可选模板参数、同步等待、独立历史、工作区继承、最终结论回传、取消行为、不能嵌套、无并行/异步消息、子记录不在侧栏且第一版无详情界面，以及子 spill 引用不可作为最终交付。更新 `Docs/user-guide/agent-templates.md`、`Docs/user-guide/configuration.md` 和 `README.md` 功能索引。新建 `test/unit/subagent_docs_test.dart`，逐项比对文档中的工具名、菜单名、配置行为与 `lib/main.dart`/模板编辑器实际文案；解析 `configuration.md` 首启示例的 `tools` 数组，与 `ToolCatalog.kBaseToolNames` 逐项比对，并检查 `configuration.md` 与 `agent-templates.md` 的数量说明不再写“十项基础工具”。验收：`flutter test test/unit/subagent_docs_test.dart test/unit/user_docs_test.dart`，文档保留旧十项数组或数量、缺少 `spawn_subagent`、声称既有十项会自动迁移、声称支持嵌套或详情界面、或界面文案不一致时测试失败。

- [ ] 7.2 新建 `integration_test/subagent_live_test.dart`，用真实 `AppShell`、独立临时数据库和 `ConfigService.load()` 解析出的真实 provider，配置含 `spawn_subagent` 的父模板与不含该工具的子模板。让真实父模型必须创建子 Agent，真实子模型返回本次运行的独特结论；复用 `integration_test/live_observability.dart`，在断言前输出实际工具名、完整输入、状态、结果、最终回复、实际上下文和父子数据库记录。断言父工具卡为已完成的 `spawn_subagent`、结果含独特结论与子运行元数据、子记录关联父会话、父历史不含子中间消息；模型不调用工具、调用错误模板、子运行失败或结论缺失都必须失败，只有配置不完整或已确认的接口/网络错误允许按既有 live 规则跳过。所有出口用 `captureLiveShot` 保留 `test/live_visual/subagent_live.png`。验收：运行 `flutter test --tags live --run-skipped integration_test/subagent_live_test.dart -d windows`，不得发生非环境原因跳过；主循环随后用 `read_image` 读取本次新截图，确认工具结果与最终回复可见，不能用 `All tests passed` 或 `run.bat` 启动代替视觉验收。

## 8. 全量验证与工件核对

- [x] 8.1 运行 `flutter analyze` 与本 change 点名的全部聚焦测试，保存完整输出；改动文件不得新增静态问题，所有新增用例必须先证明在对应缺陷仍存在时会失败。验收：逐项对照任务中的测试文件和真实通过数量，任何未运行、跳过或只凭代码阅读声称覆盖的场景都视为未完成。

- [x] 8.2 通过 `powershell -NoProfile -File scripts/sync_sidecar_dll.ps1` 刷新仓库根 DLL 后运行完整 `flutter test`，并运行 `cmake --build sidecar/build/windows --config Debug` 与 `ctest --test-dir sidecar/build/windows -C Debug --output-on-failure`。验收：保留完整日志和实际通过/失败数量；本次新增或修改行为对应测试不得跳过，任何失败都必须定位并修复后重跑。

- [x] 8.3 运行项目入口 `run.bat` 完成它实际提供的五步：Flutter 构建、构建产物检查、刷新根目录 DLL、`test/unit/sidecar_bridge_test.dart` 冒烟和启动应用；静态分析与完整测试分别由任务 8.1、8.2 负责，不把该入口不提供的检查点或视觉回归写成它的输出。随后运行 `openspec validate add-spawn-subagent-tool --strict` 和 `openspec status --change add-spawn-subagent-tool`。验收：`run.bat` 五个实际步骤都有真实输出并核到应用进程；OpenSpec 校验为 valid、所有规范场景可定位到本清单至少一条测试任务，且本文件不存在未勾条目后才算完成。
