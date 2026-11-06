// web_fetch 正文接入 spill 交付通道的 C++ 单测（change
// `migrate-web-fetch-to-spill` 任务 2.1）。
//
// 覆盖四件事：
//   ① 短正文：全文内联、无任何"省略"字样、spill 文件与输入逐字节相同；
//   ② 长正文：头尾各 preview_chars、中间不见、省略说明里的字节数 == 信封
//      omitted_bytes，且总字节数与 spill 文件实际大小一致（外部真值，不看信封自洽）；
//   ③ 写盘失败：超阈值 ⇒ ok:false 且带目录与系统原因；不超阈值 ⇒ 仍内联全文；
//   ④ 序号与 `run_command` 共用同一上下文计数器：`000001-content.txt`、
//      `000002-stdout.txt`。
//
// 判据里的数字都有出处：`preview_chars` 缺省 1000 是用户 2026-10-25 的决定（见
// `spill.h` 的 `kDefaultPreviewChars`）；200000 字节是规范「web_fetch 长正文头尾各留
// preview_chars 字符」场景里的样本规模。
#include <catch2/catch_all.hpp>

#include <cstdio>
#include <fstream>
#include <string>

#include <nlohmann/json.hpp>

#include "context.h"
#include "spill.h"
#include "temp_dir.h"
#include "web_fetch.h"

using nlohmann::json;

namespace {

std::string read_all(const std::string& path) {
    std::ifstream f(path, std::ios::binary);
    if (!f.good()) return std::string();
    return std::string((std::istreambuf_iterator<char>(f)), std::istreambuf_iterator<char>());
}

/// 把 spill 根指到某个临时目录，结束时**成对恢复**默认并清掉注入状态。
/// 写法照抄 `spill_write_test.cpp` 的 `SpillRootGuard`。
class SpillRootGuard {
public:
    explicit SpillRootGuard(const std::string& root) {
        spill::set_root_for_tests(root);
        spill::reset_call_seq_for_tests();
        spill::set_fail_after_bytes_for_tests(spill::kNoInjectedFailure);
    }
    ~SpillRootGuard() {
        spill::set_root_for_tests("");
        spill::reset_call_seq_for_tests();
        spill::set_fail_after_bytes_for_tests(spill::kNoInjectedFailure);
    }
};

/// 造一个"写不进去"的 spill 根：根落在一个普通文件下面，任何目录都建不出来。
std::string unwritable_root(TempDir& tmp) {
    tmp.write("afile.txt", "not a directory");
    return tmp.path() + "/afile.txt/spill";
}

/// 与 `web_fetch_impl` 两个成功出口构造出来的一致形态：ok / url / title / content。
json success_result(const std::string& body) {
    return json{{"ok", true},
                {"url", "https://example.com/article"},
                {"title", "示例页面"},
                {"content", body}};
}

}  // namespace

TEST_CASE("web_fetch: 短正文内联全文、无省略字样、spill 文件逐字节相同",
          "[web_fetch][spill]") {
    TempDir tmp;
    SpillRootGuard guard(tmp.path());
    context::Context& ctx = context::Context::current();

    // 800 字符 ≤ 1000 × 2（缺省 preview_chars），必须内联全文。
    const std::string body = "HEAD-" + std::string(790, 'a') + "-TAIL";
    REQUIRE(body.size() == 800);
    json result = success_result(body);

    const bool became_error =
        web_fetch_shape_success_result(ctx, result, spill::kDefaultPreviewChars);
    INFO("result = " << result.dump().substr(0, 200));
    REQUIRE(became_error == false);
    REQUIRE(result["ok"] == true);
    REQUIRE(result["truncated"] == false);
    REQUIRE(result["content"].get<std::string>() == body);  // 全文，不是前 N 个

    // 不出现任何"省略"提示（此时省略量会是 0 或负数，规范禁止）。
    REQUIRE(result["content"].get<std::string>().find("omitted") == std::string::npos);
    REQUIRE(result["content"].get<std::string>().find("省略") == std::string::npos);

    REQUIRE(result.contains("spill"));
    const json& env = result["spill"]["content"];
    const std::string ref = env["ref"].get<std::string>();
    INFO("ref = " << ref);
    // 文件必须落在本上下文自己的 spill 目录里（2.2 的清理闭环就靠这个目录）；
    // 目录名由 `context_dir(ctx.name())` 决定，同既有目录布局。
    REQUIRE(ref.find(spill::context_dir(ctx.name())) == 0);
    REQUIRE(ref.find("000001-content.txt") != std::string::npos);
    REQUIRE(read_all(ref) == body);  // 原始字节，逐字节相同
    REQUIRE(env["total_bytes"].get<size_t>() == body.size());
    REQUIRE(env["omitted_bytes"].get<size_t>() == 0);
}

TEST_CASE("web_fetch: 长正文头尾各 preview_chars、省略量与信封和文件大小闭合",
          "[web_fetch][spill]") {
    TempDir tmp;
    SpillRootGuard guard(tmp.path());
    context::Context& ctx = context::Context::current();

    const std::string head_marker = "HEAD-MARKER-";     // 12 字节
    const std::string middle_marker = "MIDDLE-MARKER";  // 13 字节
    const std::string tail_marker = "-TAIL-MARKER";     // 12 字节
    const size_t total = 200000;
    const size_t fill =
        total - head_marker.size() - middle_marker.size() - tail_marker.size();
    const std::string body = head_marker + std::string(fill / 2, 'a') + middle_marker +
                             std::string(fill - fill / 2, 'b') + tail_marker;
    REQUIRE(body.size() == total);

    json result = success_result(body);
    const bool became_error =
        web_fetch_shape_success_result(ctx, result, spill::kDefaultPreviewChars);
    REQUIRE(became_error == false);
    REQUIRE(result["ok"] == true);
    REQUIRE(result["truncated"] == true);

    const std::string content = result["content"].get<std::string>();
    INFO("content 前 120 = " << content.substr(0, 120));
    REQUIRE(content.find(head_marker) != std::string::npos);    // 头部留下
    REQUIRE(content.find(tail_marker) != std::string::npos);    // 尾部留下
    REQUIRE(content.find(middle_marker) == std::string::npos);  // 中段被省略

    const json& env = result["spill"]["content"];
    const std::string ref = env["ref"].get<std::string>();
    const size_t omitted = env["omitted_bytes"].get<size_t>();
    INFO("ref = " << ref << " omitted = " << omitted);
    REQUIRE(omitted > 0);
    // 省略说明里写的省略字节数必须**等于**信封的 omitted_bytes：少写 / 不写即红
    //（这条同时钉住"砍内容必须可见"）。
    const std::string omitted_text = std::to_string(omitted) + " bytes omitted";
    INFO("omitted_text = " << omitted_text);
    REQUIRE(content.find(omitted_text) != std::string::npos);
    REQUIRE(content.find("read_spill") != std::string::npos);

    // 信封与**外部真值**（spill 文件实际大小）对得上；头尾是原始字节切片，
    // |head| + |tail| + omitted_bytes == total_bytes 必须恒成立。
    REQUIRE(read_all(ref).size() == total);
    REQUIRE(env["total_bytes"].get<size_t>() == total);
    const std::string head = env["head"].get<std::string>();
    const std::string tail = env["tail"].get<std::string>();
    REQUIRE(head == body.substr(0, 1000));
    REQUIRE(tail == body.substr(body.size() - 1000));
    REQUIRE(head.size() + tail.size() + omitted == total);
    // 内联文本 = 消毒后的头 + 省略说明 + 消毒后的尾（纯 ASCII 下与原始切片相同）。
    REQUIRE(content.find(head) == 0);

    // 引用能按字节读回被省略的中段（2000..2199）。
    const json read = json::parse(spill::read_request(
        ctx, json{{"ref", ref}, {"offset", 2000}, {"limit", 200}}.dump()));
    INFO("read = " << read.dump().substr(0, 200));
    REQUIRE(read["ok"] == true);
    REQUIRE(read["text"].get<std::string>() == body.substr(2000, 200));
}

TEST_CASE("web_fetch: 写盘失败时超阈值报错、不超阈值仍内联全文", "[web_fetch][spill]") {
    TempDir tmp;
    const std::string root = unwritable_root(tmp);
    SpillRootGuard guard(root);
    context::Context& ctx = context::Context::current();

    // ① 长正文：不许只给头尾预览冒充完整正文 —— 整条改错误，说清目录与系统原因。
    const std::string long_body(200000, 'z');
    json long_result = success_result(long_body);
    const bool became_error =
        web_fetch_shape_success_result(ctx, long_result, spill::kDefaultPreviewChars);
    INFO("long_result = " << long_result.dump().substr(0, 400));
    REQUIRE(became_error == true);
    REQUIRE(long_result["ok"] == false);
    const std::string err = long_result["error"].get<std::string>();
    INFO("error = " << err);
    REQUIRE(err.find("spill") != std::string::npos);
    REQUIRE(err.find("afile.txt") != std::string::npos);  // 目录在错误里
    REQUIRE(long_result.contains("content") == false);     // 不许给内容片段
    REQUIRE(long_result.contains("spill") == false);       // 也不许编一个引用

    // ② 短正文：全文已经能内联，写盘失败不算工具失败（规范"写盘失败必须可见"）。
    const std::string short_body(800, 's');
    json short_result = success_result(short_body);
    const bool short_error =
        web_fetch_shape_success_result(ctx, short_result, spill::kDefaultPreviewChars);
    INFO("short_result = " << short_result.dump().substr(0, 200));
    REQUIRE(short_error == false);
    REQUIRE(short_result["ok"] == true);
    REQUIRE(short_result["content"].get<std::string>() == short_body);
    REQUIRE(short_result["truncated"] == false);
    REQUIRE(short_result.contains("spill") == false);  // 没有引用可给，就不要编一个
}

TEST_CASE("web_fetch: 序号与 run_command 共用同一上下文计数器", "[web_fetch][spill]") {
    TempDir tmp;
    SpillRootGuard guard(tmp.path());  // 清零当前上下文的序号，起点可预测
    context::Context& ctx = context::Context::current();

    // 第一次：web_fetch 的 content 流。
    json fetch_result = success_result("FIRST-VIA-CONTENT");
    REQUIRE(web_fetch_shape_success_result(ctx, fetch_result,
                                           spill::kDefaultPreviewChars) == false);
    const std::string content_ref =
        fetch_result["spill"]["content"]["ref"].get<std::string>();
    INFO("content_ref = " << content_ref);
    REQUIRE(content_ref.find("000001-content.txt") != std::string::npos);

    // 第二次：`run_command` 的 stdout 流（同一个共享形状函数的另一条流名）。
    spill::Written written;
    const spill::StreamShape shape = spill::shape_stream(
        ctx, "SECOND-VIA-STDOUT", 1000, ctx.name(), "stdout", &written);
    INFO("stdout ref = " << written.path);
    REQUIRE(written.ok);
    REQUIRE(written.path.find("000002-stdout.txt") != std::string::npos);

    // 两个文件落在同一个上下文目录，内容各自完整（序号没有被两套计数器各数一遍）。
    REQUIRE(written.path.find(spill::context_dir(ctx.name())) == 0);
    REQUIRE(read_all(content_ref) == "FIRST-VIA-CONTENT");
    REQUIRE(read_all(written.path) == "SECOND-VIA-STDOUT");
    REQUIRE(shape.truncated == false);
}
