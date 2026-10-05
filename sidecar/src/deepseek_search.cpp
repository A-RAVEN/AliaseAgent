#include "deepseek_search.h"
#include "logger.h"
#include <nlohmann/json.hpp>
#include <curl/curl.h>
#include <algorithm>
#include <chrono>
#include <unordered_map>
#include <unordered_set>

using json = nlohmann::json;

// ============================================================================
// 常量
// ============================================================================

/// 一次搜索是一次完整的模型调用，实测 4~5.4 秒；超时给 90 秒（与 kimi 同量级，
/// 但更宽，因为它自己要读完网页再回话）。
static const long DEEPSEEK_REQUEST_TIMEOUT_SEC = 90L;
static const long DEEPSEEK_CONNECT_TIMEOUT_SEC = 15L;
static const size_t DEEPSEEK_MAX_RESPONSE_SIZE = 16 * 1024 * 1024; // 16MB
/// 服务端搜索次数固定 1：这个数字是"服务端自己连搜几轮"的上限，每一次都要花钱。
static const int DEEPSEEK_MAX_USES = 1;
static const char* DEEPSEEK_ANTHROPIC_VERSION = "2023-06-01";
/// 参考实现用的固定前缀，查询接在它后面。
static const char* DEEPSEEK_QUERY_PREFIX = "Perform a web search for the query: ";

// 请求体里**不发 `max_tokens`**：输出长度交给服务端默认值，本项目不再自己钉一个数。
// 出处：`Docs/DeepSeekAPIDoc.md` 第 2 节里 `max_tokens` 那一行写着「取值范围为 1 到
// 384K（393216）。未设置时，非思考模式默认 8K，思考模式默认 64K」。曾经这里写死
// 2048 —— 那是我编的数（参考实现用的是 4096，文档默认是 8K），既砍掉过结果、又
// 完全没检查返回有没有被截断。截断现在由 `stop_reason == "max_tokens"` 那一条守
// （见 `map_response()`）。

// 请求必须有超时（到点按失败处理）。这条是编译期就能守住的规矩，改动超时常量时
// 会当场报错。`max_uses` 固定 1 那条不用编译期断言，而是交给请求形状用例去守
// （tasks.md 5.1 要求"把 max_uses 改成 5 时请求形状用例变红"）—— 编译期断言会让
// 那次变异在编译阶段就失败，用例根本跑不到，反而证明不了用例本身有效。
static_assert(DEEPSEEK_REQUEST_TIMEOUT_SEC > 0, "请求必须设超时，到点按失败处理");

// ============================================================================
// 小工具
// ============================================================================

/// 把不合法的 UTF-8 字节换成替换字符（U+FFFD）。与
/// `sidecar/src/command_tool.cpp` 里 `sanitize_utf8` 同一套判定规则，只是不做
/// 换行归一 —— 这里处理的是标题，原样保留其换行意图。
/// 实测标题会带坏字节（cctv 那条中文标题被打错），所以这不是理论问题。
static std::string sanitize_utf8_keep_newlines(const std::string& in) {
  std::string out;
  out.reserve(in.size());
  size_t i = 0;
  auto is_cont = [](unsigned char b) { return (b & 0xC0) == 0x80; };
  while (i < in.size()) {
    const unsigned char b = static_cast<unsigned char>(in[i]);
    size_t len = 0;
    if (b < 0x80) {
      len = 1;
    } else if ((b & 0xE0) == 0xC0) {
      len = 2;
    } else if ((b & 0xF0) == 0xE0) {
      len = 3;
    } else if ((b & 0xF8) == 0xF0) {
      len = 4;
    }
    bool ok = len > 0 && i + len <= in.size();
    if (ok) {
      for (size_t k = 1; k < len; ++k) {
        if (!is_cont(static_cast<unsigned char>(in[i + k]))) {
          ok = false;
          break;
        }
      }
      if (ok && len == 2 && b < 0xC2) ok = false;  // 过长编码不接受
      if (ok && len == 3 && b == 0xE0 && static_cast<unsigned char>(in[i + 1]) < 0xA0) ok = false;
      if (ok && len == 4 && b == 0xF0 && static_cast<unsigned char>(in[i + 1]) < 0x90) ok = false;
    }
    if (ok) {
      out.append(in, i, len);
      i += len;
    } else {
      out += "\xEF\xBF\xBD";  // U+FFFD
      i += 1;
    }
  }
  return out;
}

/// 从前缀里取一个字符串字段；字段不存在、不是字符串、或含坏字节都不抛异常。
static std::string safe_string(const json& obj, const char* key) {
  if (!obj.is_object() || !obj.contains(key)) return std::string();
  const json& v = obj[key];
  if (!v.is_string()) return std::string();
  return sanitize_utf8_keep_newlines(v.get<std::string>());
}

// ============================================================================
// 地址判定与调用地址
// ============================================================================

bool deepseek_address_is_deepseek(const std::string& base_url) {
  return base_url.find("api.deepseek.com") != std::string::npos;
}

std::string deepseek_build_request_url(const std::string& base_url) {
  std::string url = base_url;
  while (!url.empty() && (url.back() == '/' || url.back() == ' ')) url.pop_back();
  if (url.empty()) return url;
  const std::string suffix = "/messages";
  if (url.size() >= suffix.size() &&
      url.compare(url.size() - suffix.size(), suffix.size(), suffix) == 0) {
    return url;  // 已经是调用地址
  }
  // `.../anthropic` 与 `.../anthropic/v1` 都要落到 `.../v1/messages` 上
  if (url.size() >= 3 && url.compare(url.size() - 3, 3, "/v1") == 0) {
    return url + suffix;
  }
  return url + "/v1" + suffix;
}

// ============================================================================
// 全局实例
// ============================================================================

static std::shared_ptr<DeepSeekSearch> g_deepseek_instance;

std::shared_ptr<DeepSeekSearch> get_deepseek_provider() {
  if (!g_deepseek_instance) {
    g_deepseek_instance = std::make_shared<DeepSeekSearch>();
  }
  return g_deepseek_instance;
}

// ============================================================================
// is_configured —— 凭据闸门的落地
// ============================================================================

bool DeepSeekSearch::is_configured() const {
  // 判定只有一处：`search_provider.cpp` 的注册段按闸门规则算好后写进 gate_passed_，
  // 这里如实转述。为什么不在这儿重新按"地址含 api.deepseek.com"算一遍：自己把密钥
  // 与地址都写全的用户，地址可以不指向 DeepSeek（那时没碰会话模型的任何东西），
  // 那种情况在"密钥 / 地址"两个字段里看不出来。
  return gate_passed_ && !api_key_.empty() && !base_url_.empty();
}

// ============================================================================
// 请求体构造
// ============================================================================

std::string DeepSeekSearch::build_request_body(const std::string& query) const {
  // 故意不写 `max_tokens`：见文件顶部那段注释。服务端未设置时的默认值是 8K
  // （`Docs/DeepSeekAPIDoc.md` 第 2 节 `max_tokens` 行），比原来那个自定的 2048 宽。
  json body;
  body["model"] = model_;
  body["messages"] = json::array({
    {{"role", "user"},
     {"content", json::array({
        {{"type", "text"}, {"text", std::string(DEEPSEEK_QUERY_PREFIX) + query}}
     })}}
  });
  body["tools"] = json::array({
    {{"type", "web_search_20250305"}, {"name", "web_search"}, {"max_uses", DEEPSEEK_MAX_USES}}
  });
  return body.dump();
}

// ============================================================================
// 返回映射 —— 纯函数，不联网
// ============================================================================

ProviderResult DeepSeekSearch::map_response(
  const std::string& response_body,
  int max_results,
  bool& fatal
) {
  ProviderResult result;
  fatal = false;

  json resp;
  try {
    resp = json::parse(response_body);
  } catch (const json::parse_error& first_error) {
    // 标题里出现非法 UTF-8 是实测会发生的（中文站点的标题被打错）。JSON 解析器遇到
    // 这种字节会整包拒绝，所以先按"把坏字节换成替换字符"清洗一遍再解析一次 ——
    // 解析成功就继续（坏字节按替换字符呈现），仍然失败才算真的解析失败。
    try {
      resp = json::parse(sanitize_utf8_keep_newlines(response_body));
      LOG_WARN("DeepSeek: 返回含非法 UTF-8 字节，已替换成替换字符后重新解析成功");
    } catch (const json::parse_error& e) {
      fatal = true;
      result.error = {std::string("返回不是合法的 JSON — ") + e.what(), false};
      return result;
    }
  }

  if (max_results < 1) max_results = 1;

  // ---- 先看这次调用有没有被输出长度截断 ----
  // 请求里不再自己钉 `max_tokens`（用平台默认），所以截断只能由**服务端的取值**看
  // 出来：`stop_reason == "max_tokens"` 表示"到了输出上限"（出处：
  // `Docs/AnthropicAPIDoc.md` 1.5.1 节「we exceeded the requested `max_tokens` or the
  // model's maximum」）。这种情况必须报错，不许把拿到的半截结果当成功返回。
  const std::string stop_reason = safe_string(resp, "stop_reason");
  if (stop_reason == "max_tokens") {
    fatal = true;
    result.error = {
      "这次调用的输出被服务端截断了（stop_reason=max_tokens），结果可能不全；"
      "可以换一个输出更长的模型或稍后重试",
      false
    };
    return result;
  }

  // ---- 第一遍：把结果块里的条目全收下来（不按 server_tool_use 配对 —— 实测
  //      两者个数不是一对一），同时把引用片段按网址记下来 ----
  std::vector<SearchResult> collected;
  std::vector<std::string> order;                       // 去重用的出现顺序
  std::unordered_set<std::string> seen;
  std::unordered_map<std::string, std::string> citations;  // 网址 → 引用片段
  int result_blocks = 0;
  int dropped_no_url = 0;

  if (resp.is_object() && resp.contains("content") && resp["content"].is_array()) {
    for (const auto& block : resp["content"]) {
      if (!block.is_object()) continue;
      const std::string type = safe_string(block, "type");

      if (type == "web_search_tool_result") {
        result_blocks++;
        // 这个块本身可能就是一条错误（服务端搜索失败），那种情况不产生条目
        if (!block.contains("content") || !block["content"].is_array()) continue;
        for (const auto& item : block["content"]) {
          if (!item.is_object()) continue;
          if (safe_string(item, "type") != "web_search_result") continue;
          SearchResult r;
          r.url = safe_string(item, "url");
          r.title = safe_string(item, "title");
          // `page_age` 在返回里存在，但实测三次全空 —— 为空是常态，不丢结果
          r.content = safe_string(item, "page_age");
          if (r.url.empty()) {
            dropped_no_url++;
            continue;  // 没有网址的结果在界面上点不开，也不是引用片段能对上的键
          }
          if (seen.insert(r.url).second) {
            order.push_back(r.url);
            collected.push_back(std::move(r));
          }
        }
      } else if (type == "text") {
        if (!block.contains("citations") || !block["citations"].is_array()) continue;
        for (const auto& cite : block["citations"]) {
          if (!cite.is_object()) continue;
          const std::string url = safe_string(cite, "url");
          const std::string cited = safe_string(cite, "cited_text");
          if (url.empty() || cited.empty()) continue;
          citations[url] = cited;  // 同一网址后出现的引用片段覆盖先出现的
        }
      }
    }
  }

  // ---- 第二遍：正文按网址对应引用片段；没有引用时用标题兜底 ----
  std::vector<SearchResult> mapped;
  mapped.reserve(collected.size());
  for (auto& r : collected) {
    SearchResult out;
    out.url = r.url;
    out.title = r.title;
    auto it = citations.find(r.url);
    if (it != citations.end() && !it->second.empty()) {
      out.content = it->second;
    } else {
      // 没有摘要：这是"没有摘要"，不是真摘要 —— 不塞编造的内容，用标题兜底
      out.content = r.title;
    }
    mapped.push_back(std::move(out));
  }

  LOG_INFO("DeepSeek search: 结果块 " + std::to_string(result_blocks) +
           " 个、条目 " + std::to_string(mapped.size()) +
           " 条、引用片段 " + std::to_string(citations.size()) +
           " 条、无网址被丢 " + std::to_string(dropped_no_url) + " 条");

  // ---- "一个结果块都没有"与"有结果块但零条结果"是两种不同情况 ----
  if (result_blocks == 0) {
    fatal = true;
    result.error = {"这次调用没有触发服务端搜索（返回里没有 web_search_tool_result 块）",
                    false};
    return result;
  }

  // ---- 条数上限由我们按顺序截断（服务端不提供这个旋钮）----
  if (static_cast<int>(mapped.size()) > max_results) {
    mapped.resize(static_cast<size_t>(max_results));
  }

  result.results = std::move(mapped);
  return result;
}

// ============================================================================
// 响应体积越界 —— 判定与说明（抽出来是为了能在单测里直接跑）
// ============================================================================

DeepSeekSearch::SizeCheck DeepSeekSearch::check_response_size(
  size_t limit, size_t already, size_t incoming) {
  SizeCheck out;
  out.received_bytes = already + incoming;
  out.overflow = out.received_bytes > limit;
  return out;
}

std::string DeepSeekSearch::describe_size_overflow(size_t limit, size_t received) {
  // 这个上限是**内存保护**，不是内容预算：谁都不希望一个坏掉的端点把进程吃爆。
  // 但越界时必须交代清楚"被拒的是什么、多大、丢了多少"，否则模型只会看到一句
  // 含糊的失败，无法判断是端点的问题还是自己的问题。
  return "响应超过上限 " + std::to_string(limit) + " 字节（已收到 " +
         std::to_string(received) + " 字节），本次结果不完整";
}

// ============================================================================
// 真实传输层（libcurl）—— 一次 POST，拿整包 JSON，不流式
// ============================================================================

namespace {

struct WriteCtx {
  std::string body;
  bool overflow = false;
  /// 越界时"如果把这些也收下会到多少字节"（即本次回调原本要追加的总量 + 已收到）。
  /// 只用于事后说明；不参与判定。
  size_t would_be_size = 0;
};

size_t write_callback(char* ptr, size_t size, size_t nmemb, void* userdata) {
  auto* ctx = static_cast<WriteCtx*>(userdata);
  const size_t total = size * nmemb;
  const auto decision = DeepSeekSearch::check_response_size(
    DEEPSEEK_MAX_RESPONSE_SIZE, ctx->body.size(), total);
  if (decision.overflow) {
    ctx->overflow = true;
    ctx->would_be_size = decision.received_bytes;
    return 0;  // 中止传输
  }
  ctx->body.append(ptr, total);
  return total;
}

class CurlTransport : public DeepSeekSearch::Transport {
public:
  std::string post(
    const std::string& url,
    const std::string& api_key,
    const std::string& body,
    long& http_code,
    std::string& response_body
  ) override {
    http_code = 0;
    response_body.clear();

    CURL* curl = curl_easy_init();
    if (!curl) return "curl_easy_init 失败";

    struct curl_slist* headers = nullptr;
    headers = curl_slist_append(headers, "Content-Type: application/json");
    const std::string auth = "x-api-key: " + api_key;
    headers = curl_slist_append(headers, auth.c_str());
    const std::string ver = std::string("anthropic-version: ") + DEEPSEEK_ANTHROPIC_VERSION;
    headers = curl_slist_append(headers, ver.c_str());

    curl_easy_setopt(curl, CURLOPT_URL, url.c_str());
    curl_easy_setopt(curl, CURLOPT_POST, 1L);
    curl_easy_setopt(curl, CURLOPT_POSTFIELDS, body.c_str());
    curl_easy_setopt(curl, CURLOPT_POSTFIELDSIZE, (long)body.size());
    curl_easy_setopt(curl, CURLOPT_HTTPHEADER, headers);
    curl_easy_setopt(curl, CURLOPT_WRITEFUNCTION, write_callback);
    curl_easy_setopt(curl, CURLOPT_TIMEOUT, DEEPSEEK_REQUEST_TIMEOUT_SEC);
    curl_easy_setopt(curl, CURLOPT_CONNECTTIMEOUT, DEEPSEEK_CONNECT_TIMEOUT_SEC);
    curl_easy_setopt(curl, CURLOPT_USERAGENT, "AliasAgent/1.0");
    curl_easy_setopt(curl, CURLOPT_SSL_VERIFYPEER, 1L);
    curl_easy_setopt(curl, CURLOPT_ACCEPT_ENCODING, "");

    WriteCtx ctx;
    curl_easy_setopt(curl, CURLOPT_WRITEDATA, &ctx);

    const CURLcode cres = curl_easy_perform(curl);
    curl_easy_getinfo(curl, CURLINFO_RESPONSE_CODE, &http_code);
    curl_easy_cleanup(curl);
    curl_slist_free_all(headers);

    response_body = std::move(ctx.body);

    if (cres != CURLE_OK) {
      std::string err = "连接失败 — " + std::string(curl_easy_strerror(cres));
      if (cres == CURLE_OPERATION_TIMEDOUT) {
        err = "超时（" + std::to_string(DEEPSEEK_REQUEST_TIMEOUT_SEC) + " 秒内没有响应）";
      }
      if (ctx.overflow) {
        err += "（" + DeepSeekSearch::describe_size_overflow(
                           DEEPSEEK_MAX_RESPONSE_SIZE, ctx.would_be_size) + "）";
      }
      return err;
    }
    return std::string();  // 传输成功（HTTP 状态码另看）
  }
};

CurlTransport& real_transport() {
  static CurlTransport instance;
  return instance;
}

/// 从错误的返回体里尽量抠出一句人能看懂的原因。
std::string describe_error_body(const std::string& body) {
  if (body.empty()) return std::string();
  try {
    auto j = json::parse(body);
    if (j.contains("error") && j["error"].is_object() &&
        j["error"].contains("message") && j["error"]["message"].is_string()) {
      return j["error"]["message"].get<std::string>();
    }
    if (j.contains("message") && j["message"].is_string()) {
      return j["message"].get<std::string>();
    }
  } catch (...) {}
  return std::string();
}

/// 从返回里读一段"这次调用花了多少"的说明，用来写进日志。
/// 一次搜索 = 一次完整的模型调用，成本只能从这里的 token 数看出来；读不到就返回
/// 空串（不估、不编）。
std::string DeepSeekSearch_describe_usage_impl(const std::string& response_body) {
  try {
    const auto j = json::parse(response_body);
    if (!j.is_object() || !j.contains("usage") || !j["usage"].is_object()) {
      return std::string();
    }
    const auto& u = j["usage"];
    std::string out;
    auto append_int = [&out](const json& obj, const char* key, const char* label) {
      if (obj.contains(key) && obj[key].is_number_integer()) {
        if (!out.empty()) out += " / ";
        out += std::string(label) + "=" + std::to_string(obj[key].get<long long>());
      }
    };
    append_int(u, "input_tokens", "input_tokens");
    append_int(u, "output_tokens", "output_tokens");
    if (u.contains("server_tool_use") && u["server_tool_use"].is_object() &&
        u["server_tool_use"].contains("web_search_requests") &&
        u["server_tool_use"]["web_search_requests"].is_number_integer()) {
      if (!out.empty()) out += " / ";
      out += "web_search_requests=" +
             std::to_string(u["server_tool_use"]["web_search_requests"].get<long long>());
    }
    return out;
  } catch (...) {
    return std::string();
  }
}

/// 把一句可读说明与"本次实际使用的地址"拼起来 —— 好让"端点配错了"与"查询写
/// 错了"能区分开。规范要求**每一条失败说明**都带上实际地址。
std::string with_address(const std::string& what, const std::string& url) {
  return "DeepSeek: " + what + "（本次使用的地址：" + url + "）";
}

/// HTTP 非 2xx 时的失败结果：说明里带状态码、能抠出来的服务端原因、以及实际地址；
/// 429 与 5xx 算可重试。
ProviderResult http_failure(long http_code, const std::string& response_body,
                            const std::string& url) {
  std::string what = "HTTP " + std::to_string(http_code);
  const std::string detail = describe_error_body(response_body);
  if (!detail.empty()) what += " — " + detail;
  ProviderResult result;
  result.error = {with_address(what, url), (http_code == 429 || http_code >= 500)};
  return result;
}

}  // namespace

// ============================================================================
// 用量说明（给日志用）
// ============================================================================

std::string DeepSeekSearch::describe_usage(const std::string& response_body) {
  return DeepSeekSearch_describe_usage_impl(response_body);
}

// ============================================================================
// search —— 一次 POST + 映射
// ============================================================================

ProviderResult DeepSeekSearch::search(
  const std::string& query,
  const std::string& depth,
  int max_results
) {
  (void)depth;  // 服务端搜索没有"深度"这个旋钮
  ProviderResult result;
  const std::string url = deepseek_build_request_url(base_url_);

  // ---- 闸门：凭据不可用时**不发任何请求** ----
  if (!is_configured()) {
    result.error = {
      "DeepSeek 搜索不可用：缺少可用的密钥，或地址不指向 DeepSeek"
      "（本次地址：" + (url.empty() ? std::string("未配置") : url) + "）",
      false
    };
    return result;
  }

  if (query.empty()) {
    result.error = {with_address("搜索查询是空的", url), false};
    return result;
  }

  if (max_results < 1) max_results = 1;

  const std::string body = build_request_body(query);
  LOG_INFO("DeepSeek 搜索：query=\"" + query + "\" url=" + url +
           " model=" + model_ + " max_results=" + std::to_string(max_results));

  const auto started = std::chrono::steady_clock::now();
  long http_code = 0;
  std::string response_body;
  Transport* transport = transport_override_ ? transport_override_ : &real_transport();
  const std::string transport_error = transport->post(url, api_key_, body, http_code, response_body);
  const auto elapsed_ms = std::chrono::duration_cast<std::chrono::milliseconds>(
    std::chrono::steady_clock::now() - started).count();

  if (!transport_error.empty()) {
    result.error = {with_address(transport_error, url), true};
    LOG_ERR(result.error.message);
    return result;
  }

  if (http_code >= 400 || http_code == 0) {
    result = http_failure(http_code, response_body, url);
    LOG_ERR(result.error.message);
    return result;
  }

  LOG_INFO("DeepSeek 搜索：HTTP " + std::to_string(http_code) +
           " 用时 " + std::to_string(elapsed_ms) + "ms 返回 " +
           std::to_string(response_body.size()) + " 字节");
  // 成本只能从这次调用的 token 数看出来（一次搜索 = 一次完整模型调用）
  const std::string usage = describe_usage(response_body);
  LOG_INFO("DeepSeek 搜索：用量 " + (usage.empty() ? std::string("读不到（返回里没有 usage）") : usage));

  bool fatal = false;
  ProviderResult mapped = map_response(response_body, max_results, fatal);
  if (fatal) {
    // "没有结果块"要能看出是哪个端点没触发搜索
    mapped.error.message = with_address(mapped.error.message, url);
    LOG_ERR(mapped.error.message);
  }
  return mapped;
}
