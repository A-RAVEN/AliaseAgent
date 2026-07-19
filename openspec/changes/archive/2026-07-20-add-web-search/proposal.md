# Proposal: Add Web Search Tool

## Why

当前 Agent 只能访问本地 workspace 文件（read_file / list_dir），无法获取实时信息和外部知识。联网搜索是"通用编程 Agent 框架"愿景的核心能力之一——2026-05 提案中明确将"联网搜索"列为待讨论项。现在主模型 API（DeepSeek）不支持内置搜索，需要通过独立搜索服务补齐。

## What Changes

- 新增 `web_search` 工具：主模型自主选择使用哪些搜索渠道（provider），每个渠道独立执行后结果按命名空间打包返回
- 新增 `web_fetch` 工具：主模型可抓取指定 URL 的网页文本，在搜索摘要不够时补全
- 新增 `ISearchProvider` 抽象层：可插拔的搜索服务适配器，每个 provider 独立实现
- 三个 provider 实现：
  - SearXNG 本地自托管（零 API key，Python dev 模式一键部署，聚合 70+ 引擎，返回 snippet）
  - ZhipuAI `web_browser`（利用已有 libcurl + SSE 基础设施，AI 驱动搜索+全文提取）
  - Kimi `$web_search`（内置搜索，返回 AI 合成答案。最简单集成——NO-OP 中继）
- **Provider 选择权归属主模型**：`web_search` 的 `providers` 参数暴露所有可用渠道，主模型根据需求启用一个或多个；Sidecar 并行执行并打包结果
- 配置：用户提供各 provider 的 API key（SearXNG 不需要），工具描述中自动列出当前已配置的 provider
- 搜索结果统一归一化为 `{title, url, content}` 格式，按 provider 命名空间分组回传

## Capabilities

### New Capabilities
- `web-search`: 联网搜索工具 — 暴露所有已配置的搜索 provider 供主模型按需选择，支持同时调用多个 provider，结果按命名空间分组返回
- `web-fetch`: 网页抓取工具 — 根据 URL 获取网页纯文本，作为搜索结果的补充信息源
- `search-provider`: 搜索服务抽象层 — `ISearchProvider` 接口统一三种 provider 类型（搜索引擎 / AI 驱动搜索 / AI 合成答案），支持并行多 provider 调度，统一归一化为 `{title, url, content}` 格式

### Modified Capabilities
- `basic-tools`: 新增 `web_search` 和 `web_fetch` 工具定义，扩展现有 `read_file` / `list_dir` 工具集；工具定义动态反映已配置的 provider 列表
- `ffi-bridge`: 新增 `web_search(query)` 和 `web_fetch(url)` Sidecar 函数（snake_case），C++ 侧新增搜索逻辑模块

## Impact

- **C++ Sidecar**: 新增 `search_provider.h/cpp`（`ISearchProvider` 接口 + `SearXNGSelfHost` + `ZhipuAISearch` + `KimiSearch` 实现 + `std::future` + `wait_for` 并行调度）；新增独立 OpenAI SSE transport layer（不复用 ModelGateway，含 `function.arguments` delta 累积 + `line_buf` 64KB 上限 + `tool_choice` 强制调用 + per-provider model 配置）；新增 `web_fetch` 的 libcurl 网页抓取 + CURLOPT_OPENSOCKETFUNCTION socket 层 SSRF 防护（含 IPv4-mapped IPv6 `::ffff:0:0/96` + default-deny）；异常安全（D9: extern "C" try/catch + json_escape + SEH 缓解 + ReceivePort timeout）；`ensure_search_infra` 幂等性
- **Dart sidecar_api**: 新增 `web_search` / `web_fetch` / `ensure_search_infra` / `get_search_providers` FFI 绑定（snake_case）
- **Dart _ChatScreenState**: 新增 `web_search` / `web_fetch` 工具定义；`_executeTool` 新增 dispatch 分支；工具定义根据配置动态列出可用 provider
- **配置**: `config.json` 新增各 provider 的 API key 字段（SearXNG 无 key 则始终可用）；至少一个 provider 可用的前提下注册搜索工具
- **测试**: C++ Catch2 测试覆盖 `ISearchProvider` 接口契约、并行调度、归一化行为；MockServer 扩展支持模拟搜索服务响应
- **无破坏性变更**: 现有工具和 API 完全不受影响
