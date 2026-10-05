#ifndef DEEPSEEK_SEARCH_H
#define DEEPSEEK_SEARCH_H

#include "search_provider.h"
#include <string>
#include <vector>

// ============================================================================
// DeepSeekSearch —— 用 DeepSeek 自己的服务端搜索当 `web_search` 的一个后端
//
// 一次搜索 = 一次完整的模型调用：POST <搜索地址>/messages，请求体里带一个
// 服务端工具 `{"type":"web_search_20250305","name":"web_search","max_uses":1}`，
// 返回里结构化结果在 `web_search_tool_result` 块里。不流式（要的是结构化结果
// 块，不是逐字文本）。
//
// 凭据只认两处（安全边界，改动前先读
// `openspec/changes/add-deepseek-web-search/design.md` 的决策 D2）：
//   ① `search.deepseek.api_key` / `.base_url`：写了就用写的；
//   ② **仅当**会话模型当前 provider 的地址确实指向 DeepSeek（含
//      `api.deepseek.com`）**且** `search.deepseek` 段存在时，才允许回落复用它
//      那把密钥与地址。
// 地址不是 DeepSeek 时报告不可用，**不回落、不发任何请求** —— 不是"发出去再
// 失败"，是根本不发。
//
// 未做的（见设计里的非目标）：不把模型写的那段回答当结果；不做一次请求连搜多轮
// （`max_uses` 固定 1）；不把搜索结果塞进会话的流式装配链。
// ============================================================================

/// 判定一个地址是否指向 DeepSeek —— 凭据闸门的唯一依据（地址字符串里含
/// `api.deepseek.com`）。单独抽成函数是为了能被单测直接调用。
bool deepseek_address_is_deepseek(const std::string& base_url);

/// 把地址补成"以 `/messages` 结尾"的调用地址；`.../anthropic` 与
/// `.../anthropic/v1` 两种写法都能用。
std::string deepseek_build_request_url(const std::string& base_url);

class DeepSeekSearch : public ISearchProvider {
public:
  DeepSeekSearch() = default;

  std::string name() const override { return "deepseek"; }

  std::string description() const override {
    return "DeepSeek Web Search — 用 DeepSeek 的服务端搜索，密钥可与会话模型复用"
           "（只在地址确实指向 DeepSeek 时）。搜索结果按次计费，每次都是一次完整"
           "模型调用。";
  }

  bool is_configured() const override;

  ProviderResult search(
    const std::string& query,
    const std::string& depth,
    int max_results
  ) override;

  // ---- 配置项（由 ensure_search_infra 按 D2 的闸门解析后设置）----

  /// 标记配置里出现了 `search.deepseek` 这一段。回落第 ② 条要求它存在。
  void set_section_present(bool present) { section_present_ = present; }
  void set_api_key(const std::string& key) { api_key_ = key; }
  void set_base_url(const std::string& url) { base_url_ = url; }
  void set_model(const std::string& model) { model_ = model; }

  /// 标记"凭据已经过闸门判定，可以用"（由 `search_provider.cpp` 的注册段设置）。
  /// 判定规则见 `deepseek_provider_is_available()`：自己把密钥与地址都写全时地址
  /// 可以不指向 DeepSeek，而那种情况在"密钥 / 地址"两个字段里看不出来 —— 所以结论
  /// 由闸门函数给出并记在这里，`is_configured()` 只如实转述它。
  void set_gate_passed(bool passed) { gate_passed_ = passed; }

  // ---- 供测试与排错读取 ----

  bool section_present() const { return section_present_; }
  bool gate_passed() const { return gate_passed_; }
  const std::string& api_key() const { return api_key_; }
  const std::string& base_url() const { return base_url_; }
  const std::string& model() const { return model_; }

  // ---- 请求构造与返回映射（拆出来是为了能在不联网的层上单测）----

  /// 构造那次 POST 的请求体。`max_uses` 固定 1。
  std::string build_request_body(const std::string& query) const;

  /// 把返回的那一整包 JSON 映射成搜索结果。纯函数：不联网、不读配置。
  ///
  /// - 只从 `type == "web_search_tool_result"` 的块取结果，块里每一条
  ///   `type == "web_search_result"` 取 `url` / `title` / `page_age`；
  /// - 同一网址只留一次（按出现顺序去重）；
  /// - 正文：优先取 `text` 块里按网址匹配上的 `citations[].cited_text`，
  ///   没有引用时**用标题兜底**（这是"没有摘要"，不是真摘要）；
  /// - 标题里的非法 UTF-8 字节替换成替换字符，不让解析失败；
  /// - `page_age` 为空是常态，不让它把结果丢掉；
  /// - 返回里**一个结果块都没有**时：`result.error.message` 非空，说明"这次
  ///   调用没有触发服务端搜索"（不许回退成把模型写的文字当结果，也不许当成
  ///   "搜到 0 条"）；
  /// - 有结果块但块里零条结果：正常返回空结果（成功，即"搜到 0 条"）。
  ///
  /// @param response_body 返回的整包 JSON 文本
  /// @param max_results   条数上限（按顺序截断，服务端没有这个旋钮）
  /// @param[out] fatal    解析失败或"没有结果块"时为 true（错误已写进结果里）
  static ProviderResult map_response(
    const std::string& response_body,
    int max_results,
    bool& fatal
  );

  /// 从返回里读一段"这次调用花了多少"的说明（`input_tokens` / `output_tokens` /
  /// `web_search_requests`），给日志用。一次搜索 = 一次完整模型调用，成本只能从
  /// 这里看出来；**读不到就返回空串**（不估、不编）。纯函数。
  static std::string describe_usage(const std::string& response_body);

  // ---- 响应体积越界（抽出来是为了能在单测里直接跑）----

  /// 一次体积判定的结果。
  struct SizeCheck {
    bool overflow = false;      // 越界（调用方应当中止传输）
    size_t received_bytes = 0;  // 已收到 + 本次要收下的总字节数
  };

  /// 判定"再收下 `incoming` 字节会不会超过 `limit`"。纯函数：不联网、不看全局。
  /// 真实传输层的写回调与单测走的是**同一个**判定，所以单测能覆盖到这条分支
  /// （替身传输层不走写回调，原来的写法覆盖不到 —— 这是把判定抽出来的原因）。
  static SizeCheck check_response_size(size_t limit, size_t already, size_t incoming);

  /// 越界时给用户/模型看的那句说明：写明上限与已收到（含本次）的字节数。
  /// 约定：这个上限是**内存保护**，不是内容预算。
  static std::string describe_size_overflow(size_t limit, size_t received);

  // ---- 可注入的传输层（单测与安全边界用例用）----

  /// 发一次 POST 并把响应体写进 `response_body`。
  /// 返回空串表示成功；非空表示失败说明（超时算失败）。
  struct Transport {
    virtual ~Transport() = default;
    virtual std::string post(
      const std::string& url,
      const std::string& api_key,
      const std::string& body,
      long& http_code,
      std::string& response_body
    ) = 0;
  };

  /// 换掉传输层。**安全边界用例靠它断言"没有发出任何请求"**：替身一旦被调用
  /// 就失败，而不是"发出去然后看它失败"。传 nullptr 恢复真实实现。
  void set_transport(Transport* transport) { transport_override_ = transport; }

private:
  bool section_present_ = false;  // 配置里是否出现过 search.deepseek 这一段
  bool gate_passed_ = false;      // 闸门判定结论（见 set_gate_passed）
  std::string api_key_;
  std::string base_url_;          // 自己写了就用写的，否则是会话模型的地址
  std::string model_ = "deepseek-v4-flash";
  Transport* transport_override_ = nullptr;  // 非空则用它，不联网
};

// ============================================================================
// 工厂 / 注册
// ============================================================================

/// 取全局 DeepSeekSearch 实例（首次调用时创建）。
std::shared_ptr<DeepSeekSearch> get_deepseek_provider();

#endif // DEEPSEEK_SEARCH_H
