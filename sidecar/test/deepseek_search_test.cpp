// `deepseek` 搜索后端的 C++ 单测（tasks.md 4.1 / 4.2 / 4.3）。
//
// 覆盖：请求体的固定形状（查询前缀、服务端搜索工具的 type 与 max_uses、没有流式
// 开关）；调用地址的拼法；结果块的映射（网址 / 标题 / 日期 / 按网址去重）；引用片段
// 按网址对应成正文；没有引用时用标题兜底；标题含非法字节不崩；`page_age` 为空不丢
// 结果；`max_results` 按顺序截断；有结果块但零条结果算成功；没有结果块时明确报错；
// 传输层失败、HTTP 非 200、超时的说明里都带本次实际地址。
//
// **离线**：本文件不联网。返回映射是纯函数（喂响应文本即可）；请求构造与失败路径
// 走 `DeepSeekSearch::set_transport()` 注入的替身，替身只记账、不出网。
#include <catch2/catch_all.hpp>

#include <string>
#include <vector>

#include <nlohmann/json.hpp>

#include "deepseek_search.h"
#include "search_provider.h"

using nlohmann::json;

namespace {

const char* kTestKey = "sk-test-key";
const char* kTestBase = "https://api.deepseek.com/anthropic";
const char* kExpectedUrl = "https://api.deepseek.com/anthropic/v1/messages";

/// 传输层替身：记账，不出网。把它当作"是否发过请求"的唯一依据 ——
/// 安全边界用例就是断言它**一次都没被调用**（不是"发出去了然后失败"）。
class StubTransport : public DeepSeekSearch::Transport {
public:
  std::string fail_with;      // 非空则模拟传输层失败（例如超时）
  long http_code = 200;
  std::string response_body;
  int calls = 0;
  std::string seen_url;
  std::string seen_api_key;
  std::string seen_body;

  std::string post(
    const std::string& url,
    const std::string& api_key,
    const std::string& body,
    long& out_http_code,
    std::string& out_response_body
  ) override {
    ++calls;
    seen_url = url;
    seen_api_key = api_key;
    seen_body = body;
    out_http_code = http_code;
    out_response_body = response_body;
    return fail_with;
  }
};

DeepSeekSearch make_provider() {
  DeepSeekSearch p;
  p.set_section_present(true);
  p.set_api_key(kTestKey);
  p.set_base_url(kTestBase);
  p.set_gate_passed(true);  // 真实路径上由 search_provider.cpp 的注册段判定后设置
  return p;
}

std::string ok_body_with(const std::string& blocks_json) {
  return std::string("{\"content\":[") + blocks_json + "]}";
}

std::string result_block(const std::string& items_json) {
  return std::string("{\"type\":\"web_search_tool_result\",\"content\":[") + items_json + "]}";
}

std::string result_item(const std::string& url, const std::string& title) {
  json item;
  item["type"] = "web_search_result";
  item["url"] = url;
  item["title"] = title;
  item["page_age"] = "";
  return item.dump();
}

ProviderResult map_json(const std::string& body, int max_results) {
  bool fatal = false;
  return DeepSeekSearch::map_response(body, max_results, fatal);
}

}  // namespace

// ============================================================================
// 请求体形状（放 5.1 那条变异的地方）
// ============================================================================

TEST_CASE("deepseek: 请求体是固定形状", "[deepseek]") {
  auto p = make_provider();
  const json body = json::parse(p.build_request_body("上海 天气"));

  // 固定前缀，查询接在它后面
  REQUIRE(body["messages"].size() == 1);
  REQUIRE(body["messages"][0]["role"] == "user");
  REQUIRE(body["messages"][0]["content"].size() == 1);
  REQUIRE(body["messages"][0]["content"][0]["type"] == "text");
  REQUIRE(body["messages"][0]["content"][0]["text"] ==
          "Perform a web search for the query: 上海 天气");

  // 服务端搜索工具：type 与 max_uses 固定
  REQUIRE(body["tools"].size() == 1);
  REQUIRE(body["tools"][0]["type"] == "web_search_20250305");
  REQUIRE(body["tools"][0]["name"] == "web_search");
  REQUIRE(body["tools"][0]["max_uses"] == 1);

  // 模型可配、缺省一个轻量模型
  REQUIRE(body["model"] == "deepseek-v4-flash");
  p.set_model("deepseek-v4");
  REQUIRE(json::parse(p.build_request_body("x"))["model"] == "deepseek-v4");

  // 没有流式开关
  const std::string raw = p.build_request_body("x");
  REQUIRE(raw.find("stream") == std::string::npos);

  // 请求体里**没有** `max_tokens`：输出长度交给服务端默认值（未设置时 8K，
  // 见 Docs/DeepSeekAPIDoc.md 第 2 节）。曾经这里被我写死成 2048，是个编出来的数，
  // 会把结果砍掉且不报 —— 所以这条断言要一直守着"不许再钉一个自己的上限"。
  REQUIRE(body.contains("max_tokens") == false);
  REQUIRE(raw.find("max_tokens") == std::string::npos);
}

TEST_CASE("deepseek: 调用地址拼成 /v1/messages", "[deepseek]") {
  REQUIRE(deepseek_build_request_url("https://api.deepseek.com/anthropic") ==
          "https://api.deepseek.com/anthropic/v1/messages");
  REQUIRE(deepseek_build_request_url("https://api.deepseek.com/anthropic/v1") ==
          "https://api.deepseek.com/anthropic/v1/messages");
  REQUIRE(deepseek_build_request_url("https://api.deepseek.com/anthropic/v1/messages") ==
          "https://api.deepseek.com/anthropic/v1/messages");
  REQUIRE(deepseek_build_request_url("https://api.deepseek.com/anthropic/") ==
          "https://api.deepseek.com/anthropic/v1/messages");
  // 地址判定的唯一依据是字符串里含 api.deepseek.com
  REQUIRE(deepseek_address_is_deepseek("https://api.deepseek.com/anthropic"));
  REQUIRE_FALSE(deepseek_address_is_deepseek("https://gateway.example.com/v1"));
  REQUIRE_FALSE(deepseek_address_is_deepseek(""));
}

// ============================================================================
// 结果映射
// ============================================================================

TEST_CASE("deepseek: 结果块被映射成搜索结果且按网址去重", "[deepseek]") {
  const std::string body = ok_body_with(
    result_block(result_item("https://a.example/1", "第一条")) + "," +
    result_block(result_item("https://b.example/2", "第二条") + "," +
                 result_item("https://a.example/1", "重复的网址")));

  auto r = map_json(body, 10);
  INFO("错误 = " << r.error.message);
  REQUIRE(r.error.message.empty());
  REQUIRE(r.results.size() == 2);
  REQUIRE(r.results[0].url == "https://a.example/1");
  REQUIRE(r.results[0].title == "第一条");  // 先出现的留下
  REQUIRE(r.results[1].url == "https://b.example/2");
}

TEST_CASE("deepseek: 有结果块但零条结果是成功（搜到 0 条）", "[deepseek]") {
  const std::string body = ok_body_with(
    result_block("") + "," + result_block(""));

  auto r = map_json(body, 10);
  INFO("错误 = " << r.error.message);
  REQUIRE(r.error.message.empty());
  REQUIRE(r.results.empty());
}

TEST_CASE("deepseek: 没有结果块时明确报错", "[deepseek]") {
  const std::string body = ok_body_with(
    "{\"type\":\"thinking\",\"thinking\":\"想一下\"},"
    "{\"type\":\"text\",\"text\":\"我搜到了三条，分别是……\"}");

  auto r = map_json(body, 10);
  INFO("错误 = " << r.error.message);
  REQUIRE_FALSE(r.error.message.empty());
  REQUIRE(r.error.message.find("没有触发服务端搜索") != std::string::npos);
  // 不许回退成把模型写的文字当结果、也不许当成"搜到 0 条"
  REQUIRE(r.results.empty());
}

TEST_CASE("deepseek: 模型写的回答不作为结果内容", "[deepseek]") {
  const std::string answer = "这是一篇模型读完网页写的回答，里面有结论。";
  const std::string body = ok_body_with(
    std::string("{\"type\":\"text\",\"text\":\"") + answer + "\"}," +
    result_block(result_item("https://a.example/1", "第一条")));

  auto r = map_json(body, 10);
  REQUIRE(r.results.size() == 1);
  REQUIRE(r.results[0].content.find(answer) == std::string::npos);
  // 没有引用片段 → 正文用标题兜底（这是"没有摘要"，不是真摘要）
  REQUIRE(r.results[0].content == "第一条");
}

TEST_CASE("deepseek: 引用片段按网址对应成正文", "[deepseek]") {
  const std::string cited = "网页里被引用的那一段原文。";
  json text_block;
  text_block["type"] = "text";
  text_block["text"] = "模型写的回答";
  text_block["citations"] = json::array({
    {{"type", "web_search_result_location"},
     {"url", "https://a.example/1"},
     {"cited_text", cited}},
    {{"type", "web_search_result_location"},
     {"url", "https://other.example/9"},
     {"cited_text", "另一条对不上任何结果的引用"}}
  });

  const std::string body = ok_body_with(
    result_block(result_item("https://a.example/1", "第一条")) + "," +
    text_block.dump());

  auto r = map_json(body, 10);
  REQUIRE(r.results.size() == 1);
  REQUIRE(r.results[0].content == cited);
}

TEST_CASE("deepseek: 标题含非法字节不崩且被替换", "[deepseek]") {
  // 手写 JSON：标题是「中」+ 两个落单的后续字节（实测标题里出现过这种坏字节）。
  // 故意不用 nlohmann 构造 —— 它在序列化时就拒绝这种字节，而服务端真的会这么发。
  const std::string raw = ok_body_with(
    "{\"type\":\"web_search_tool_result\",\"content\":["
    "{\"type\":\"web_search_result\",\"url\":\"https://a.example/1\","
    "\"title\":\"\xE4\xB8\xAD\xE6\x96\",\"page_age\":\"\"}]}," +
    result_block(result_item("https://b.example/2", "正常标题")));

  REQUIRE_NOTHROW(map_json(raw, 10));
  auto r = map_json(raw, 10);
  INFO("错误 = " << r.error.message);
  REQUIRE(r.error.message.empty());
  REQUIRE(r.results.size() == 2);
  REQUIRE(r.results[0].title == "\xE4\xB8\xAD\xEF\xBF\xBD\xEF\xBF\xBD");  // 中 + 两个替换字符
  REQUIRE(r.results[1].title == "正常标题");  // 其它结果不受影响
}

TEST_CASE("deepseek: page_age 为空不丢结果", "[deepseek]") {
  json item;
  item["type"] = "web_search_result";
  item["url"] = "https://a.example/1";
  item["title"] = "没有日期的结果";
  item["page_age"] = "";  // 实测三次全空，这是常态

  auto r = map_json(ok_body_with(result_block(item.dump())), 10);
  INFO("错误 = " << r.error.message);
  REQUIRE(r.error.message.empty());
  REQUIRE(r.results.size() == 1);

  // 字段缺失也不能丢
  json no_age = item;
  no_age.erase("page_age");
  auto r2 = map_json(ok_body_with(result_block(no_age.dump())), 10);
  REQUIRE(r2.results.size() == 1);
}

TEST_CASE("deepseek: 响应体积越界要报出上限与已收字节数", "[deepseek]") {
  // 这条守的是 7.3 那类"悄悄中止"：越界时说明里必须同时有上限与收到了多少，
  // 好让人判断是端点坏了还是自己在拉一个巨大的东西。
  const size_t limit = 16 * 1024 * 1024;

  auto ok = DeepSeekSearch::check_response_size(limit, 0, 1024);
  REQUIRE_FALSE(ok.overflow);
  REQUIRE(ok.received_bytes == 1024);

  auto just_over = DeepSeekSearch::check_response_size(limit, limit, 1);
  REQUIRE(just_over.overflow);

  const std::string msg = DeepSeekSearch::describe_size_overflow(limit, just_over.received_bytes);
  INFO("说明 = " << msg);
  REQUIRE(msg.find(std::to_string(limit)) != std::string::npos);          // 上限
  REQUIRE(msg.find(std::to_string(limit + 1)) != std::string::npos);      // 已收到（含本次）
  REQUIRE(msg.find("不完整") != std::string::npos);                        // 丢了多少的口径
}

TEST_CASE("deepseek: 输出被截断时明确报错（stop_reason=max_tokens）", "[deepseek]") {
  // 请求里不再自己钉 max_tokens ⇒ 截断只能从服务端的取值看出来。这条守的是
  // "拿到的半截结果不许当成功返回"。
  json body = json::parse(ok_body_with(
    result_block(result_item("https://a.example/1", "第一条"))));
  body["stop_reason"] = "max_tokens";

  bool fatal = false;
  auto r = DeepSeekSearch::map_response(body.dump(), 10, fatal);
  INFO("错误 = " << r.error.message);
  REQUIRE(fatal);
  REQUIRE(r.error.message.find("截断") != std::string::npos);
  REQUIRE(r.error.message.find("max_tokens") != std::string::npos);
  REQUIRE(r.results.empty());  // 半截结果不许当成功交出去
}

TEST_CASE("deepseek: 正常结束不受截断检查影响（stop_reason=end_turn）", "[deepseek]") {
  json body = json::parse(ok_body_with(
    result_block(result_item("https://a.example/1", "第一条"))));
  body["stop_reason"] = "end_turn";

  bool fatal = false;
  auto r = DeepSeekSearch::map_response(body.dump(), 10, fatal);
  INFO("错误 = " << r.error.message);
  REQUIRE_FALSE(fatal);
  REQUIRE(r.error.message.empty());
  REQUIRE(r.results.size() == 1);

  // 字段完全缺失（有些兼容端点不返回它）同样不许误判成截断
  bool fatal2 = false;
  auto r2 = DeepSeekSearch::map_response(
    ok_body_with(result_block(result_item("https://a.example/2", "第二条"))), 10, fatal2);
  REQUIRE_FALSE(fatal2);
  REQUIRE(r2.results.size() == 1);
}

TEST_CASE("deepseek: 超出上限时按顺序截断", "[deepseek]") {
  std::string items;
  for (int i = 1; i <= 10; ++i) {
    if (i > 1) items += ",";
    items += result_item("https://a.example/" + std::to_string(i),
                         "第 " + std::to_string(i) + " 条");
  }

  auto r = map_json(ok_body_with(result_block(items)), 3);
  REQUIRE(r.results.size() == 3);
  REQUIRE(r.results[0].url == "https://a.example/1");
  REQUIRE(r.results[2].url == "https://a.example/3");
}

// ============================================================================
// 失败路径（全部经替身，不联网）
// ============================================================================

TEST_CASE("deepseek: 传输层失败时说明带实际地址", "[deepseek]") {
  StubTransport stub;
  stub.fail_with = "超时（90 秒内没有响应）";

  auto p = make_provider();
  p.set_transport(&stub);
  auto r = p.search("任意查询", "basic", 5);
  p.set_transport(nullptr);

  REQUIRE(stub.calls == 1);
  REQUIRE(stub.seen_url == kExpectedUrl);
  REQUIRE(stub.seen_api_key == kTestKey);
  REQUIRE(r.results.empty());
  INFO("错误 = " << r.error.message);
  REQUIRE(r.error.message.find("超时") != std::string::npos);
  REQUIRE(r.error.message.find(kExpectedUrl) != std::string::npos);
  REQUIRE(r.error.is_transient);
}

TEST_CASE("deepseek: HTTP 非 200 时说明带状态码、服务端原因与实际地址", "[deepseek]") {
  StubTransport stub;
  stub.http_code = 401;
  stub.response_body = R"({"error":{"message":"Authentication Fails"}})";

  auto p = make_provider();
  p.set_transport(&stub);
  auto r = p.search("任意查询", "basic", 5);
  p.set_transport(nullptr);

  INFO("错误 = " << r.error.message);
  REQUIRE(r.error.message.find("401") != std::string::npos);
  REQUIRE(r.error.message.find("Authentication Fails") != std::string::npos);
  REQUIRE(r.error.message.find(kExpectedUrl) != std::string::npos);
}

TEST_CASE("deepseek: 没有触发搜索时说明里既有原因也有实际地址", "[deepseek]") {
  StubTransport stub;
  stub.response_body = ok_body_with("{\"type\":\"text\",\"text\":\"没搜\"}");

  auto p = make_provider();
  p.set_transport(&stub);
  auto r = p.search("任意查询", "basic", 5);
  p.set_transport(nullptr);

  INFO("错误 = " << r.error.message);
  REQUIRE(r.error.message.find("没有触发服务端搜索") != std::string::npos);
  REQUIRE(r.error.message.find(kExpectedUrl) != std::string::npos);
}

// ============================================================================
// 安全边界（5.5 那条变异的地方）
// ============================================================================

TEST_CASE("deepseek: 地址不是 DeepSeek 时不可用且不发出任何请求", "[deepseek]") {
  StubTransport stub;

  DeepSeekSearch p;  // 没有 search.deepseek 段，也没有自己写密钥
  p.set_section_present(false);
  p.set_api_key("sk-别家的密钥");
  p.set_base_url("https://gateway.example.com/anthropic");
  p.set_transport(&stub);

  REQUIRE_FALSE(p.is_configured());

  auto r = p.search("任意查询", "basic", 5);
  p.set_transport(nullptr);

  REQUIRE(r.results.empty());
  REQUIRE_FALSE(r.error.message.empty());
  // 关键断言：替身一次都没被调用 —— 不是"发出去了然后失败"
  REQUIRE(stub.calls == 0);
}

TEST_CASE("deepseek: 地址指向 DeepSeek 且密钥非空时可用", "[deepseek]") {
  auto p = make_provider();
  REQUIRE(p.is_configured());
  REQUIRE(p.name() == "deepseek");
  REQUIRE_FALSE(p.description().empty());

  p.set_api_key("");
  REQUIRE_FALSE(p.is_configured());  // 密钥空 → 不可用

  auto q = make_provider();
  q.set_base_url("https://api.deepseek.com");  // 不带 /anthropic 也能用
  REQUIRE(q.is_configured());
}

// ============================================================================
// 凭据闸门（tasks.md 3.2）—— 各种配置各来一次
// 参数顺序：段是否存在 / 会话凭据是否存在 / 自己的密钥 / 会话的密钥 /
//          自己写的地址 / 本次实际用的地址
// ============================================================================

TEST_CASE("deepseek: 自己写了密钥时用它（地址也指向 DeepSeek）", "[deepseek]") {
  REQUIRE(deepseek_provider_is_available(
    /*section_seen=*/true, /*session_model_present=*/false,
    /*own_api_key=*/"sk-own", /*session_api_key=*/"sk-别家的",
    /*own_base_url=*/"https://api.deepseek.com/anthropic",
    /*endpoint=*/"https://api.deepseek.com/anthropic"));
}

TEST_CASE("deepseek: 模型配的也是 DeepSeek 且写了 deepseek 段时回落", "[deepseek]") {
  REQUIRE(deepseek_provider_is_available(
    /*section_seen=*/true, /*session_model_present=*/true,
    /*own_api_key=*/"", /*session_api_key=*/"sk-会话模型的",
    /*own_base_url=*/"",
    /*endpoint=*/"https://api.deepseek.com/anthropic"));
}

TEST_CASE("deepseek: 什么都没写时不出现", "[deepseek]") {
  // 没有 search.deepseek 段、会话模型地址也不是 DeepSeek
  REQUIRE_FALSE(deepseek_provider_is_available(
    /*section_seen=*/false, /*session_model_present=*/true,
    /*own_api_key=*/"", /*session_api_key=*/"sk-会话模型的",
    /*own_base_url=*/"",
    /*endpoint=*/"https://gateway.example.com/anthropic"));
  // 有段但没有可回落的密钥
  REQUIRE_FALSE(deepseek_provider_is_available(
    /*section_seen=*/true, /*session_model_present=*/false,
    /*own_api_key=*/"", /*session_api_key=*/"",
    /*own_base_url=*/"",
    /*endpoint=*/"https://api.deepseek.com/anthropic"));
}

TEST_CASE("deepseek: 会话模型的地址不是 DeepSeek 时不可用（5.5 的落点之一）",
          "[deepseek]") {
  // 关键情形：自己没写密钥（要回落会话模型那把），会话模型地址又不是 DeepSeek
  REQUIRE_FALSE(deepseek_provider_is_available(
    /*section_seen=*/true, /*session_model_present=*/true,
    /*own_api_key=*/"", /*session_api_key=*/"sk-会话模型的",
    /*own_base_url=*/"",
    /*endpoint=*/"https://gateway.example.com/anthropic"));
  // 连 search.deepseek 段都没有
  REQUIRE_FALSE(deepseek_provider_is_available(
    /*section_seen=*/false, /*session_model_present=*/true,
    /*own_api_key=*/"", /*session_api_key=*/"sk-会话模型的",
    /*own_base_url=*/"",
    /*endpoint=*/"https://gateway.example.com/anthropic"));
}

TEST_CASE("deepseek: 只写了密钥、地址来自会话模型且不是 DeepSeek 时不可用", "[deepseek]") {
  // 自己只写了密钥（`own_base_url` 为空）→ 地址取自会话模型，而它不是 DeepSeek：
  // 这把密钥不能发到那个地址上，必须拒绝。
  REQUIRE_FALSE(deepseek_provider_is_available(
    /*section_seen=*/true, /*session_model_present=*/true,
    /*own_api_key=*/"sk-own", /*session_api_key=*/"sk-会话模型的",
    /*own_base_url=*/"",
    /*endpoint=*/"https://gateway.example.com/anthropic"));
}

TEST_CASE("deepseek: 自己同时写了密钥与地址时用它（地址可以不指向 DeepSeek）",
          "[deepseek]") {
  // 用户显式给了两份配置：没有动用会话模型的任何东西，地址写错要让错误说明报出来
  REQUIRE(deepseek_provider_is_available(
    /*section_seen=*/true, /*session_model_present=*/true,
    /*own_api_key=*/"sk-own", /*session_api_key=*/"sk-会话模型的",
    /*own_base_url=*/"https://my-gateway.example.com/v1",
    /*endpoint=*/"https://my-gateway.example.com/v1"));
  // 只写了地址、没写密钥（要回落会话模型那把密钥）时，地址仍受闸门管
  REQUIRE_FALSE(deepseek_provider_is_available(
    /*section_seen=*/true, /*session_model_present=*/true,
    /*own_api_key=*/"", /*session_api_key=*/"sk-会话模型的",
    /*own_base_url=*/"https://my-gateway.example.com/v1",
    /*endpoint=*/"https://my-gateway.example.com/v1"));
}

TEST_CASE("deepseek: 用量那一行从返回里读得出来（读不到就不编）", "[deepseek]") {
  // 一次搜索 = 一次完整模型调用，成本只能从 usage 看出来（tasks.md 7.2）。
  // 这里核对"读得出来"这条：正常返回 → 三项都读出来；没有 usage → 空串（日志里写
  // "读不到"，不许估）。
  const std::string withUsage = R"({
    "content": [{"type":"web_search_tool_result","content":[
      {"type":"web_search_result","url":"https://a.example/1","title":"第一条","page_age":""}]}],
    "usage": {"input_tokens": 7429, "output_tokens": 620,
              "server_tool_use": {"web_search_requests": 1}}
  })";
  const std::string usage = DeepSeekSearch::describe_usage(withUsage);
  INFO("用量说明 = " << usage);
  REQUIRE(usage.find("input_tokens=7429") != std::string::npos);
  REQUIRE(usage.find("output_tokens=620") != std::string::npos);
  REQUIRE(usage.find("web_search_requests=1") != std::string::npos);

  REQUIRE(DeepSeekSearch::describe_usage("{\"content\":[]}").empty());
  REQUIRE(DeepSeekSearch::describe_usage("不是 JSON").empty());
}

TEST_CASE("deepseek: is_configured 如实转述闸门结论（不自己按地址重算）", "[deepseek]") {
  // 这一条是 7.3 那次实测暴露出来的：闸门放行了"自己写全密钥与地址"的配置，但
  // `is_configured()` 若自己再按"地址含 api.deepseek.com"算一遍，就会把放行的配置
  // 又挡掉（表现是清单里没有 deepseek、错误只说"没有配置任何后端"）。
  DeepSeekSearch p;
  p.set_section_present(true);
  p.set_api_key("sk-own");
  p.set_base_url("https://my-gateway.example.com/v1");
  REQUIRE_FALSE(p.is_configured());  // 还没判过闸门 → 不可用
  p.set_gate_passed(true);
  REQUIRE(p.is_configured());        // 闸门放行后即使地址不是 DeepSeek 也可用
  REQUIRE(p.base_url() == "https://my-gateway.example.com/v1");
}
