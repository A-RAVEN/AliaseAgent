# Design: Add Web Search Tool

## Context

当前 Sidecar 通过 `ModelGateway` 与模型 API 通信。`ModelGateway` 是一个完全的 Anthropic 协议实现——SSE 解析 dispatch 的是 Anthropic 事件类型，HTTP 请求格式和 auth headers 不可切换。搜索工具的 ZhipuAI 和 Kimi provider 都需要 OpenAI Chat Completions 兼容的协议，因此需要独立的 HTTP/SSE 传输路径。

三个 provider 覆盖三种搜索范式：搜索引擎 REST API（SearXNG）、AI 驱动非流式搜索（ZhipuAI web_search）、AI 合成答案 SSE（Kimi $web_search）。

## Goals / Non-Goals

**Goals:**
- web_search 工具，主模型自主选择 provider 组合，并行搜索，按命名空间打包结果
- web_fetch 工具，可从 URL 抓取网页纯文本，含 SSRF 防护
- ISearchProvider 抽象层，三种 provider 类型（搜索引擎 REST / AI 驱动非流式 / AI 合成 SSE）
- 三个实现：SearXNG localhost + ZhipuAI web_search adapter + Kimi $web_search adapter
- 用户提供各 provider 的 API key（SearXNG 不需要），工具描述自动反映已配置的 provider
- web_search/web_fetch 在 worker isolate 中异步执行（仿 `sendMessage` 已有模式），不阻塞 UI

**Non-Goals:**
- 不修改现有 ModelGateway 的公共接口或内部逻辑
- 不做 MCP bridge（后续单独 change）
- 不做搜索结果缓存
- 不修改 Dart 侧 Session/Message 数据模型
- 不支持运行时 config hot-reload（需重启应用）
- 不加密 config.json 中的 API key（与现有主模型 key 同级别保护）

## Decisions

### D0: 传输层分离 — Anthropic vs OpenAI-compatible

**Decision**: `ModelGateway` 保持不变（仅用于主模型的 Anthropic 协议通信）。ZhipuAI 和 Kimi 适配器使用独立的 OpenAI 兼容 HTTP/SSE 传输层。SearXNG 使用简单 HTTP GET（不需要 SSE）。

```
search() 调用 → 传输层选择:
  ├─ SearXNG:          libcurl GET (REST JSON)
  ├─ ZhipuAISearch:    独立 curl 句柄 + 非流式 HTTP POST（解析完整 JSON）
  └─ KimiSearch:       独立 curl 句柄 + OpenAI SSE parser（流式 tool_calls）
```
**Rationale**: `ModelGateway` 硬编码了 Anthropic 协议的所有方面——URL 路径（`/v1/messages`）、auth header（`x-api-key`）、SSE 事件 type dispatch（`content_block_delta` 等）、tool call 组装流程（`content_block_start`/`content_block_stop`）。OpenAI 兼容 API 使用 `POST /v1/chat/completions`、`Authorization: Bearer`、`choices[0].delta` 事件结构。两者不可互相替代。

**Implementation**: ZhipuAI 和 Kimi 适配器各自创建 curl 句柄，send/receive 逻辑内联在各适配器内部。OpenAI SSE 解析复用 `write_callback` 的行缓冲模式（`line_buf` → split on `\n` → parse `data:` lines），但事件 dispatch 为 OpenAI 格式（`choices[0].delta.content` 用于文本，`choices[0].delta.tool_calls` 用于工具调用）。所有 HTTPS 句柄 SHALL 设置 `CURLOPT_SSL_VERIFYPEER=1L`（与 `model_gateway.cpp:411` 一致）。

**SSE `function.arguments` delta 累积**：OpenAI 流式 API 将 `function.arguments` 分散在多个 SSE delta 中。parser SHALL 按 `tool_calls[].index` 拼接 delta 片段，仅在收到完整参数后解析 JSON。同时 SHALL 捕获 `tool_calls[].id`（与 `function.arguments` 在同一 delta 中），用于构造后续 `{"role": "tool", "tool_call_id": "...", "content": "..."}` 消息。

**SSE line_buf 大小上限**：`write_callback` 的 `line_buf` 积累 SHALL 设 64KB 上限（与 `raw_body` 一致）。超过上限时 write callback 返回 0 中止传输，防止恶意/异常 SSE 流（无换行符的连续数据）导致内存无限增长。此上限同步应用于现有的 `model_gateway.cpp` 和新 search provider 的 SSE parser。

**SSE event 聚合大小上限**：`function.arguments` delta 累积（跨多个 `data:` 行）SHALL 设 1MB 总大小上限。单行 64KB cap 不足以防止大量小行累积导致的 OOM。超过 1MB 聚合上限时中止该 provider 的 SSE 流并返回错误。

### D1: 搜索服务抽象 — ISearchProvider 接口（含错误通道）

```cpp
struct SearchResult {
  std::string title;   // 可空（Kimi 合成答案无 title）
  std::string url;     // 可空
  std::string content; // 必有
};

struct SearchError {
  std::string message;    // 人类可读错误
  bool is_transient;      // 可重试（HTTP 429, timeout）vs 永久（401, 403）
};

struct ProviderResult {
  std::vector<SearchResult> results;  // 成功时可空或非空，失败时为空；空 results + 空 error.message = "无匹配结果"（成功态）
  SearchError error;                   // 成功时 message 为空，is_transient 仅对失败态有意义
};

class ISearchProvider {
public:
  virtual std::string name() const = 0;
  virtual std::string description() const = 0;
  virtual bool is_configured() const = 0;
  virtual ProviderResult search(
    const std::string& query,
    const std::string& depth,
    int max_results
  ) = 0;
  virtual ~ISearchProvider() = default;
};
```

`ProviderResult` 统一了"成功但空结果"（`results` 空 + `error.message` 空）和"失败"（`results` 空 + `error.message` 非空），消除了旧设计中两者无法区分的歧义。

### D2: Provider 选择——AI 决策，工具参数包含 depth

```dart
const _webSearchDef = {
  'name': 'web_search',
  'description': 'Available providers:\n'
      '- searxng: 70+ engines, short snippets. No API key needed.\n'
      '- zhipuai: AI-driven search with synthesized answer and structured results. Requires API key.\n'
      '- kimi: AI-synthesized answer (single summary, no URLs). Requires API key.\n\n'
      'Choose providers based on needs. Combine to cross-reference.',
  'input_schema': {
    'properties': {
      'query': {'type': 'string', 'description': 'The search query.'},
      'providers': {
        'type': 'array',
        'items': {'enum': ['searxng', 'zhipuai', 'kimi']},
        'default': [],  // empty = use all configured providers
        'description': 'Which search providers to use. Run in parallel.',
      },
      'depth': {
        'type': 'string',
        'enum': ['basic', 'deep'],
        'default': 'basic',
        'description': 'basic = snippets only (fast). deep = full page extraction (higher latency, only meaningful for zhipuai).',
      },
      'max_results': {'type': 'integer', 'minimum': 1, 'maximum': 10, 'default': 5},
    },
    'required': ['query'],
  },
};
```

```json
// config.json — 人类提供各 provider 的凭证（per-provider 嵌套 key）
{
  "search": {
    "zhipuai": {"api_key": "xxx"},
    "kimi": {"api_key": "sk-xxx"}
    // searxng 不需要 key，无需配置
  }
}
```

**注意**: `specs/basic-tools/spec.md` 中条件注册检查的是 `search.zhipuai.api_key` 或 `search.kimi.api_key` 存在性（per-provider），而非平面 key `search.api_key`。Config key 使用 snake_case `api_key`，与现有 `ProviderConfig.api_key` 字段一致。

### Config 流向 — Dart 为 config 唯一读取者

**Decision**: 搜索 provider 的 API key 读取路径与主模型保持一致。Dart `ConfigService` 是 `config.json` 的唯一读取者，搜索凭证通过 FFI 传递给 C++ Sidecar。C++ 侧不直接读文件系统，不引入第二套 config 解析逻辑。

```
config.json
  ↓ Dart ConfigService.load()
  ↓ AppConfig 模型扩展 search 字段
  ↓ 序列化为 search_config_json
  ↓ FFI: ensure_search_infra(search_config_json)
  ↓
C++ 侧:
  ├─ 解析 JSON → 缓存到各 provider 实例
  ├─ is_configured() → 对于 ZhipuAI/Kimi：检查内存中缓存的 key 是否非空（不读文件）
  │                     对于 SearXNG：返回 ensure_search_infra 中 TCP liveness check 的缓存结果（O(1)）
  ├─ get_search_providers() → 返回已配置的 provider 列表
  └─ web_search() → 用已缓存的 key 发请求
```

**SearXNG 例外**: SearXNG 无 API key，其 `is_configured()` 行为不同于其他 provider。`ensure_search_infra` 调用时执行一次性 TCP connect 到 `localhost:8888`（2s 超时），结果缓存为 bool。`is_configured()` 直接返回缓存值，不发起新连接。避免重复 TCP 检查导致启动延迟。

**Rationale**: 主模型的 API key 路径是 `Dart ConfigService → send_message(api_key, ...) → C++`。如果搜索 provider 走 `C++ 直接 fopen config.json`，会导致：(1) 两套 config 解析逻辑（Dart 的 `jsonDecode` + C++ 的 JSON parser）；(2) C++ 需要知道 `%USERPROFILE%\.aliasagent\config.json` 路径（平台相关逻辑）；(3) AppConfig 模型变更时需要两边同步。统一走 Dart → FFI → C++ 避免了所有这些。

**Implementation**: 
- `AppConfig` 新增 `search: Map<String, dynamic>?` 字段，承载整个 `search` 区块
- `AppConfig.toJson()` SHALL 条件性包含 `search` 字段（非 null 非空时写入），防止 ConfigService.save() 回写时丢失数据
- `sidecar_api.h` 新增 `SIDECAR_API const char* ensure_search_infra(const char* search_config_json);`
- C++ 侧解析 JSON，将各 provider 的 key 写入对应实例的成员变量
- **Idempotency**: `ensure_search_infra` SHALL 使用 `std::call_once` / `static bool` 守卫确保只执行一次。重复调用直接返回 `{"ok":true}` 跳过，避免不必要的 TCP 检查和凭证覆盖
- C++ FFI 函数命名采用 snake_case（与现有 `send_message`/`read_file`/`list_dir` 一致）
- `is_configured()` 只检查内存中的缓存值，不做文件 IO 或网络 IO

### D3: 并行多 provider 执行（含超时和 deadline）

web_fetch 非搜索工具，此处不适用。

Per-provider 超时：
- SearXNG: 5 秒（简单 HTTP GET）
- ZhipuAI: 30 秒（单次非流式 HTTP POST + JSON 解析）
- Kimi: 30 秒（单次 SSE 流）

总 deadline：`max(已选 provider 的 per-provider 超时)` = 30 秒。超时后，已完成的 provider 结果 + 未完成 provider 的超时错误一同返回。

**Deadline 执行机制**：使用 `std::future` + `wait_for`，而非 `std::thread` + `join`。`join()` 会无限期阻塞，一旦某 provider 的 curl 调用挂死（如 TCP 分区），整个 worker isolate 永久卡住。正确做法：

```cpp
std::vector<std::future<ProviderResult>> futures;
for (auto& provider : providers) {
  futures.push_back(std::async(std::launch::async, [provider, &query, &depth, &max_results]() {
    return provider->search(query, depth, max_results);
  }));
}

auto deadline = std::chrono::steady_clock::now() + std::chrono::seconds(30);
for (auto& f : futures) {
  auto status = f.wait_until(deadline);
  if (status == std::future_status::ready) {
    // 收集结果
  } else {
    // 超时——该 provider 结果标记为 timeout error
  }
}
```

**`std::future` 析构语义注意事项**：`std::async(std::launch::async, ...)` 返回的 future 在析构时会阻塞直到异步任务完成。这不会造成无限 hang，因为 `CURLOPT_TIMEOUT` 在 per-provider 级别确保线程最终退出（最坏情况 = deadline + max(CURLOPT_TIMEOUT) = 120s）。**不**使用 `std::thread::detach()` 或 thread pool——每个 provider 的 future 析构等待是可控的，curl timeout 保证了上界。若未来需要更精细的控制（如 Dart 侧取消），可改为 detached `std::thread` + `std::promise` 模式。

每个 provider 的 `search()` 内部通过 `CURLOPT_TIMEOUT` + `CURLOPT_CONNECTTIMEOUT` 设置 per-request 超时（参照 `model_gateway.cpp` 已设两者），确保即使 deadline 未触发，curl 也不会无限 hang。

线程安全：每个 provider 使用自己的 curl 句柄和自己的字符串缓冲区。`std::async` 不共享可变状态。Provider 实例是 singleton（在 `ensure_search_infra` 中创建，缓存 API key），但每个 provider 的 curl 句柄在每次 `web_search` 调用中新建（per-call handle），确保同一 provider 的两次并发调用不会竞争 curl 状态。Dart 侧当前串行执行工具调用（_executeTool 的 for 循环），因此并发 FFI 调用不会发生；若未来改为并行工具执行，需在 C++ `web_search` 入口加 mutex 或改为 per-call provider 实例化。

返回格式采用 per-namespace 结构（见 spec `web-search/spec.md`）。`error` 非 null 时 `results` 必定为空数组。**注意**：`is_transient` 字段用于 C++ 内部（Kimi 429 重试、timeout 分类、异常包装），在序列化为 per-namespace JSON 时不保留——AI 模型通过 error string 内容区分错误类型。若未来 Dart 侧需要消费 `is_transient`，应在 serialization 格式中将 `error` 改为 `{message, is_transient}` 对象。

### D4: ZhipuAI 适配器（非流式 HTTP POST + web_search tool）

**Model**: `glm-4.7-flash`（免费，支持 web_search tool）。`search.zhipuai.model` 可配置。

ZhipuAI 的 `web_search` 不是 function calling——平台在后台自动执行搜索、将结果注入模型上下文、模型生成带引用的回答。客户端只需发起一次非流式 POST，在完整 JSON 响应中同时拿到结构化搜索数据和模型综合回答。

**Tool 格式**（参考 [官方文档](https://docs.bigmodel.cn/cn/guide/tools/web-search)）:
```json
[{
  "type": "web_search",
  "web_search": {
    "enable": true,
    "search_result": true,    // ← 必须设为 true，否则响应不含 web_search[] 数组
    "search_prompt": "你是一位搜索助手...",
    "count": 5
  }
}]
```

```
ZhipuAISearch::search(query, depth, max_results)
  │
  ├─ 构造 messages: [{"role": "user", "content": query}]
  │   可包含 system message 引导搜索行为
  ├─ 注册 tool: [{"type": "web_search", "web_search": {"enable": true, "search_result": true, ...}}]
  │   search_result=true 确保响应中包含顶层 web_search[] 数组
  │   （平台自动执行搜索、阅读、综合——客户端无需处理 tool_calls）
  ├─ POST /chat/completions (Authorization: Bearer, stream: false)
  │   （非流式——web_search 结果仅在完整响应中返回）
  ├─ 解析 JSON 响应:
  │   ├─ 顶层 web_search[] → {title, link, content, icon, media, refer}
  │   │   → 映射为 SearchResult{title, url=link, content}
  │   │   按 max_results 截断
  │   └─ choices[0].message.content → 模型综合回答（带 [来源：ref_N] 引用）
  │       → 作为 SearchResult{title:"", url:"", content: answer} 追加到 results
  └─ 返回 ProviderResult{results, error}

超时：30 秒（单次非流式 HTTP POST）
depth 参数忽略（web_search 不支持 depth 控制——平台自动决定搜索深度）
```

与 Kimi 适配器的关键区别：ZhipuAI web_search 不需要 SSE 解析、不需要 agent loop、不需要 tool_result 回传。搜索结果以结构化 JSON 字段返回，而非模型内部合成后仅返回文本。

**注意**: 实际 API 行为可能因模型/API key 不同而异。`glm-4.7-flash` 模型成功执行搜索但可能只返回综合回答（`message.content`）而不返回顶层 `web_search[]` 数组。代码已兼容两种模式：优先解析 `web_search[]`（若存在），始终捕获 `message.content` 作为 fallback 结果。

### D5: SearXNG 适配器

```
SearXNGSelfHost::search(query, depth, max_results)
  │
  ├─ GET /search?q=<url_encoded_query>&format=json
  │   （无 limit 参数——SearXNG API 不支持，客户端截断）
  │
  ├─ 解析 JSON → results[] → 截取前 max_results 条
  ├─ 映射: .title→title, .url→url, .content→content
  ├─ depth 忽略
  │
  └─ 超时 5s
```

URL 编码：搜索 query 在拼接 URL 前必须进行百分号编码。

SearXNG 部署方式：Python dev 模式（`python -m searx.webapp`），无需 Docker。项目提供 `scripts/setup_searxng.bat`（Windows）一键完成：检查 Python → git clone → venv 创建 → pip install → 生成含 `format: json` 的 settings.yml → 启动本地服务。SearXNG 部署前提：`settings.yml` 中启用 `format: json`，否则返回 HTTP 403。

### D6: Kimi 适配器（OpenAI 传输 + NO-OP relay）

**Model**: 使用 `moonshot-v1-auto`（默认支持 `$web_search` builtin function）。`search.kimi.model` 可配置项允许用户覆盖。

```
KimiSearch::search(query, depth, max_results)
  │
  ├─ 构造 body 时注入 `thinking: {type: "disabled"}` ← 必须！
  │   （Kimi 文档明确要求 $web_search 与思考模式不兼容）
  │
  ├─ 注册 $web_search 为 builtin_function
  │   + tool_choice: {type: "builtin_function", builtin_function: {name: "$web_search"}}
  │   （强制调用搜索 tool，防止模型从训练记忆直接回答而不执行搜索）
  ├─ POST /v1/chat/completions (Authorization: Bearer, OpenAI 格式)
  ├─ 拦截 SSE: finish_reason=tool_calls + function.name="$web_search"
  │   → 按 index 累积 function.arguments delta → 原封不动回传完整 arguments 作为 tool_result (NO-OP)
  │   若 arguments 缺失/null → 返回 ProviderResult 带 error（Kimi API 契约异常）
  │
  ├─ 继续 SSE → finish_reason=stop → 收集文本答案
  └─ 归一化: SearchResult{title: "", url: "", content: "<答案>"}
```

HTTP 429 重试：Kimi 适配器专属逻辑。最多 2 次，指数退避（1s, 2s），尊重 `Retry-After` header。SearXNG 和 ZhipuAI 当前不做 429 重试（后续迭代添加）。

### D7: web_fetch（含 SSRF 防护）

```
web_fetch(url)
  │
  ├─ URL 验证:
  │   ├─ 小写化 scheme 后检查：仅允许 http: 和 https:（大小写不敏感）
  │   ├─ 拒绝 hostname "localhost"（大小写不敏感）
  │   ├─ 仅设置 CURLOPT_PROTOCOLS = CURLPROTO_HTTP | CURLPROTO_HTTPS
  │   │
  │   └─ 不在此阶段做 IP blocklist 检查（URL 字符串级别的 blocklist 不可靠——
  │       IPv6 表示法、DNS rebinding、HTTP 重定向均可绕过）
  │
  ├─ libcurl HTTP GET, 15s 超时, CURLOPT_FOLLOWLOCATION=1, CURLOPT_MAXREDIRS=5
  │   （允许重定向以兼容现实 web，但通过 socket callback 验证所有连接目标）
  │   CURLOPT_ACCEPT_ENCODING="" → 启用 gzip/deflate 透明解压；无需手动处理 Content-Encoding
  │
  ├─ CURLOPT_OPENSOCKETFUNCTION callback（socket 级 SSRF 防护）:
  │   │  在 DNS 解析后、connect() 前触发，可检查已解析的 sockaddr
  │   ├─ 拒绝 IPv4 私有/环回/链路本地:
  │   │   127.0.0.0/8, 10.0.0.0/8, 172.16.0.0/12, 192.168.0.0/16,
  │   │   169.254.0.0/16, 0.0.0.0/8, 100.64.0.0/10
  │   ├─ 拒绝 IPv6 环回/链路本地/ULA:
  │   │   ::1/128, fe80::/10, fc00::/7
  │   ├─ 此 callback 对每次连接都触发（包括 HTTP 重定向后的新连接）
  │   └─ 拒绝时返回 CURL_SOCKET_BAD，curl 报告连接失败
  │
  ├─ CURLOPT_WRITEFUNCTION callback（incremental size check）:
  │   │  每收到一块数据，累加已收字节数
  │   ├─ 超过 100KB 时返回 0 → curl 中止传输
  │   └─ 防止 zip bomb / 无限 chunked response 先撑爆内存再 truncate
  │
  ├─ 检查 Content-Type（MIME 类型精确匹配（取 ';' 前部分，与 `"text/html"` 做 case-insensitive equality check））:
  │   ├─ 类型为 "text/html"（含 charset 后缀如 "text/html; charset=utf-8"）→ HTML 标签剥离 + 空白压缩
  │   ├─ NULL / 无 Content-Type header → 当作原始文本处理（保守策略，避免 HTML bypass）
  │   └─ 其他 → 返回原始文本，100KB 截断
  │
  └─ 错误: 连接失败, TLS 错误, HTTP 4xx/5xx, 超时,
           重定向到内部地址, SSRF 阻止
```

**SSRF 防御核心原则**：验证发生在 socket 层（`CURLOPT_OPENSOCKETFUNCTION`），而非 URL 字符串层。socket 层的 sockaddr 已经是 DNS 解析后的结果，天然免疫 DNS rebinding、IPv6 变体、HTTP 重定向、大小写欺骗。

`extract_mode` 参数 v1 只支持 `"text"`。`"markdown"` 延后到后续 change（需引入 HTML→Markdown 转换库）。

`CURLOPT_FOLLOWLOCATION=1` + `CURLOPT_MAXREDIRS=5`。因为 socket callback 对所有目标都触发 SSRF 验证，重定向是安全的。`CURLOPT_REDIR_PROTOCOLS_STR` 设为 `"http,https"` 防止协议切换攻击。

### D8: Dart 侧异步执行（Isolate + _toolDefs 重构）

`web_search` 和 `web_fetch` 的 FFI 调用 SHALL NOT 在主 isolate 上执行。它们 SHALL 遵循 `sendMessage` 的已有模式：`Isolate.spawn` + `SendPort`/`ReceivePort`。

`sidecar_bridge.dart` 中的实现参考现有的 `sendMessage` 包装模式（`sidecar_bridge.dart:112-154`）。

**_executeTool 签名变更**：现有 `_executeTool` 是同步方法（返回 `Map<String, dynamic>`），但 `Isolate.spawn` + `ReceivePort` 模式本质上是异步的。`_executeTool` 的签名 SHALL 改为 `Future<Map<String, dynamic>>`，工具循环（`lib/main.dart` 的 `for` loop）SHALL 对每次调用加 `await`。现有的 `read_file`/`list_dir` 同步调用在 async 方法内仍然有效（Dart 允许 async 方法中的同步操作）。

**_toolDefs 重构**：现有 `_toolDefs` 是 `static const`，不可在运行时动态增删。`web_search` 的工具定义需要根据已配置的 provider 列表动态生成 description（列出当前可用的 provider 名称和能力）。改造方案：
1. `_toolDefs` 改为 `late final` 实例字段（或 static `late final`）
2. 启动时：`ConfigService.load()` → `ensure_search_infra()` → `get_search_providers()` → 动态构建 `_toolDefs`（包含静态的 `read_file`/`list_dir` + 根据配置条件包含 `web_search`/`web_fetch`）
3. `web_search` 的 description 和 providers enum 从 `get_search_providers()` 返回的列表中动态生成

这确保了：无已配置 provider 时不注册搜索工具（符合 spec），AI 看到的 description 仅列出实际可用的 provider（避免 AI 选择不可用的 provider）。

### D9: C++ 异常安全 — FFI 边界保护

**Decision**: 所有 `extern "C"` FFI 函数 MUST catch 所有异常并返回 JSON 错误对象。C++ 异常穿透 C 函数边界属于未定义行为，会导致进程 crash。

**返回字符串的线程安全**：采用与现有 `g_last_tool_result`（`sidecar_api.cpp:12`）一致的 **static string** 模式。每个 `extern "C"` 函数用独立 `static std::string` 作为返回值缓冲区。当前 Dart 侧工具调用是串行的（`_executeTool` 的 `for` 循环），因此同一函数不会被两个线程并发调用。Dart 侧 `toDartString()` 在 FFI 返回后立即拷贝数据，static string 的生命周期足够。

```cpp
// 与现有 send_message/read_file/list_dir 一致的 static string 模式
SIDECAR_API const char* web_search(const char* request_json) {
  try {
    static std::string result;  // 函数级 static，与 g_last_tool_result 同模式
    result = actual_implementation(request_json);
    return result.c_str();
  } catch (const std::exception& e) {
    static std::string err;
    err = "{\"ok\":false,\"error\":\"" + json_escape(e.what()) + "\"}";
    return err.c_str();
  } catch (...) {
    return "{\"ok\":false,\"error\":\"Unknown internal error\"}";
  }
}
```

**注意**：不可使用 `new std::string(...)->c_str()` heap 分配模式——`c_str()` 返回内部 buffer 指针，无法从 `const char*` 反推 `std::string*` 所有权（SSO 下 offset 不可移植），导致无法正确释放。Static string 模式已在现有 `send_message`/`read_file`/`list_dir` 中验证可行。
```

**JSON 转义**：`e.what()` 可能包含双引号、反斜杠、换行符等 JSON 特殊字符。err string 拼接前 SHALL 调用 `json_escape()`（现有 `tools.cpp:146-160` 已有实现，需提取到 `tools.h` 作为公共函数）。不转义会导致 Dart 侧 JSON 解析失败。

**Windows SEH 异常**：在 MSVC `/EHsc` 编译模式下，C++ `catch(...)` **不捕获** Windows SEH 异常（如 access violation 0xC0000005、stack overflow 0xC00000FD）。这些异常会穿透到 crash handler 并终止进程。缓解措施：
1. 代码质量（null 检查、bounds check）是主要防线
2. `crash_handler.cpp` 的 unhandled exception filter 会写 minidump 后终止
3. Dart 侧 `ReceivePort` 应加 `.timeout(Duration(seconds: 120))` 防止 isolate 永久挂起
4. 如需完整 SEH 捕获，可改为 `/EHa` 编译选项（有性能开销），或在关键 FFI 边界加 `__try/__except` 守卫

**每个 provider 线程内部也 SHALL catch 异常**，转换为 `ProviderResult{results={}, error={message, is_transient=false}}`，避免 `std::thread` 中未捕获异常导致 `std::terminate`。

**Implementation**: 参照已有模式——`sidecar_api.cpp` 中 `set_workspace`/`read_file`/`list_dir` 已使用 try/catch + JSON error return（`g_last_tool_result`）。`web_search`/`web_fetch`/`ensure_search_infra`/`get_search_providers` 沿用同一模式，但需注意上述线程安全与 JSON 转义改进。

### D10: SSRF socket 层验证 — CURLOPT_OPENSOCKETFUNCTION

**Decision**: SSRF 防护的核心位置是 socket 创建时（`CURLOPT_OPENSOCKETFUNCTION`），而非 URL 字符串解析时。socket callback 接收已解析的 `struct sockaddr`，天然覆盖 DNS rebinding、IPv6 变体、HTTP 重定向、大小写欺骗。

```
攻击向量                        URL 字符串检查    Socket 层检查
─────────────────────────────────────────────────────────────
http://127.0.0.1/              ✅ 可捕获         ✅ 可捕获
HTTP://127.0.0.1/ (大小写)     ❌ 可能漏         ✅ sockaddr 不变
http://[::1]:8080/ (IPv6)      ❌ 可能漏         ✅ sockaddr 不变
http://127.0.0.1.nip.io/       ❌ 无法判断       ✅ 解析后检查 IP
DNS rebinding (TTL=1s)         ❌ 无法判断       ✅ 每次连接重检
HTTP 301 → 内网 IP             ❌ 不重检         ✅ callback 重触发
```

Blocklist（在 socket callback 中检查 `sockaddr`）：
- IPv4: `127.0.0.0/8`, `10.0.0.0/8`, `172.16.0.0/12`, `192.168.0.0/16`, `169.254.0.0/16`, `0.0.0.0/8`, `100.64.0.0/10`
- IPv6: `::1/128`, `fe80::/10`, `fc00::/7`, **`::ffff:0:0/96`**（IPv4-mapped IPv6——DNS 可返回 AAAA 记录将内网 IPv4 编码为 `::ffff:192.168.1.1`，必须在 IPv6 分支中检测并提取嵌入 IPv4 地址重新做 IPv4 blocklist 检查），**`64:ff9b::/96`**（NAT64 Well-Known Prefix per RFC 6052——IPv6-only 网络中 DNS64 合成地址，同样需提取嵌入 IPv4 地址做二次检查）

**Implementation**: 注册 `CURLOPT_OPENSOCKETFUNCTION` callback，其中调用 `getpeername` 或直接检查 `curl_sockaddr.address`。匹配 blocklist 则返回 `CURL_SOCKET_BAD` 阻止连接。当 `sa_family == AF_INET6` 且地址在 `::ffff:0:0/96` 范围内时，提取末 4 字节作为 IPv4 地址进行二次检查。

## Risks / Trade-offs

| Risk | Mitigation |
|------|------------|
| 并行搜索 token 消耗过大 | AI 权衡——简单问题单 provider，复杂问题多 provider |
| ModelGateway 不可复用给 ZhipuAI/Kimi | D0：每个适配器使用独立 curl 句柄 + OpenAI SSE parser |
| Kimi 结果无 URL 结构 | 工具描述已声明；AI 知道无法用 web_fetch 补全 |
| ModelGateway SSE parse 错误静默丢弃 | 每个适配器的 SSE parser 累积错误计数（超出阈值时报告） |
| web_fetch 非 HTML 内容被 tag stripper 破坏 | D7：Content-Type 检查，非 HTML 直接返回原始文本 |
| SearXNG 未部署时 AI 仍选择 | 返回错误标注在命名空间下，AI 学习避免 |
| 网页抓取反爬/超时 | 15s 超时，错误不阻塞 |
| API key 明文存储于 config.json | 与现有主模型 key 同级别保护；crash dump 使用 MiniDumpNormal（无堆内存）；文档警告用户 |
| API key 存在于 sidecar.log | 日志未记录 auth headers；HTTP body 日志从 INFO 降级为 DEBUG；用户可设 ALIASAGENT_LOG_LEVEL=warn |
| 多 provider 并发时 g_last_tool_result 线程不安全 | D3：每个 provider 独立缓冲区，不共享 g_last_tool_result |
| 无 config hot-reload | 已记录为限制；桌面应用重启即可（符合现有行为） |
| Provider 名称 magic string 分散多文件 | 写入设计文档提醒实施者保持同步；C++ name() 为单一来源，Dart 通过 getSearchProviders() 获取 |
| SSRF via web_fetch | D7 + D10：CURLOPT_OPENSOCKETFUNCTION socket 层验证，覆盖 IPv4/IPv6/DNS rebinding/重定向/大小写 |
| HTTP 429 被当作永久错误 | D6：Kimi 适配器专属重试逻辑；其他 provider 后续迭代 |
| zip bomb / 无限 chunked response | D7：CURLOPT_WRITEFUNCTION 中增量检查累计大小，超 100KB 即中止传输 |
| C++ 异常穿透 FFI 边界 → crash | D9：所有 extern "C" 函数 try/catch → JSON error；provider 线程内 catch → ProviderResult |
| AppConfig.toJson() 回写丢失 search 字段 | Config 流向 Implementation：toJson() 条件性包含非空 search |
| 非 socket 层 IP 检查可被绕过 | D10：核心防护在 CURLOPT_OPENSOCKETFUNCTION 中执行，URL 字符串层 blocklist 降级为辅助 |
| HTTPS→HTTP 重定向降级导致明文传输 | `CURLOPT_REDIR_PROTOCOLS_STR="http,https"` 允许此降级。但 web_fetch 本身接受明文 HTTP URL，重定向降级不引入新的威胁面；内容完整性不属于 web_fetch 的威胁模型 |
