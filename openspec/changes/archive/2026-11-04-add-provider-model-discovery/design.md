# Design: add-provider-model-discovery

## Context

配置文件的既有结构（实测核对）：`AppConfig.providers` 是"名字 → `{api_key, base_url}`"的多条目映射，`agent_types.<名>.provider` 按名字引用；C++ 执行库把对话请求拼成 `base_url + "/v1/messages"`（`sidecar/src/model_gateway.cpp`）。界面层缺口（2026-11-04 对抗审查后按代码核实修正）：`lib/ui/setup_dialog.dart` 首启把供应商键名写死为 `anthropic`（L78），除此之外**没有任何日常维护 Provider 的入口**（改第二条的地址/密钥只能手改 JSON）；模板编辑器的 provider 下拉选项其实已是全部键名（`agent_template_editor.dart` L219 遍历 `widget.providers`），`providers.first` 只是新增模板时的默认选中值（L69）——缺口在"无处管理 Provider"，不在"下拉只有一条"。

外部事实（2026-11-04 实测，来源 `yetone/magpie` 本机网关与其 `docs/reference.md`）：

- magpie 网关 `GET /v1/models` 免鉴权可达，Anthropic 头（`x-api-key` + `anthropic-version`）也通；返回 `{data:[...]}`，每个模型含 `id`、`display_name`、`context_window`、`max_output_tokens`、`modalities.{input,output}`、`supported_reasoning_levels[].effort`、`reasoning_levels`（纯名数组，无已知档位时为 `[]`）、`native_endpoints`（文档原文：标"哪些协议路径原生直通"，路由组与"全翻译模型"整个省略该字段）、`pricing`（未知整个省略）。
- 对照网关 DeepSeek 方言不同（平铺 `input_modalities`、`effort.supported_levels`），且其 Anthropic 兼容端点 `GET /v1/models` 实测 404。用户已裁定：**以 magpie 为事实标准做探测**，其他方言不在本期适配。
- 窗口与档位在 magpie 侧有四级回落（模型 → provider 通配 → 上游列表 → models.dev），且窗口数值被 magpie 自己用于路由决策——目录值是网关运行参数的同源数，可信度高于用户手打。

约束：压缩阈值规则是用户钉死的"窗口 × 百分比"推导，本设计只改"窗口数从哪来"，不碰推导规则；产品是零审批全权限设计，探测失败不弹窗求确认、界面内如实报错即可。

## Goals / Non-Goals

**Goals:**

- Provider 成为可增删改的一等对象，模板编辑器面对真实的 Provider 列表。
- 一个命令式的"探测"动作把网关的模型元数据取回、解析、持久化，并让模板字段以目录值回填默认。
- 探测与解析的每一种失败形态都有可见、不静默的去处（界面原因显示 + 旧目录保留 + 回落打日志）。

**Non-Goals:**

- 不做定时/后台自动刷新（只有手动按钮与保存 Provider 时自动探测各一次）。
- 不做 DeepSeek/OpenAI 方言适配；目录缺失的网关就用手填老路。
- 不让目录值在运行时参与任何推导——模板存的显式值继续是唯一执行真相（压缩、发图判断读模板字段，不读目录）。
- 不做计费功能（`pricing` 仅录入展示）；不用 `native_endpoints` 拦截模型。
- 不迁移既有配置去自动探测（启动时零网络请求）。

## Decisions

### D1 探测放 Dart 侧，不进 C++ 执行库

目录的全部消费者是配置解析与模板编辑器（都在 Dart）；C++ 执行库只需要模板里那根 `model` 字符串，无需知道目录存在。备选（FFI 到 C++ 复用 curl）被否：要给 `sidecar_interface` 加导出、假库同步加接口，成本花在一个纯配置态读取上。探测用 `dart:io` HttpClient，超时对齐产品既有对外 HTTP 数值：读 15 秒（`FETCH_TIMEOUT_SEC`）、连接 15 秒（`FETCH_CONNECT_TIMEOUT_SEC`），两者出处 `sidecar/src/web_fetch.cpp`——不发明新数。

### D2 探测 URL 与对话 URL 拼接同源：`{规范化 base_url}/v1/models`

规范化规则只有一条：**存储时剥掉用户输入尾部的 `/v1`（及尾随 `/`）**。真实踩点：用户给 magpie 地址习惯写 `http://127.0.0.1:3425/v1`，而对话拼接是 `base_url + "/v1/messages"`，不剥会变成 `/v1/v1/messages`。除此之外路径原样保留（DeepSeek 的 `https://api.deepseek.com/anthropic` 尾部不是 `/v1`，不受影响）。探测与对话共用规范化后的存储值，两条拼接互推自同一规则。

### D3 目录存 config.json（`providers.<名>.models` + `discovered_at`），不进 SQLite

config.json 是配置事实的唯一载体（`ConfigService.load()` 全产品统一入口），目录本质是"网关元数据的配置快照"；SQLite 会话库按既有规范只承载对话态。向后兼容：`models`/`discovered_at` 缺失即空目录 + 从未探测，不写迁移代码。`discovered_at` 存 ISO 8601 时刻（Dart `DateTime.now().toUtc().toIso8601String()`），界面显示"目录取自 …"。

### D4 回填是编辑器动作，不是运行时引用

模板编辑器中选定目录内某模型 → `max_context_tokens`/`input_modalities`/`thinking_effort` 三个输入框以目录值预填；用户可改，保存后**模板字段为唯一执行真相**。目录后续刷新不回改已保存模板（隐式改配置是静默降级，违反"砍内容必须可见"原则）。备选"运行时引用目录"被否：会造出第二条真相路径，且手填模板、无目录网关全部要特判。

### D5 字段残缺语义按 magpie 文档，逐项回落不整体作废

- `context_window` 缺失或非正整数 → 该条目录记为"窗口未知"，编辑器回填留空并显示"目录未提供窗口，请手填（压缩阈值依赖它）"。
- `supported_reasoning_levels` 为 `[]` → 合法语义"无已知档位"（文档原文 "`[]` when there are none"），编辑器该框留空手填；不视为解析失败。
- `modalities.input` 含 `video` 等产品发不出的取值 → 目录照录原值（可见），回填进模板时过滤为 `text`/`image` 交集，交集为空回落 `text` 并打日志点名略去了什么（可见 + 可恢复：目录里原值仍在）。
- `native_endpoints`/`pricing` 未知 → 整个省略，界面不显示徽章；已知 → 仅展示。
- 单条模型记录缺 `id` 或 `id` 非字符串 → 丢弃该条并打日志点名原始 JSON；其余条目不受影响（逐条容错，不搞一份坏全废）。被丢弃条目**不计入"移除"**，单独计为"丢弃 X"并在界面显示（对抗审查发现：混入移除会把解析失败显示成网关下架，失败原因正好相反）。
- 响应顶层不是 `{data:[...]}` 或 `data` 非数组 → 判为"该端点不是 magpie 标准目录"，本次结果整体作废、旧目录保留。错误展示遵守"砍多少看得见、看得见取得回"：完整原始响应写入 `~/.aliasagent/logs/model_discovery_error_<UTC 时刻>.txt`，界面显示"共 N 字符，已略去 M 字符，完整内容见 <路径>"，预览长度取产品既有配置项 `spill.preview_chars`（缺省 1000，用户 2026-10-25 定的头尾预览长度；不发明新数）。

### D6 失败与状态都在界面内显示，不弹窗

探测失败（连接拒绝 / 超时 / 401 / 404 / 非标准 JSON）→ Provider 编辑区显示"探测失败：<具体原因>"（含 HTTP 状态码；非标准 JSON 时按 D5 的截断可见可恢复规则显示预览与取回路径），旧目录与 `discovered_at` 原样保留；成功 → 显示"新增 N，更新 M，移除 K，丢弃 X"四类计数（解析丢弃与网关下架分账，见 D5）。备选"失败清空目录"被否：网关重启瞬时不可达不该毁掉离线可用的快照。

### D7 鉴权头照对话请求，不新增鉴权模式

`x-api-key: {api_key}` + `anthropic-version: 2023-06-01`（与 C++ 对话请求同源的两个头）。密钥经 http 明文发送的风险：magpie 默认只监听 127.0.0.1（实测监听地址可查），与对话请求同一信任边界，不额外加"http 拦截"护栏——产品是零审批全权限设计，护栏不得挡住用户明确要连的本地网关。

### D8 界面：新增常驻「Providers」管理页；首启流程改为两步向导

现状核实（对抗审查后按代码修正）：`SetupDialog` 不止密钥一个输入——它含 **API 密钥 + 上下文窗口（正整数必填）** 两个输入框（`setup_dialog.dart` L31-L32），且承担两类触发：无配置时的首启、`general.max_context_tokens` 缺失时的补问（`existingConfig` 非空路径，L13-L17 注释与 `_mergeConfig` L73-L97：补问只替换密钥与窗口、合并保留其余配置段）。窗口是**模板字段**不是 Provider 字段，故拆分如下：

- 新增会话侧栏 `Providers` 入口（与模板菜单 `Agents` 并列）的管理页：列表（名字、地址、目录条数与 `discovered_at`）+ 增/改/改名/删 + 逐条"探测"按钮。此页只谈 Provider 三要素（名字/地址/密钥），不含窗口字段。
- 首启与补问改为**两步向导**：第一步 = 内嵌上述 Provider 编辑表单（**首启默认键名 `magpie`、默认地址 `http://127.0.0.1:3425`、默认密钥值 `magpie`，均可改**——用户裁定 2026-11-04 原话「我以后打算使用magpie网关」「我的要求是magpie」「另外magpie的APIkey就叫magpie」，推翻沿用旧默认 `anthropic` 的做法；密钥默认值与 magpie 网关约定一致，该网关实测免鉴权也通；补问时跳到第一步的密钥步——沿用现有"写回它实际在用的 provider"逻辑）；第二步 = 现有的上下文窗口必填步（正整数校验、合并写回 `general.max_context_tokens`，既有 `test/widget` 首启/补问用例的窗口断言**原样保留不删**）。"提交成功前不可关闭"（`barrierDismissible: false`）语义覆盖整条向导。
- 模板编辑器 provider 下拉保持全部键名（现状即如此），新增/编辑模型字段对接目录（见模板编辑器组任务）。删除 Provider 的约束：被任一模板 `provider` 字段引用时禁止删除并在该行显示被哪些模板引用（避免引用悬空）。Provider 改名 = 删旧键 + 建新键 + 同步改写所有引用模板的 `provider` 字段（一次保存动作内完成，配置写回原子）。

## Risks / Trade-offs

- [第三方网关自称 magpie 但字段漂移] → 解析逐条容错（D5），坏 JSON 不砸旧目录（D6）；文档落档 `Docs/MagpieGatewayDoc.md` 记录抓取时间与出处，漂移可比对。
- [目录陈旧而用户没再点探测] → `discovered_at` 常驻显示；窗口/档位是网关侧稳定量，陈旧代价低；不做隐式后台刷新正是为了不静默改数据。
- [探测响应巨大（网关挂了几千模型）拖垮编辑器下拉] → 本期不设数量上限也不截断（发明上限违反溯源规则）；若实测出现性能问题另立 change 处理，风险如实记录。
- [改名级联写模板出错会连坐 Provider 列表] → 级联与两键增删在内存 AppConfig 上完成、一次 `ConfigService.save` 落盘，落盘前有既有 JSON 校验路径；测试覆盖级联（tasks 点名）。
- [dart:io HttpClient 受系统代理环境变量影响（与 C++ libcurl 行为不一致）] → 集成测试用本机回环假服务端验证，不依赖代理环境；真网关 live 测试直连 127.0.0.1 不受系统代理影响；风险记录于此。

## Migration Plan

无数据迁移：新键缺失按空目录读。上线顺序即 tasks 物理顺序：1 事实源落档 → 2 配置模型与解析 → 3 探测服务 → 4 Providers 页 → 5 首启向导 → 6 模板编辑器 → 7 真机 live → 8 用户文档 → **9 最终全量**（文档与守卫落定后 analyze + 全量测试 + live 非跳过各跑一次，最终树被完整跑过——2026-11-04 对抗审查修正：原设计把顺序写反，全量跑在了文档之前）。回滚 = 回退代码提交；配置里多出的 `models`/`discovered_at` 键对旧版本解析无害（`ProviderConfig.fromJson` 忽略未知键）。

## Open Questions

- 无阻塞性未决。两处待 apply 时以实测钉死的小数值不在设计内发明：无。
