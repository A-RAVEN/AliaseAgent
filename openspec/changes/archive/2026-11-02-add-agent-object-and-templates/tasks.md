## 1. 实例生效配置与模板保存

- [x] 1.1 新增 `lib/models/resolved_agent_config.dart` 与 `lib/services/agent_config_resolver.dart`：从 `AgentTypeConfig` 解析不可变实例配置，集中处理模型、推理模式与强度、系统提示词、工具、上下文窗口、压缩参数、图片输入模态、命令超时和不可压缩要求；provider 密钥不进入可序列化快照。缺失、零或负窗口必须拒绝创建，不得按 0 继续发送。
  - **验收（能失败）**：新增 `test/unit/resolved_agent_config_test.dart`，覆盖合法/非法推理强度、非法窗口必须报错的模板名、模型编辑时当场确认窗口，以及 100 万 token 窗口 × 25% = 25 万 token 的压缩阈值；图片模态、命令超时和不可压缩要求在模板保存后仍保持创建时取值。把非法窗口改成静默全文发送或把这些字段改回注册表现读时用例红。
- [x] 1.2 扩展 `lib/services/agent_type_registry.dart` 支持添加与更新模板，新增 `lib/services/agent_template_controller.dart` 协调校验、更新 `AppConfig.agentTypes`、调用 `ConfigService.save` 并更新注册表；providers、search、spill 和未编辑的受支持字段原样保留，废弃键仍只告警不保留。
  - **验收（能失败）**：新增 `test/unit/agent_template_controller_test.dart` 并补充 `test/unit/config_service_test.dart`，覆盖添加、修改、空模板名、空模型、重复名、未知 provider、非法窗口，以及多 provider/搜索/spill/图片模态/命令超时/不可压缩要求/压缩参数的往返保存。这些字段复位成缺省值或运行实例被放进模板注册表时用例红。

- [x] 1.3 新增 `ToolCatalog` 作为唯一只读工具目录并由现有 `_toolDefs` 初始化与条件注册路径维护；未知工具显式报错，旧版两项默认工具清单可见迁移，自定义清单不变。`lib/ui/setup_dialog.dart` 的首启默认清单覆盖基础工具，首启与补问都合并现有 `AppConfig`，不整份覆盖。
  - **验收（能失败）**：新增 `test/unit/tool_catalog_test.dart` 覆盖未知工具报错与目录一致；新增 `test/integration/legacy_tool_migration_test.dart` 证明旧默认清单有提示地升级、自定义清单不变；更新 `test/widget/setup_dialog_test.dart`，证明补问后其它 provider、search、spill 与自定义模板均可读回。未知工具被静默过滤、旧清单静默减少或补问清空配置时用例红。

## 2. Agent 运行对象与会话接入

- [x] 2.1 新增 `lib/services/agent.dart`、`agent_factory.dart` 与 `agent_registry.dart`：Agent 持有句柄、实例生效配置、消息历史、请求与取消状态、计量和销毁状态；工厂确保上下文并注册实例。销毁先等本 Agent 的整轮 Future 与后台压缩写库，再调 `disposeContext` 排空桥内队列和 C++ 在途调用。同步增强 `test/integration/helpers/fake_sidecar.dart` 记录 `defaultWorkspace` 与 `setWorkspace` 路径。
  - **验收（能失败）**：新增 `test/integration/agent_registry_test.dart`，证明只在 `created:true` 时设置记录的缺省工作区、按句柄查找、整轮写库早于 `disposeContext`、其它实例不受影响；只调用 `disposeContext` 未等整轮、直接删注册表或假 sidecar 丢弃工作区时用例红。
- [x] 2.2 把 `lib/main.dart` 中模型—工具循环、摘要调用及其数据库写入迁入 Agent，`ChatScreen` 只保留会话与展示职责；模型、工具、摘要、取消和计量都显式使用本实例句柄与消息历史。
  - **验收（能失败）**：新增 `test/integration/agent_runtime_test.dart`，两个实例交替执行时请求、工具结果、摘要和消息写入仍各归各会话；界面切换不读取新 `_currentId`。现有 `test/integration/bridge_realtime_test.dart`、`context_handle_wiring_test.dart`、`delete_session_round_test.dart` 继续通过；只改调用名但执行仍由 `ChatScreen` 持有时用例红。
- [x] 2.3 Agent 按生效配置过滤 `ToolCatalog` 中的实际工具定义并传递模型、系统提示词和推理配置；配置含未知工具时创建失败并列名，不得静默少给。
  - **验收（能失败）**：新增 `test/integration/agent_tool_filter_test.dart`，请求只含模板允许的工具且模型/推理参数来自本实例；未知工具必须报错而不是消失，旧默认清单迁移后基础工具不减少，为 `general` 或条件注册工具静默绕过目录时用例红。
- [x] 2.4 新建和恢复会话都通过 AgentFactory 按 `Session.agentType` 解析模板；历史缺失字段仍默认 `general`，已存储但不存在模板时给可区分错误，不静默改用其它模板。
  - **验收（能失败）**：新增 `test/integration/agent_session_restore_test.dart`，覆盖非 `general` 恢复、历史缺省、缺失模板、非法窗口与新建默认；恢复后模型或推理配置落到 `general`、非法窗口静默全文发送时用例红。
- [x] 2.5 用真实 `SidecarBridge` 与本地 SSE 服务核验 Agent 到既有 FFI 的完整传递，不连接外部模型；保留按实例取消、计量和销毁行为。
  - **验收（能失败）**：新增 `test/integration/agent_runtime_real_bridge_test.dart`，从本地 SSE 请求体与回调核对模型、推理配置、系统提示词、工具和句柄；两个实例的请求区间、取消和计量不串；用带密钥的 provider 夹具捕获创建与发送日志并断言不含密钥。用 `FakeSidecar` 冒充桥内部、请求体仍含 `general` 配置或日志泄漏 `api_key` 时用例红。

## 3. 模板菜单与生效时机

- [x] 3.1 在 `lib/ui/session_sidebar.dart` 增加 `Agents` 入口，新增 `lib/ui/agent_template_menu.dart`，展示模板名、模型、推理强度及添加/修改入口；provider 密钥不显示。
  - **验收（能失败）**：新增 `test/widget/agent_template_menu_test.dart` 并更新 `test/widget/session_sidebar_test.dart`，覆盖列表、入口回调和无密钥展示；缺少任一已有模板或界面出现 `api_key` 值时用例红。
- [x] 3.2 新增 `lib/ui/agent_template_editor.dart`，模板名只在添加时填写、修改时只读，支持修改 provider、模型、推理强度、系统提示词、工具集合和上下文窗口；保存前校验并保留失败时的输入，第一版无删除、改名与实例覆盖入口。
  - **验收（能失败）**：新增 `test/widget/agent_template_editor_test.dart`，覆盖添加、修改、空模板名、空模型、重复名、未知 provider、非法窗口、未知工具与失败后输入保留；写坏配置、清空其它字段、出现删除按钮或允许修改被引用模板名时用例红。
- [x] 3.3 把菜单保存接到 `AgentTemplateController` 与模板注册表，接通之后创建/恢复实例的读取路径；运行实例继续使用创建时配置，界面与提示明确生效时机。
  - **验收（能失败）**：新增 `test/integration/agent_template_apply_test.dart`，证明保存后新实例使用新配置、既有实例的图片模态/命令超时/不可压缩要求/模型与推理配置均不变、完整配置可读回；若保存即热更新运行实例、只改界面未改注册表、未编辑字段复位或配置其它段丢失时用例红。

- [x] 3.4 把占用环的窗口分母改为产生当前 `ContextSnapshot` 的 Agent 实例生效配置，模板窗口后续修改不改变旧实例的环；同步 MODIFIED `context-occupancy-ring` 的「环的几何」与「不渲染环的两种情形」。
  - **验收（能失败）**：新增 `test/widget/context_ring_agent_config_test.dart` 并更新 `test/widget/context_view_test.dart`，证明模板窗口改小后旧实例仍用创建时窗口且不超 100%，新实例才用新窗口；非法窗口在创建时显式失败而不是只隐藏圆环。绘制时重新读取配置文件的窗口时用例红。

- [x] 3.5 **返工：Session 切换的持久化、实例退役与操作互斥**。扩展 `lib/services/session_repository.dart` 增加 `updateAgentType`，未更新到唯一既有行时显式失败；新增 `lib/services/agent_session_controller.dart`，接收界面回调并协调候选预检、重复切换拦截、旧 Agent 对象退役、持久化后重读 Session、新实例创建。`AgentFactory` 增加与创建路径共用规则的 `validateCandidate`，普通 `ensure` 对模板名不一致或正在退役的实例显式报错。新增不调用 `cancelRequest` / `disposeContext` 的退役路径：阻止新调用但让当前整轮与后台压缩写库自然结束，保留同 Session 的句柄、工作区、浏览器上下文、溢出文件及序号；删除进行中切换被拒绝，切换进行中删除等待结束后重读 Session。同步更新 `SessionRepository` 的现有测试替身。
  - **验收（能失败）**：新增 `test/unit/session_agent_controller_test.dart`，覆盖同名无需操作、合法顺序、界面回调传递、预检失败无副作用、重复切换、退役/写库/创建失败阶段与候选名、未找到 Session 不创建实例，以及退役不调用 `cancelRequest` / `disposeContext`；更新 `test/integration/agent_session_restore_test.dart` 证明 `ensure` 不复用不一致或退役中的实例，更新 `test/integration/delete_session_round_test.dart` 证明切换与删除互斥。只改 `agent_type` 仍返回旧实例、预检失败却退役旧实例、删除先于最后写库或新实例使用空回调时用例红。
- [x] 3.6 **返工：当前 Session 的可见切换入口、发送守卫与真实请求接线**。新增 `lib/ui/session_agent_switcher.dart`，在 `lib/main.dart` 当前会话工具栏显示并选择模板；工具未就绪、无当前会话或切换中时只禁用选择控件，无会话直接发送仍自动创建 `general`。扩展 `lib/ui/input_bar.dart` 让按钮和回车都服从切换状态，同时在 `_submitInput` 与 `_sendMessage` 数据层再次拦截。切换后更新界面 Session、保留聊天与工具输出、清除旧实例占用快照，新实例通过原界面回调显示新消息；其它 Session 不受影响。
  - **验收（能失败）**：新增 `test/widget/session_agent_switcher_test.dart` 覆盖当前值、模板列表、禁用和回调；新增 `test/integration/session_agent_switch_test.dart`，从界面往返切换并发送，核对数据库、实际模型/推理/系统提示词/工具、聊天区新消息、历史保留、旧 Agent 退役早于新实例创建、在途自然排空、旧快照清除、其它 Session 不变，以及无会话直接发送保持既有行为。分别注入退役、持久化、创建失败，断言界面显示阶段与候选名且选择框回读实际保存值；在切换中按回车、点发送和直接调用发送入口都必须被拒绝。用真实文件证明旧 `read_spill` 引用切换后仍可读且新文件不覆盖旧引用。只换文字仍发旧模型、空回调、失败无红条、历史或溢出文件丢失时用例红。

## 4. 文档与全量验收

- [x] 4.1 新增 `Docs/user-guide/agent-templates.md`，说明菜单位置、添加/修改、字段含义、错误和生效时机；更新 `Docs/user-guide/configuration.md` 删除“没有图形化设置界面”“只认 general”“首启只有两个文件工具”等过时说明，并在 `README.md` 功能索引加入口。
  - **验收（能失败）**：`test/unit/user_docs_test.dart` 通过；新增 `test/unit/agent_template_docs_test.dart` 比对文档中的 `Agents` 入口、模板名创建后不可改、未知工具与非法窗口错误、配置键和生效时机与产品代码，文档仍写只认 `general`、没有菜单、首启只有两项工具或索引缺文件时用例红。
- [x] 4.2 **返工：同步 Session 切换用户文档并删除错误的重开说明**。更新 `Docs/user-guide/agent-templates.md`，说明当前会话切换入口、旧 Agent 退役但保留上下文与溢出文件、历史保留、失败提示和重启恢复；明确删除“重新打开该会话就会使用新配置”的说法，区分仅在会话列表重开、重启重建实例与显式切换。更新 `Docs/user-guide/configuration.md` 实际存在的 `agent_types` 配置键说明及“把会话改到已有模板”路径，写明界面切换最终更新数据库 `sessions.agent_type`，不得寻找或改写不存在的“只读归属”句子。
  - **验收（能失败）**：更新 `test/unit/agent_template_docs_test.dart`，比对界面实际切换文案与两份文档，断言包含真实请求使用新模板、历史与溢出引用保留、失败可见、重启仍读新 `agent_type`，并断言不再出现“重新打开该会话（或新建会话）才会使用新配置”“重新打开它，或新建一个会话”；同时核对 `configuration.md` 的切换说明。文档只有模板管理、仍声称重开即重建或缺少数据库键说明时用例红。
- [x] 4.3 运行静态检查与完整 Dart 回归：先 `flutter analyze`，再 `powershell -NoProfile -File scripts\sync_sidecar_dll.ps1`，最后 `flutter test`；保留完整输出。
  - **验收（能失败）**：改动文件不得新增静态问题，完整测试必须出现 `All tests passed`，不得有 `Failed to lookup symbol`、未实现接口或新增失败；用局部测试代替全量不算通过。
- [x] 4.4 工件自检：proposal 的 Capabilities 与 delta 一一对应，MODIFIED 标题与主规范逐字一致，规范、design、tasks 不互相矛盾；新增 `test/unit/agent_change_artifact_test.dart` 逐条抽取本 change 的任务编号与其“新增 `test/...`”声称，核对文件真实存在且每项实现任务都有可执行测试。
  - **验收（能失败）**：`openspec validate add-agent-object-and-templates` 为 valid；`openspec validate --specs` 为 55 passed / 0 failed；逐条输出 MODIFIED 标题与主规范匹配结果；`agent_change_artifact_test.dart` 在任一 delta 缺失、标题不一致、任务点名的测试文件不存在或只提路径未建文件时失败。
- [x] 4.5 **返工：全量验收与可失败的工件自检**。按顺序重新运行 `flutter analyze`、`powershell -NoProfile -File scripts\sync_sidecar_dll.ps1`、完整 `flutter test`；更新并运行 `test/unit/agent_change_artifact_test.dart`，覆盖返工任务、测试文件以及 Session 切换规范的实质要求，再运行 change 与主规范校验。
  - **验收（能失败）**：本次改动文件不得新增静态问题；完整测试必须出现 `All tests passed` 且没有 `Failed to lookup symbol`；`openspec validate add-agent-object-and-templates` 为 valid，`openspec validate --specs` 为 55 passed / 0 failed。工件测试必须直接断言 `agent-runtime` 含「Session 切换模板必须替换运行实例」及发送/删除互斥、保留溢出引用、无会话发送保持、失败界面场景，`session-persistence` 含切换持久化与失败回读场景；删掉任一要求时用例红。缺返工测试文件、只做界面不接通实例替换或用局部测试代替全量同样失败。

### 返工工件对抗核验修订对照（2026-11-02）

- **失败界面**：改前只在控制器检查失败阶段，界面集成只测成功；改后在 3.6 注入退役、持久化、创建失败，检查红条、候选名与数据库回读。
- **新实例回调**：改前未规定回调；改后在 3.5 明确传入 `_callbacksFor`，3.6 断言新消息进入聊天区。
- **无会话发送**：改前“没有当前会话时禁用选择和发送”；改后只禁用选择控件，并保留自动创建 `general` 的回归用例。
- **发送数据层**：改前只写界面禁用；改后覆盖 `InputBar` 回车、按钮、`_submitInput` 与 `_sendMessage`，并在切换中逐路径测试。
- **切换与删除**：改前没有互斥要求；改后删除等待切换结束并重读 Session，未更新到唯一行不得创建新实例。
- **工具输出溢出文件**：改前切换完整销毁旧上下文；改后退役不调用 `cancelRequest` / `disposeContext`，保留句柄、工作区、溢出文件与序号，并用真实文件验收。
- **配置文档目标**：改前要求修改不存在的“`agent_type` 只读归属”；改后更新实际存在的 `agent_types` 行与“把会话改到已有模板”路径，说明数据库 `sessions.agent_type`。
- **重开文档**：改前未处理“重新打开该会话就会使用新配置”；改后明确删除两句错误说明并加入反向断言。
- **任务物理顺序**：改前 3.7 / 3.8 更新由 4.1 / 4.3 创建的文件；改后文档返工为 4.2，原全量与工件任务顺延为 4.3 / 4.4，最终返工验收为 4.5。
- **工件守卫**：改前只泛称“规范仍不要求 Session 切换时失败”；改后逐条断言切换标题与关键场景，删除要求会真的变红。
- **目标用词一致性**：改前 design 的 Goals 仍写“旧实例安全销毁”；改后写“旧 Agent 对象安全退役并保留同 Session 的上下文”，与决策 9 和溢出文件验收一致。
