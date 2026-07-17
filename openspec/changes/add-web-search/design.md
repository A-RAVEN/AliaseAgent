# Design: Add Web Search Tool

## Context

当前 Sidecar 通过 `ModelGateway` 与模型 API 通信。`ModelGateway` 是一个完全的 Anthropic 协议实现——SSE 解析 dispatch 的是 Anthropic 事件类型，HTTP 请求格式和 auth headers 不可切换。搜索工具的 ZhipuAI 和 Kimi provider 都需要 OpenAI Chat Completions 兼容的协议，因此需要独立的 HTTP/SSE 传输路径。

三个 provider 覆盖三种搜索范式：搜索引擎 REST API（SearXNG）、AI 驱动 SSE 搜索（ZhipuAI web_browser）、AI 合成答案 SSE（Kimi $web_search）。

## Goals / Non-Goals

**Goals:**
- web_search 工具，主模型自主选择 provider 组合，并行搜索，按命名空间打包结果
- web_fetch 工具，可从 URL 抓取网页纯文本，含 SSRF 防护
- ISearchProvider 抽象层，三种 provider 类型（搜索引擎 REST / AI 驱动 SSE / AI 合成 SSE）
- 三个实现：SearXNG localhost + ZhipuAI web_browser adapter + Kimi $web_search adapter
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
  ├─ ZhipuAISearch:    独立 curl 句柄 + OpenAI SSE parser
  └─ KimiSearch:       独立 curl 句柄 + OpenAI SSE parser
```

**Rationale**: `ModelGateway` 硬编码了 Anthropic 协议的所有方面——URL 路径（`/v1/messages`）、auth header（`x-api-key`）、SSE 事件 type dispatch（`content_block_delta` 等）、tool call 组装流程（`content_block_start`/`content_block_stop`）。OpenAI 兼容 API 使用 `POST /v1/chat/completions`、`Authorization: Bearer`、`choices[0].delta` 事件结构。两者不可互相替代。

**Implementation**: ZhipuAI 和 Kimi 适配器各自创建 curl 句柄，send/receive 逻辑内联在各适配器内部。OpenAI SSE 解析复用 `write_callback` 的行缓冲模式（`line_buf` → split on `\n` → parse `data:` lines），但事件 dispatch 为 OpenAI 格式（`choices[0].delta.content` 用于文本，`choices[0].delta.tool_calls` 用于工具调用）。

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
  std::vector<SearchResult> results;  // 成功时为非空，失败时为空
  SearchError error;                   // 成功时 message 为空
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
      '- zhipuai: AI-driven search + full page extraction (depth=deep). Requires API key.\n'
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
- C++ FFI 函数命名采用 snake_case（与现有 `send_message`/`read_file`/`list_dir` 一致）
- `is_configured()` 只检查内存中的缓存值，不做文件 IO 或网络 IO

### D3: 并行多 provider 执行（含超时和 deadline）

web_fetch 非搜索工具，此处不适用。

Per-provider 超时：
- SearXNG: 5 秒（简单 HTTP GET）
- ZhipuAI: 30 秒/轮（每轮一个 SSE 往返，deep 模式最多 3 轮 = 90 秒上限）
- Kimi: 30 秒（单次 SSE 流）

总 deadline：30 秒。超时后，已完成的 provider 结果 + 未完成 provider 的超时错误一同返回。

**Deadline 执行机制**：使用 `std::future` + `wait_for`，而非 `std::thread` + `join`。`join()` 会无限期阻塞，一旦某 provider 的 curl 调用挂死（如 TCP 分区），整个 worker isolate 永久卡住。正确做法：

```cpp
std::vector<std::future<ProviderResult>> futures;
for (auto& provider : providers) {
  futures.push_back(std::async(std::launch::async, [&]() {
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
    // future 在后台继续运行至自然结束（不影响后续请求）
  }
}
```

每个 provider 的 `search()` 内部通过 `CURLOPT_TIMEOUT` 设置 per-request 超时，确保即使 deadline 未触发，curl 也不会无限 hang。

线程安全：每个 provider 使用自己的 curl 句柄和自己的字符串缓冲区。`std::async` 不共享可变状态。

返回格式采用 per-namespace 结构（见 spec `web-search/spec.md`）。`errors[ns]` 非 null 时 `content[ns]` 必定为空数组。

### D4: ZhipuAI 适配器（OpenAI 传输 + mini agent loop）

```
ZhipuAISearch::search(query, depth, max_results)
  │
  ├─ 构造 prompt + 注册 web_browser tool (msearch, mclick)
  ├─ POST /v1/chat/completions (Authorization: Bearer, OpenAI 格式 body)
  ├─ 拦截 SSE choices[0].delta.tool_calls → msearch →
  │   收集 WebBrowserOutput[]（映射 title/link/content → SearchResult）
  │
  ├─ [仅 deep] 回传 mclick tool_result → 继续 SSE →
  │   收集更多 WebBrowserOutput[]
  │   部分 mclick 失败时：成功的返回全文，失败的保留 msearch snippet
  │
  ├─ 在 finish_reason="stop" 时中止（不收集 ZhipuAI 的合成答案）
  └─ 返回 ProviderResult{results, error}
```

循环级超时：30 秒/轮。多轮总超时 90 秒。任何一轮超时——返回已收集的结果 + 超时错误。

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

```
KimiSearch::search(query, depth, max_results)
  │
  ├─ 构造 body 时注入 `thinking: {type: "disabled"}` ← 必须！
  │   （Kimi 文档明确要求 $web_search 与思考模式不兼容）
  │
  ├─ 注册 $web_search builtin_function
  ├─ POST /v1/chat/completions (Authorization: Bearer, OpenAI 格式)
  ├─ 拦截 SSE: finish_reason=tool_calls + function.name="$web_search"
  │   → 原封不动回传 arguments 作为 tool_result (NO-OP)
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
  │
  ├─ CURLOPT_OPENSOCKETFUNCTION callback（socket 级 SSRF 防护）:
  │   │  在 DNS 解析后、connect() 前触发，可检查已解析的 sockaddr
  │   ├─ 拒绝 IPv4 私有/环回/链路本地:
  │   │   127.0.0.0/8, 10.0.0.0/8, 172.16.0.0/12, 192.168.0.0/16,
  │   │   169.254.0.0/16, 0.0.0.0/8, 100.64.0.0/10
  │   ├─ 拒绝 IPv6 环回/链路本地/ULA:
  │   │   ::1/128, fe80::/10, fc00::/7
  │   ├─ 此 callback 对每次连接都触发（包括 HTTP 重定向后的新连接）
  │   └─ 拒绝时返回 CURL_SOCKOPT_ALREADY_CONNECTED，curl 报告连接失败
  │
  ├─ CURLOPT_WRITEFUNCTION callback（incremental size check）:
  │   │  每收到一块数据，累加已收字节数
  │   ├─ 超过 100KB 时返回 0 → curl 中止传输
  │   └─ 防止 zip bomb / 无限 chunked response 先撑爆内存再 truncate
  │
  ├─ 检查 Content-Type:
  │   ├─ text/html → HTML 标签剥离 + 空白压缩
  │   └─ 其他 → 返回原始文本，100KB 截断
  │
  └─ 错误: 连接失败, TLS 错误, HTTP 4xx/5xx, 超时,
           重定向到内部地址, SSRF 阻止
```

**SSRF 防御核心原则**：验证发生在 socket 层（`CURLOPT_OPENSOCKETFUNCTION`），而非 URL 字符串层。socket 层的 sockaddr 已经是 DNS 解析后的结果，天然免疫 DNS rebinding、IPv6 变体、HTTP 重定向、大小写欺骗。

`extract_mode` 参数 v1 只支持 `"text"`。`"markdown"` 延后到后续 change（需引入 HTML→Markdown 转换库）。

`CURLOPT_FOLLOWLOCATION=1` + `CURLOPT_MAXREDIRS=5`。因为 socket callback 对所有目标都触发 SSRF 验证，重定向是安全的。`CURLOPT_REDIR_PROTOCOLS_STR` 设为 `"http,https"` 防止协议切换攻击。

### D8: Dart 侧异步执行（Isolate）

`web_search` 和 `web_fetch` 的 FFI 调用 SHALL NOT 在主 isolate 上执行。它们 SHALL 遵循 `sendMessage` 的已有模式：`Isolate.spawn` + `SendPort`/`ReceivePort`。

`sidecar_bridge.dart` 中的实现参考现有的 `sendMessage` 包装模式（`sidecar_bridge.dart:112-154`）。

### D9: C++ 异常安全 — FFI 边界保护

**Decision**: 所有 `extern "C"` FFI 函数 MUST catch 所有异常并返回 JSON 错误对象。C++ 异常穿透 C 函数边界属于未定义行为，会导致进程 crash。

```cpp
SIDECAR_API const char* web_search(const char* request_json) {
  try {
    // actual implementation
  } catch (const std::exception& e) {
    static std::string err;
    err = "{\"ok\":false,\"error\":\"" + std::string(e.what()) + "\"}";
    return err.c_str();
  } catch (...) {
    return "{\"ok\":false,\"error\":\"Unknown internal error\"}";
  }
}
```

**每个 provider 线程内部也 SHALL catch 异常**，转换为 `ProviderResult{results={}, error={message, is_transient=false}}`，避免 `std::thread` 中未捕获异常导致 `std::terminate`。

**Implementation**: 参照已有模式——`sidecar_api.cpp` 中 `set_workspace`/`read_file`/`list_dir` 已使用 try/catch + JSON error return（`g_last_tool_result`）。`web_search`/`web_fetch`/`ensure_search_infra`/`get_search_providers` 沿用同一模式。

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
- IPv6: `::1/128`, `fe80::/10`, `fc00::/7`

**Implementation**: 注册 `CURLOPT_OPENSOCKETFUNCTION` callback，其中调用 `getpeername` 或直接检查 `curl_sockaddr.address`。匹配 blocklist 则返回 `CURL_SOCKOPT_ALREADY_CONNECTED` 阻止连接。

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
| ZhipuAI multi-turn 超时无上限（120s × 3 = 360秒） | 每轮 30s 超时，总 90s 上限 |
| SSRF via web_fetch | D7 + D10：CURLOPT_OPENSOCKETFUNCTION socket 层验证，覆盖 IPv4/IPv6/DNS rebinding/重定向/大小写 |
| HTTP 429 被当作永久错误 | D6：Kimi 适配器专属重试逻辑；其他 provider 后续迭代 |
| zip bomb / 无限 chunked response | D7：CURLOPT_WRITEFUNCTION 中增量检查累计大小，超 100KB 即中止传输 |
| C++ 异常穿透 FFI 边界 → crash | D9：所有 extern "C" 函数 try/catch → JSON error；provider 线程内 catch → ProviderResult |
| AppConfig.toJson() 回写丢失 search 字段 | Config 流向 Implementation：toJson() 条件性包含非空 search |
| 非 socket 层 IP 检查可被绕过 | D10：核心防护在 CURLOPT_OPENSOCKETFUNCTION 中执行，URL 字符串层 blocklist 降级为辅助 |
