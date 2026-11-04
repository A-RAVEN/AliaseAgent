## ADDED Requirements

### Requirement: Provider 管理页支持增删改与改名

应用 SHALL 在会话侧栏提供 `Providers` 入口，展示每个 Provider 的名称、网关地址与目录状态（目录条数与 `discovered_at` 时刻），支持添加、编辑（密钥、地址）与改名。界面 SHALL NOT 以明文显示密钥。Provider 改名 SHALL 在同一保存动作内把旧键改为新键，并同步改写所有引用旧名的模板 `provider` 字段，配置一次原子写回。删除 SHALL 仅在没有任何模板 `provider` 字段引用该 Provider 时允许；被引用时该行 SHALL 显示引用它的模板名单并拒绝删除。

#### Scenario: 添加第二个 Provider

- **WHEN** 用户在 Providers 页填写新名称、网关地址与密钥并保存
- **THEN** 配置 `providers` 出现第二个键，既有 Provider 与其它配置段原样保留，模板编辑器的 provider 下拉同时列出两条

#### Scenario: 改名级联引用模板

- **WHEN** 用户把被两个模板引用的 Provider 改名并保存
- **THEN** 配置中旧键消失、新键携带原值，且这两个模板的 `provider` 字段同时变为新名，重新加载后无悬空引用

#### Scenario: 被引用时删除被拒

- **WHEN** 用户尝试删除一个仍被某模板引用的 Provider
- **THEN** 删除被拒绝，该行显示引用它的模板名列表，配置不变

### Requirement: 网关地址存储前归一化

保存 Provider 时，系统 SHALL 对输入的网关地址做且仅做一种规范化：剥掉尾随的 `/`，再剥掉尾部路径段 `/v1`（循环至不再以 `/v1` 或 `/` 结尾），其余路径原样保留。归一化后的值是存储与拼接的唯一真相：对话请求拼 `{base_url}/v1/messages`（既有 C++ 规则），模型探测拼 `{base_url}/v1/models`，两条拼接 MUST 同源不重复。

#### Scenario: 用户粘贴带 /v1 的网址

- **WHEN** 用户输入 `http://127.0.0.1:3425/v1` 并保存
- **THEN** 存储值为 `http://127.0.0.1:3425`，对话与探测 URL 分别拼成 `/v1/messages` 与 `/v1/models`，不出现 `/v1/v1/`

#### Scenario: 带子路径的地址不受影响

- **WHEN** 用户输入 `https://api.deepseek.com/anthropic` 并保存
- **THEN** 存储值逐字保留（尾部不是 `/v1`），两条拼接仍与现状一致

### Requirement: 模型探测请求形态

系统 SHALL 通过 Dart 侧 HTTP 客户端对 Provider 发 `GET {归一化 base_url}/v1/models`，请求头携带 `x-api-key: {api_key}` 与 `anthropic-version: 2023-06-01`（与对话请求同源的鉴权头），连接与读超时对齐产品既有对外 HTTP 超时数值（出处：`sidecar/src/web_fetch.cpp` 的 `FETCH_CONNECT_TIMEOUT_SEC = 15L` 与 `FETCH_TIMEOUT_SEC = 15L`）。触发时机 SHALL 只有两个：用户在 Providers 页手动点"探测"，以及保存 Provider（新增/改名/改地址/改密钥）成功后自动执行一次。除此之外系统 MUST NOT 在任何时机（启动、定时、后台）自动发起探测。

#### Scenario: 手动探测成功

- **WHEN** 用户对一个可达的 magpie 标准网关点击"探测"
- **THEN** 界面显示本次结果的"新增 N，更新 M，移除 K，丢弃 X"计数，目录与 `discovered_at` 写入配置

#### Scenario: 保存 Provider 后自动探测一次

- **WHEN** 用户保存一个新 Provider 且其网关可达
- **THEN** 保存成功后自动完成一次探测，目录状态显示在列表行内

#### Scenario: 启动不产生网络请求

- **WHEN** 应用带着含两个 Provider 的既有配置冷启动
- **THEN** 启动过程不发生任何模型探测请求（既有对话恢复行为不受影响）

### Requirement: 目录解析按 magpie 事实标准逐字段回落

解析 `{data:[...]}` 响应时，每个模型条目 SHALL 记录 `id`、`display_name`、`context_window`、`max_output_tokens`、`modalities.input`、`modalities.output`、`supported_reasoning_levels[].effort`、`native_endpoints`、`pricing`；`native_endpoints` 与 `pricing` 缺失 SHALL 记为"未知"（该网关文档语义：未知整个省略），MUST NOT 补齐成空集合冒充已知。回落规则：单条缺 `id` 或 `id` 非字符串 → 丢弃该条并打一行日志点名原始 JSON，其余条目照常入库，被丢弃条数 SHALL 计入"丢弃 X"而 **不计入**"移除"；`context_window` 缺失或非正整数 → 该条记"窗口未知"；`supported_reasoning_levels` 为 `[]` → 合法语义"无已知档位"，不算解析失败；`modalities.input` 含产品当前发不出的取值（如 `video`）→ 目录 MUST 照录原值，任何过滤只发生在回填模板输入框之时（检测≠能力，略去必须可见）。响应顶层不是对象、`data` 缺失或非数组 → 判定"该端点不是 magpie 标准目录"，本次结果整体作废，旧目录保留；完整原始响应 SHALL 写入 `~/.aliasagent/logs/model_discovery_error_<UTC 时刻>.txt`，界面 SHALL 显示总字符数、按既有配置 `spill.preview_chars` 长度的预览、以及"已略去多少字符、完整内容见 <路径>"（截断可见且可恢复）。

#### Scenario: 实测网关目录落库

- **WHEN** 对本机 magpie 网关探测成功（2026-11-04 实测其目录含 10 条、3 个上游）
- **THEN** 每个条目的 `id`、`display_name`、`context_window`（如 `deepseek/deepseek-flash` 为 1048576）、`modalities.input`（含 `video` 的照录）、`supported_reasoning_levels` 全部写入 `providers.<名>.models`

#### Scenario: 坏条目不砸整份目录

- **WHEN** 响应 `data` 数组里有一条缺 `id`
- **THEN** 其余条目全部正常入库，日志有一行点名被丢弃条目的原始 JSON

#### Scenario: 非标准响应整体作废

- **WHEN** 端点返回顶层数组或非 JSON 文本
- **THEN** 判定不是 magpie 标准目录，旧目录与 `discovered_at` 不变，界面显示总字符数、按 `spill.preview_chars` 长度的预览、"已略去多少字符"与完整响应落盘文件的路径

#### Scenario: 截断后全文仍可取回

- **WHEN** 原始响应超过预览长度且用户在界面看到截断标记
- **THEN** 按界面给出的 `~/.aliasagent/logs/model_discovery_error_<UTC 时刻>.txt` 路径能读到与网关返回逐字节相同的完整响应

### Requirement: 目录持久化与整配置写回

探测成功的目录 SHALL 写入 `~/.aliasagent/config.json` 的 `providers.<名>.models` 数组并同步更新 `discovered_at`（UTC ISO 8601）。再次探测 SHALL 以新目录整体替换该 Provider 的旧目录（模型已从网关消失即从目录消失，替换结果通过"移除 K"计数可见，不静默消失）；"移除 K" SHALL 只统计本次响应中**完整解析成功且**不再出现的 `id`，解析期丢弃的条目 MUST NOT 计入 K 而 SHALL 计入"丢弃 X"（否则解析失败会被显示成网关下架，两种原因相反）。写回 MUST 保留 `version`、其它 Provider、`agent_types`、`search`、`spill` 各段原样。旧配置缺 `models`/`discovered_at` SHALL 按空目录、从未探测读取，无迁移代码；序列化 SHALL 写回这两个键使其可发现。

#### Scenario: 模型从网关消失

- **WHEN** 网关目录里原有、本地目录里也有的某模型在本次探测不再返回
- **THEN** 新目录不含该模型，界面结果计数"移除 1"，已保存模板的字段不被回改

#### Scenario: 旧配置直接可读

- **WHEN** 加载一份没有任何 `models`/`discovered_at` 键的既有配置
- **THEN** 每个 Provider 解析为空目录 + 从未探测，列表显示"未探测"，全部既有功能不回归

### Requirement: 探测失败可见且不破坏旧目录

连接拒绝、超时、非 200 状态码（含 401/404）等失败 SHALL 在 Providers 界面对应行显示"探测失败：<具体原因>"（HTTP 失败必须带状态码），该 Provider 的既有目录与 `discovered_at` MUST 原样保留；保存 Provider 后的自动探测失败 SHALL NOT 回滚已保存的配置。密钥 MUST NOT 出现在错误展示或日志里。

#### Scenario: 网关未启动

- **WHEN** 用户对网关进程未启动的 Provider 点探测
- **THEN** 行内显示连接失败原因，旧目录仍可被模板编辑器用作下拉来源

#### Scenario: 密钥错误 401

- **WHEN** 网关对探测返回 401
- **THEN** 界面显示"探测失败：HTTP 401"，日志与界面均不含密钥明文

### Requirement: native_endpoints 与 pricing 仅展示不门禁

目录中的 `native_endpoints` 与 `pricing` SHALL 原样存储并在模板编辑器选中模型时作为参考信息展示；系统 MUST NOT 依据 `native_endpoints` 缺失或不含 `/v1/messages` 而阻止选择该模型或报错（magpie 官方文档语义：该字段只标"哪些协议路径原生直通"，全翻译模型与路由组整个省略该字段，Messages 请求仍可用）。

#### Scenario: 无 native_endpoints 的模型仍可选

- **WHEN** 用户选中一个目录条目不含 `native_endpoints` 的模型
- **THEN** 正常回填与保存，无警告弹窗；若同 Provider 的其它条目带该字段，其值仅显示为说明文字
