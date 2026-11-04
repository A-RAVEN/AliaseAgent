# Tasks: add-provider-model-discovery

## 1. 外部事实源落档

- [x] 1.1 新建 `Docs/MagpieGatewayDoc.md`：来源仓库 `yetone/magpie`（含源文件完整 URL `https://github.com/yetone/magpie/blob/main/docs/reference.md` 与抓取时间 2026-11-04、README 来源 URL）、**两条实测模型条目的完整 JSON 原文**（2026-11-04 对本机 `http://127.0.0.1:3425/v1/models` 的真实响应中摘取 `kimi/kimi-for-coding` 与 `deepseek/deepseek-flash`，逐字照录）、三段字段语义英文原文及其在 reference.md 中的所在小节名（`native_endpoints` 的 "passed straight through … left out of a routing group"、`reasoning_levels` 的 "`[]` when there are none"、`pricing` 的 "left out when it isn't known"），并附 DeepSeek 兼容端点 `GET /anthropic/v1/models` 实测 404 的对照记录（请求与响应原文）。验收（能失败）：在该文档文件内 grep 命中 `1048576`、`video`、三段英文原文与 GitHub 源 URL 各行；JSON 样例经 `ConvertFrom-Json` 可解析。`flutter analyze` 不因文档改动新增问题。

## 2. 配置模型与解析（Dart）

- [x] 2.1 新建模型目录类 `lib/models/model_catalog_entry.dart`：字段 `id`/`displayName`/`contextWindow`（可空=窗口未知）/`maxOutputTokens`/`inputModalities`/`outputModalities`/`reasoningEfforts`（可空列表，空数组=无已知档位）/`nativeEndpoints`（可空=未知，不补空集合）/`pricing`（原样 Map 透传）；`fromJson` 按 design D5 逐条容错（缺字符串 `id` 丢弃该条并 `debugPrint` 点名原始 JSON）。
- [x] 2.2 `lib/models/provider_config.dart`：`ProviderConfig` 增加 `models`（`List<ModelCatalogEntry>`，缺省空）与 `discoveredAt`（`String?`），`fromJson`/`toJson` 写回两键使其在 config.json 可发现；`models` **非数组** → 整体按空目录处理并打一行日志点名原始值（非数组没有条目可逐条回落，与 agent-config delta 一致）；数组内缺字符串 `id` 的条目逐条丢弃。新增地址归一化函数 `normalizeBaseUrl`（仅剥尾随 `/` 与尾部路径段 `/v1`，循环至稳定，其余路径原样）。验收：`test/unit/provider_catalog_test.dart` 覆盖——旧配置无 `models`/`discovered_at` 读为空目录；`models` 写成对象/字符串时回落空目录且有日志；坏条目丢弃其余保留且有日志行；`http://127.0.0.1:3425/v1` 归一为 `http://127.0.0.1:3425`、`https://api.deepseek.com/anthropic` 逐字不变、尾斜杠 `https://x.example/` 剥净；该测试在无归一化函数实现时先红。
- [x] 2.3 全量回归本组：`flutter test test/unit`（含既有 `agent_config`/`config_service` 相关用例不回归）。

## 3. 探测服务

- [x] 3.1 新建 `lib/services/model_discovery_service.dart`：对归一化后的 base_url 发 `GET {base}/v1/models`，头 `x-api-key` 与 `anthropic-version: 2023-06-01`；`dart:io HttpClient` 连接超时与读超时均取 15 秒，代码注释写明出处（`sidecar/src/web_fetch.cpp` 的 `FETCH_CONNECT_TIMEOUT_SEC = 15L` / `FETCH_TIMEOUT_SEC = 15L`）；结果判别——非 200 → 携带状态码的失败；顶层非对象或 `data` 非数组 → "非标准目录"失败：把**完整原始响应**写入 `~/.aliasagent/logs/model_discovery_error_<UTC 时刻>.txt`，错误结果携带总字符数、按既有配置 `spill.preview_chars`（缺省 1000）截取的预览、"已略去 M 字符"与该文件路径（截断可见可恢复，不发明新长度）；成功 → `List<ModelCatalogEntry>` 加"丢弃 X"计数（缺字符串 `id` 的条目数）。密钥 MUST NOT 进入异常消息与日志。
- [x] 3.2 目录替换与计数：探测成功后整体替换该 Provider 的 `models` 并写 `discoveredAt`（UTC ISO 8601），产出"新增 N，更新 M，移除 K，丢弃 X"四类计数（按 `id` 对齐；**移除 K 只统计完整解析成功且本次不再出现的条目**，解析丢弃计入 X，两种原因不得混账）；失败返回旧目录原样的错误结果。写入经 `ConfigService.save`，其余配置段原样（复用 `copyWith`）。
- [x] 3.3 `test/integration/model_discovery_test.dart`：用 `dart:io HttpServer` 起本机随机端口假 magpie——成功路径断言落库条目与四类计数；401 路径断言状态码入错误且密钥不泄露；坏 JSON 路径断言旧目录保留、错误携带总字符数与"已略去 M 字符"、落盘的 `model_discovery_error_*.txt` 可读到与假服务端**逐字节相同**的完整响应、预览长度取自 `spill.preview_chars`；响应缺某模型断言"移除 1"；响应含一条缺 `id` 断言"丢弃 1"且该条**不**计入移除；探测写回后断言配置里 `version`、其它 Provider、`agent_types`、`search`、`spill` 段逐字节不变（MUST 保留的验收）。另加两条服务层守卫：假服务端记录请求计数——`ConfigService.load` + 界面初始化的路径上计数为 0（启动零探测）、"保存 Provider 后自动探测一次"路径计数恰为 1。该文件点名为 `test/integration` 层；假服务端缺陷仍在时断言必红。
- [x] 3.4 `flutter test test/integration/model_discovery_test.dart test/unit/provider_catalog_test.dart` 通过后跑全量 `flutter test`（先按 `scripts/sync_sidecar_dll.ps1` 刷新根目录 DLL），贴真实读数。

## 4. Providers 管理页

- [x] 4.1 新建 `lib/ui/providers_page.dart`：列表行显示名称、归一化后的 base_url、目录条数与 `discovered_at`（未探测显示"未探测"）、最近一次探测结果（成功显示"新增 N，更新 M，移除 K，丢弃 X"四类计数；失败显示"探测失败：<原因>"，非标准目录时含总字符数、略去数与完整响应文件路径）；支持添加/编辑（密钥输入不回显、列表不显示明文）/改名/删除。会话侧栏加 `Providers` 入口（与 `Agents` 并列）。
- [x] 4.2 引用完整性：改名在同一保存动作内改写所有引用旧名的模板 `provider` 字段并原子写回；删除前扫描 `agent_types` 引用，被引用则拒绝并在该行显示引用模板名列表。
- [x] 4.3 探测触发：每行"探测"按钮手动触发；新增/改名/改地址/改密钥保存成功后自动执行一次；两者共用 3.x 服务且失败都不回滚已保存配置、不清空旧目录。除此之外无任何自动触发（不新增定时器）。
- [x] 4.4 `test/widget/providers_page_test.dart`：假配置 + 注入假探测服务，断言——两 Provider 并行列出、改名后模板引用同步（读回配置）、被引用删除被拒且显示模板名、探测失败行内显示原因且旧目录条数不变、错误文本不含注入的密钥串。

## 5. 首启流程接入

- [x] 5.1 改造 `lib/ui/setup_dialog.dart` 为两步向导（design D8）：第一步 Provider 名字/地址/密钥（**首启默认名 `magpie`、默认地址 `http://127.0.0.1:3425`、默认密钥值 `magpie`，均可改——用户裁定 2026-11-04 推翻沿用旧默认 `anthropic`，原话「我以后打算使用magpie网关」「我的要求是magpie」「另外magpie的APIkey就叫magpie」；改前判据=同名用例断言默认 `anthropic`，改后=断言默认三件套 `magpie`/`http://127.0.0.1:3425`/`magpie`，加严不放松**；补问时沿用"写回 general 实际在用的 provider"的既有合并逻辑），第二步**保留现有"上下文窗口必填正整数"输入与校验原样**（不许删既有窗口断言——补问就是靠它拦截，砍掉对话框会反复弹出）；整向导完成前不可关闭（`barrierDismissible: false` 语义延续）。校验：空密钥拒绝、名字空/重名拒绝、base URL 必须是绝对 http(s) URL（非法时点名该字段、不落盘）、窗口非正整数拒绝，失败均保留其它输入。保存写 `providers.<提交名>`（归一化 base_url）与 `general.max_context_tokens`，其余配置段合并保留，然后 `onComplete`。既有 `test/widget` 首启用例（Setup dialog renders/validates/creates/non-dismissible）按 delta 场景更新为同名新断言并新增"非法 URL 拒绝""两步都过才 onComplete""首启默认名/地址/密钥为 magpie、127.0.0.1:3425、magpie"三条，不许删用例。`Docs/user-guide/configuration.md` 与 `provider-models.md` 中涉及首启默认键名的句子同步改。（本条因用户裁定回退重做，勾选时须附默认值断言的测试读数。）

## 6. 模板编辑器

- [x] 6.1 `lib/ui/agent_template_editor.dart`：provider 下拉**选项已是全部键名**（L219 遍历 `widget.providers`，与规范相符，勿当缺陷改）；本期只需把模型字段改为"目录下拉（`display_name` 显示、`id` 为值）+ 自由输入"双通道，手输目录外模型保存不被拒绝、可显示"不在最近一次目录中"的中性提示。选中模型联动其 provider 的目录（切换 provider 后模型下拉重新取该 Provider 目录）。新增模板时默认选中 `providers.first` 的行为保留（对抗审查发现：删掉它会让新模板 provider 为空、被"provider 未定义"校验拒绝——默认值是防错设计不是缺陷），但补一条断言：providers 为空列表时编辑器显示"请先在 Providers 页添加供应商"并禁用保存。
- [x] 6.2 选定目录内模型时回填三框：`max_context_tokens`←`contextWindow`（窗口未知留空并显示"目录未提供窗口，请手填（压缩阈值依赖它）"）；`input_modalities`←与 `text`/`image` 的交集（交集空回落 `text`，日志点名略去的原值）；`thinking_effort` 下拉选项←`reasoningEfforts` 与既有合法集合（`low`/`medium`/`high`/`xhigh`/`max`）的**交集**，目录 `none` 档映射为"留空"（既有语义 absent = 不思考），交集外的目录档位不消失——编辑器显示一行"目录档位 X 暂不被执行层支持，未列入"；目录空/未知时保留手填。既有"推理强度属于既有合法集合"的保存校验**原样保留**（delta 与它不再矛盾：选项=目录∩合法集，校验=合法集）。`nativeEndpoints`/`pricing` 仅在该模型带值时显示为说明文字，MUST NOT 参与可用性判断或拦截。
- [x] 6.3 保存校验扩展：模板 `input_modalities` 写回值仍只允许 `text`/`image` 子集（目录含 `video` 被回填时剔除并日志可见）；其余既有校验（正整数窗口、非空模型、已注册工具、provider 已定义）原样保留。
- [x] 6.4 `test/widget/template_editor_catalog_test.dart`：假目录（含 `video` 条目、"窗口未知"条目、无 `native_endpoints` 条目）注入——选模型断言预填 1048576、模态勾选不含 `video` 且日志有略去行、无 `native_endpoints` 条目仍可选、provider 下拉列两条、手输目录外模型保存成功。

## 7. 真机与全量验证

- [x] 7.1 `integration_test/provider_discovery_live_test.dart`（`@Tags(['live'])`，`-d windows`）：真连 magpie 网关 `http://127.0.0.1:3425`——探测成功、目录含 `deepseek/deepseek-flash` 且 `contextWindow == 1048576`、其 `modalities.input` 含 `image`、`kimi/kimi-for-coding` 的 `input` 含 `video` 且模板回填不含 `video`；断言前打印实际目录条目与回填值；截图存 `test/live_visual/provider_discovery.png` 并 `read_image` 验收。跳过条款收紧（对抗审查：跳过通道会让 1048576 与 video 永不被核）：**只有网关进程确认未运行**（连接被拒且 `magpie-windows-amd64.exe` 不在进程表）才允许跳过，跳过时测试输出必须打印"SKIPPED: 网关未运行"并在 9.1 收尾报告如实披露——跳过**不等于**验证通过，1.1 落档的 JSON 样例是数字的第二出处；HTTP 非 200、解析失败、断言不符必须红。
- [x] 7.2 `flutter test test/integration/model_discovery_test.dart` 与 `test/unit/provider_catalog_test.dart`、`test/widget/providers_page_test.dart`、`test/widget/template_editor_catalog_test.dart` 先跑通，贴真实读数（全量留到 9.1）。

## 8. 文档同步

- [x] 8.1 新建 `Docs/user-guide/provider-models.md`：Providers 页在哪、怎么增删改改名、探测按钮与状态含义（含"新增/更新/移除/丢弃"四类计数各指什么）、模板选模型与三个回填规则（含 `none` 档=留空、执行层不支持档位的显示方式）、目录外手输、探测失败会看到什么（状态码、截断标记与完整响应文件路径怎么读）、改名与删除引用的行为、已知限制（仅 magpie 标准方言、目录不自动刷新、`video` 收不了）。验收（能失败）：文档内 grep 命中界面实际文案词（`Providers`、"探测"、"未探测"、"新增"、"丢弃"）且"已知限制"三条（magpie 方言/不自动刷新/video）逐条在。
- [x] 8.2 `Docs/user-guide/configuration.md` 配置键表补 `providers.<名>.models` 与 `discovered_at`；`Docs/user-guide/agent-templates.md` 同步改被本 change 触及的段落（模型字段现为目录选取+手输、档位选项来源、"界面不显示密钥"仍在、新增 Providers 页指引一句）；`README.md` 功能文档索引加 provider-models 条目。
- [x] 8.3 文档守卫：`test/unit/user_docs_test.dart` 现有"文档键 ↔ 代码解析路径"检查覆盖 `models`/`discovered_at`（代码 `ProviderConfig.fromJson` 真读这两键，文档 json 块样例与之对齐）；新增 `test/unit/provider_docs_test.dart` 断言——8.1 与 8.2 两份文档中出现的界面词（`Providers`、"探测"、"未探测"、"目录未提供窗口"、"请先在 Providers 页添加供应商"）与产品代码文案 grep 逐词一致，文档缺任一词或用词不符即红。

## 9. 最终全量（文档与守卫落定之后，最终树整跑一次）

- [x] 9.1 在**含全部代码与文档的最终树**上跑：`flutter analyze`（不新增问题）+ 先 `scripts/sync_sidecar_dll.ps1` 刷新根目录 DLL 再全量 `flutter test` + `flutter test --tags live --run-skipped integration_test/provider_discovery_live_test.dart -d windows`（跑前用进程表确认 `magpie-windows-amd64.exe` 在运行——live 非跳过是本 change 的完成条件之一，若网关确实未运行，跳过必须逐字贴进收尾报告并如实标注"1048576/video 未经真机核对"）。贴三组真实读数与截图 `read_image` 验收结果。C++ 侧无改动故 ctest 不重跑，如实现触碰 `sidecar/` 则必须重跑并贴输出。
