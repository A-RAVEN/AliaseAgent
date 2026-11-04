# Proposal: add-provider-model-discovery

## Why

Agent 模板里的"用哪个模型"至今是无处校验的手打字符串：上下文窗口与输入模态由每个模板手填，实测用户手填的 `general` 模板窗口是 1000000，而网关目录里的真实值是 1048576——压缩阈值按"窗口 × 25%"推导（用户钉死的规则），1000000 算出 250000、1048576 算出 262144，差 12144 token 的等待空间。同时配置里 Provider 本是多条目映射，日常却**没有任何维护入口**：首次配置对话框写死键名 `anthropic`，改第二条 Provider 只能手改 JSON（模板编辑器的下拉选项其实已是全部键名，缺的是选项背后的管理界面）。用户已明确今后使用本机 magpie 网关（`yetone/magpie`，实测一个网关下 10 个模型、3 个上游，且其 `GET /v1/models` 返回窗口、模态、思考档位等完整元数据）。

## What Changes

- Provider 升级为一等管理对象：界面可新增、编辑、删除多个 Provider（名称 + 网关地址 + 密钥），不再写死单条。
- 新增模型探测：对 Provider 发 `GET {base_url}/v1/models`（与产品现有对话请求拼接规则同源，附 `x-api-key` 与 `anthropic-version` 头），按 magpie 事实标准解析目录：`id`、`display_name`、`context_window`、`max_output_tokens`、`modalities.input/output`、`supported_reasoning_levels[].effort`、`native_endpoints`、`pricing`。
- 探测结果作为该 Provider 的模型目录持久化进 `~/.aliasagent/config.json`（`providers.<名>.models` 数组 + `discovered_at` 时刻），解析对缺字段/非法值回落并打日志；探测失败时界面显示具体原因，旧目录保留不清空。
- 模板编辑器的模型字段改为从所选 Provider 的目录中选取；选中模型后 `max_context_tokens`、`input_modalities`、`thinking_effort` 的输入框以目录值回填为默认，模板字段仍保留手填覆盖（无目录或目录缺失该模型时手填照旧可用）。
- 思考档位的下拉选项来自目录 `supported_reasoning_levels[].effort` 与既有执行层合法集合的交集（目录 `none` 映射为"留空=不思考"，交集外的档位如实显示"不被执行层支持"而非静默消失；实测三家词表不同：none/low/high/max、low/high/max、low/medium/xhigh，产品不内置自建词表）。
- `native_endpoints` 与 `pricing` 只录入目录并展示，**不**作为模型可用性门禁（magpie 官方文档原文：该字段只标"哪些协议路径原生直通"，全翻译的模型整个省略此字段，Messages 请求照样能用）。
- 目录里出现产品当前发不出的模态（实测 magpie 有 `video`）时如实记录，但模板校验仍只放行产品真能发送的 `text`/`image`——检测到的能力不等于产品的能力。
- 外部事实源落档：新建 `Docs/MagpieGatewayDoc.md`（来源仓库、抓取时间、实测响应样例与 `docs/reference.md` 的字段语义引用）。

## Capabilities

### New Capabilities

- `provider-model-discovery`: Provider 的多条目管理界面、`GET {base_url}/v1/models` 探测协议与鉴权头、目录解析的字段映射与回落、目录持久化与"探测失败保留旧目录"、地址归一化（用户填了带尾 `/v1` 的地址时剥掉尾部再存储，保证对话请求拼接不重复）。

### Modified Capabilities

- `agent-config`: Provider 定义新增 `models`（目录数组）与 `discovered_at`（探测时刻）两个可选键的解析与写回规则——缺失按空目录处理，非法值回落并打日志，与 `input_modalities` 的既有回落风格一致。
- `agent-template-management`: 模板的 provider 与模型字段改为从配置与目录中选取；选定目录内模型后窗口/模态/档位输入框回填目录默认值；模板字段手填覆盖保留；保存前校验新增"模态取值仍只允许 text/image"。
- `setup-dialog-tests`: 首次配置对话框从"单条 Provider"扩展为"Provider 列表管理"后的字段校验、保存与错误提示行为。

## Impact

- **Dart 配置模型与解析**：`lib/models/provider_config.dart`（新增目录字段）、`lib/models/app_config.dart`、`lib/services/config_service.dart`、`lib/services/sidecar_bridge.dart` 不动（C++ 执行库不需要知道目录——发给模型的 `model` 字符串仍由模板携带）。
- **界面**：新增 Provider 管理页（会话侧栏 `Providers` 入口，列表 + 增删改改名 + 逐条"探测"按钮，design D8）；`lib/ui/setup_dialog.dart` 首启与补问改为两步向导——第一步 Provider 名字/地址/密钥，第二步保留现有"上下文窗口必填正整数"步（既有窗口断言不删），"提交成功一条前不可关闭"语义延续；`lib/ui/agent_template_editor.dart`（provider 下拉取全部已配置供应商、模型下拉来自目录、回填、档位选项来自目录）、新增探测状态与错误展示的界面组件。
- **探测实现**：Dart 侧 `dart:io` HttpClient 新增探测服务；超时对齐产品既有对外 HTTP 超时数值 15 秒（出处：`sidecar/src/web_fetch.cpp` 的 `FETCH_TIMEOUT_SEC = 15L`，连接超时同为该文件 `FETCH_CONNECT_TIMEOUT_SEC = 15L`）。
- **配置兼容性**：既有 config.json 向后兼容——`models`/`discovered_at` 缺失即空目录，不做自动迁移探测（首次由用户在界面上点"探测"或保存 Provider 时触发）。
- **文档**：`Docs/user-guide/provider-models.md`（新，含操作与报错说明）、`Docs/user-guide/agent-templates.md`（模型选取、档位来源、密钥显示等既有段落同步更新——CLAUDE.md 硬性同步规则）、`README.md` 功能索引、`Docs/user-guide/configuration.md` 配置键表（新增 `models`、`discovered_at` 键）、`Docs/MagpieGatewayDoc.md`（新，外部事实源）。
- **测试**：`test/unit`（目录解析方言/回落）、`test/widget`（模板编辑器下拉与回填、Provider 管理界面）、`test/integration`（假 HTTP 服务端到端探测含失败路径）、`integration_test` + `--tags live`（真连 magpie 网关，端口不可达时按既有 live 规则跳过）。
- **不做**：定时自动刷新目录（只有手动"探测"按钮与保存 Provider 时自动探测）；OpenAI 方言的解析适配（用户已定以 magpie 为标准，其他网关没有目录就走手填老路）；模型计费行为（`pricing` 仅展示）；用 `native_endpoints` 拦截模型。
