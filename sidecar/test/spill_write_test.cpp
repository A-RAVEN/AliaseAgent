// spill 落盘与读回的 C++ 单测（change `spill-large-tool-output`）。
//
// 这个文件覆盖：原子写（写完的内容逐字节相同、中途失败不破坏已有文件）、
// UTF-8 安全切分、`read_spill` 的五种失败与前缀限制、写盘失败的两种处置。
//
// 判据里出现的数字全部来自实测读数或规范条文（`preview_chars` 默认 1000 是用户
// 2026-10-25 的决定），不手算、不发明。
#include <catch2/catch_all.hpp>

#include <cstdio>
#include <cstdlib>
#include <fstream>
#include <set>
#include <string>
#include <vector>

#include <nlohmann/json.hpp>

#include "command_tool.h"
#include "context.h"
#include "context_api.h"
#include "spill.h"
#include "temp_dir.h"

#ifdef _WIN32
#include <windows.h>
#endif

using nlohmann::json;

namespace {

std::string read_all(const std::string& path) {
    std::ifstream f(path, std::ios::binary);
    if (!f.good()) return std::string();
    return std::string((std::istreambuf_iterator<char>(f)), std::istreambuf_iterator<char>());
}

bool file_exists(const std::string& path) {
    std::ifstream f(path, std::ios::binary);
    return f.good();
}

/// 当前上下文的名字在 spill 目录里的编码形式（`read_spill` 只接受这个目录内的引用）。
std::string ctx_dir() {
    return spill::session_dir_name(context::Context::current().name());
}

/// 把 spill 根指到某个临时目录，结束时恢复默认并清掉注入状态。
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

}  // namespace

// ---------------------------------------------------------------------------
// 2.3 UTF-8 安全切分
// ---------------------------------------------------------------------------

TEST_CASE("spill: 头尾按字符切，切出来仍是合法 UTF-8", "[spill][spill_write]") {
    // 一头一尾都是中文，中间塞够长 —— 只要按字节硬切，头或尾必有一个是半个字。
    const std::string text = "中文开头" + std::string(3000, 'a') + "中文结尾";
    const std::string head = spill::head_chars(text, 1000);
    const std::string tail = spill::tail_chars(text, 1000);
    INFO("head.size=" << head.size() << " tail.size=" << tail.size());
    INFO("head 末尾字节=" << static_cast<int>(static_cast<unsigned char>(head.back())));

    REQUIRE(spill::is_valid_utf8(head));  // 严格校验：非法就是红
    REQUIRE(spill::is_valid_utf8(tail));
    REQUIRE(spill::char_count(head) == 1000);
    REQUIRE(spill::char_count(tail) == 1000);
    // 头是原文的前缀、尾是原文的后缀（切点都在码点边界上）
    REQUIRE(text.compare(0, head.size(), head) == 0);
    REQUIRE(text.compare(text.size() - tail.size(), tail.size(), tail) == 0);
    // 尾部不许以续字节开头（那就是把一个中文字劈成两半）
    REQUIRE((static_cast<unsigned char>(tail.front()) & 0xC0) != 0x80);
    REQUIRE(head.find("中文开头") == 0);
    REQUIRE(tail.find("中文结尾") == tail.size() - std::string("中文结尾").size());
}

TEST_CASE("spill: 切点落在四字节字符上也不许切半个", "[spill][spill_write]") {
    const std::string text = "😀😀😀abc";  // 每个 emoji 4 字节
    const std::string head = spill::head_chars(text, 2);
    const std::string tail = spill::tail_chars(text, 1);
    INFO("head=" << head << " head.size=" << head.size());
    REQUIRE(spill::is_valid_utf8(head));
    REQUIRE(spill::is_valid_utf8(tail));
    REQUIRE(head.size() == 8);   // 两个 emoji，各 4 字节
    REQUIRE(tail == "c");
}

TEST_CASE("spill: 严格校验会拒绝过长编码、代理区与被截断的尾巴", "[spill][spill_write]") {
    REQUIRE(spill::is_valid_utf8("正常中文 abc"));
    REQUIRE(spill::is_valid_utf8("") == true);
    REQUIRE(spill::is_valid_utf8("\x80") == false);              // 孤立续字节
    REQUIRE(spill::is_valid_utf8("\xE4\xB8") == false);          // 被截断的三字节字符
    REQUIRE(spill::is_valid_utf8("\xC0\xAF") == false);          // 过长编码
    REQUIRE(spill::is_valid_utf8("\xED\xA0\x80") == false);      // 代理区
    REQUIRE(spill::is_valid_utf8("\xF5\x80\x80\x80") == false);  // 超出 U+10FFFF
}

// ---------------------------------------------------------------------------
// 2.5 read_spill 的两种形状与五种可区分的失败
// ---------------------------------------------------------------------------

TEST_CASE("spill: read_spill 读到的是文件对应区间的原文", "[spill][spill_write]") {
    TempDir tmp;
    SpillRootGuard guard(tmp.path());
    const std::string content = "0123456789ABCDEFGHIJ";
    tmp.write(ctx_dir() + "/probe.txt", content);
    const std::string ref = spill::root() + "\\" + ctx_dir() + "\\probe.txt";

    const json ok = json::parse(spill::read_request(
        context::Context::current(),
        json{{"ref", ref}, {"offset", 5}, {"limit", 4}}.dump()));
    INFO("ok = " << ok.dump());
    REQUIRE(ok["ok"] == true);
    REQUIRE(ok["text"] == "5678");
    REQUIRE(ok["bytes_read"] == 4);
    REQUIRE(ok["total_bytes"] == content.size());

    // limit 省略时按 preview_chars × 2 取：这里 preview_chars=5 ⇒ limit=10，
    // 文件 20 字节，所以正好取到前 10 个字节（不是越界）
    const json omitted_limit = json::parse(spill::read_request(
        context::Context::current(),
        json{{"ref", ref}, {"offset", 0}, {"preview_chars", 5}}.dump()));
    INFO("省略 limit: " << omitted_limit.dump());
    REQUIRE(omitted_limit["ok"] == true);
    REQUIRE(omitted_limit["text"] == "0123456789");
    REQUIRE(omitted_limit["bytes_read"] == 10);
}

TEST_CASE("spill: read_spill 的五种失败各有不同错误文本", "[spill][spill_write]") {
    TempDir tmp;
    SpillRootGuard guard(tmp.path());
    // 多字节内容：一个中文字 3 字节，用来验"切点落在字符中间"。
    // 文件名用 ASCII —— Windows 的 `std::ofstream` 认的是 ANSI 代码页，
    // 拿 UTF-8 的中文文件名建出来的会是另一个名字。
    tmp.write(ctx_dir() + "/mb.txt", "中文测试");

    const std::string inside = spill::root() + "\\" + ctx_dir() + "\\mb.txt";
    const std::string outside = tmp.path() + "/../outside.txt";

    std::vector<std::string> errors;
    auto error_of = [&](const std::string& ref, long long offset, long long limit) {
        const json r = json::parse(spill::read_request(
            context::Context::current(),
            json{{"ref", ref}, {"offset", offset}, {"limit", limit}}.dump()));
        INFO("请求 ref=" << ref << " offset=" << offset << " limit=" << limit
                         << " → " << r.dump());
        REQUIRE(r["ok"] == false);
        REQUIRE(r.contains("error"));
        errors.push_back(r["error"].get<std::string>());
        return r["error"].get<std::string>();
    };

    // ① 引用不在 spill 根目录内
    const std::string e1 = error_of(outside, 0, 1);
    // ② 引用不存在（在本上下文目录内，但文件没有）
    const std::string e2 = error_of(spill::root() + "\\" + ctx_dir() + "\\nope.txt", 0, 1);
    // ③ 越界
    const std::string e3 = error_of(inside, 0, 1000);
    // ④ 切点落在多字节字符中间（"中文测试" 的第二个字节）
    const std::string e4 = error_of(inside, 1, 3);

    INFO("① " << e1);
    INFO("② " << e2);
    INFO("③ " << e3);
    INFO("④ " << e4);
    REQUIRE(e1.find("不在 spill 根目录内") != std::string::npos);
    REQUIRE(e2.find("引用不存在") != std::string::npos);
    REQUIRE(e3.find("越界") != std::string::npos);
    REQUIRE(e4.find("多字节字符中间") != std::string::npos);

    // ⑤ 根目录不可读：把根指到一个不存在的位置
    spill::set_root_for_tests(tmp.path() + "/no-such-root/spill");
    const json r5 = json::parse(spill::read_request(
        context::Context::current(),
        json{{"ref", inside}, {"offset", 0}, {"limit", 1}}.dump()));
    INFO("⑤ " << r5.dump());
    REQUIRE(r5["ok"] == false);
    const std::string e5 = r5["error"].get<std::string>();
    errors.push_back(e5);
    REQUIRE(e5.find("根目录不可读") != std::string::npos);

    // 五种错误文本两两不同（否则调用方没法按原因处理）
    std::set<std::string> distinct(errors.begin(), errors.end());
    INFO("错误文本条数=" << errors.size() << " 去重后=" << distinct.size());
    REQUIRE(errors.size() == 5);
    REQUIRE(distinct.size() == 5);
}

// ---------------------------------------------------------------------------
// 4.1 / 4.2 写盘失败必须可见
// ---------------------------------------------------------------------------

namespace {

/// 造一个"写不进去"的 spill 根：把根指到一个**普通文件**下面，任何目录都建不出来。
std::string unwritable_root(TempDir& tmp) {
    tmp.write("afile.txt", "not a directory");
    return tmp.path() + "/afile.txt/spill";
}

}  // namespace

TEST_CASE("run_command: 输出不超过预览阈值时写盘失败 ⇒ 内联全文且不报错", "[spill][spill_write]") {
    TempDir tmp;
    SpillRootGuard guard(unwritable_root(tmp));

    const std::string cmd = "[Console]::Out.Write('SHORT-AND-SAFE')";
    const json r = json::parse(
        command_tool::run_command(json{{"command", cmd}}.dump()));
    INFO("r = " << r.dump());
    REQUIRE(r["ok"] == true);                       // 小输出：写盘失败不算工具失败
    REQUIRE(r["stdout"] == "SHORT-AND-SAFE");       // 全文都在
    REQUIRE(r["truncated"]["stdout"] == false);
    REQUIRE(r.contains("spill") == false);          // 没有引用可给，就不要编一个
}

TEST_CASE("run_command: 输出超过预览阈值时写盘失败 ⇒ 报错且不返回任何内容片段",
          "[spill][spill_write]") {
    TempDir tmp;
    const std::string root = unwritable_root(tmp);
    SpillRootGuard guard(root);

    // 200000 字节，明显超过 preview_chars × 2 = 2000
    const std::string cmd =
        "[Console]::Out.Write('HEAD-MARKER' + ('A' * 199978) + 'TAIL-MARKER')";
    const json r = json::parse(
        command_tool::run_command(json{{"command", cmd}}.dump()));
    INFO("r = " << r.dump().substr(0, 400));
    REQUIRE(r["ok"] == false);
    const std::string err = r["error"].get<std::string>();
    INFO("error = " << err);
    // 说清哪条流、写到了哪、为什么失败（目录与系统原因都要在）
    REQUIRE(err.find("标准输出") != std::string::npos);
    REQUIRE(err.find("afile.txt") != std::string::npos);
    REQUIRE(err.find("spill") != std::string::npos);
    // 不许只给一部分内容冒充完整结果
    REQUIRE(r.contains("stdout") == false);
    REQUIRE(r.contains("stderr") == false);
    REQUIRE(r.contains("HEAD-MARKER") == false);
}

// ---------------------------------------------------------------------------
// 2.6 引用必须解析到 spill 根目录之内
// ---------------------------------------------------------------------------

TEST_CASE("spill: spill 根目录之外的引用被拒（拿真实文件试）", "[spill][spill_write]") {
    // 这一条**不**改 spill 根：用真实的 `~/.aliasagent/spill` 与真实存在的目录外文件。
    // 拿两个 ref 各试一次：
    //   ① 任务点名的 `~/.aliasagent/config.json`（应用跑过就一定在）；
    //   ② 本测试可执行文件自己（一定存在，保证"存在但不该被读"这个条件成立）。
    const char* home = std::getenv("USERPROFILE");
    REQUIRE(home != nullptr);
    const std::string config_ref = std::string(home) + "\\.aliasagent\\config.json";

    char self[MAX_PATH];
    const DWORD n = GetModuleFileNameA(nullptr, self, MAX_PATH);
    REQUIRE(n > 0);
    const std::string self_ref(self, n);

    for (const std::string& ref : {config_ref, self_ref}) {
        const json r = json::parse(spill::read_request(
            context::Context::current(),
            json{{"ref", ref}, {"offset", 0}, {"limit", 10}}.dump()));
        INFO("ref = " << ref << " → " << r.dump());
        REQUIRE(r["ok"] == false);
        const std::string e = r["error"].get<std::string>();
        // 理由必须说"不在 spill 根目录内"，而不是含混地报"引用不存在"
        REQUIRE(e.find("不在 spill 根目录内") != std::string::npos);
        REQUIRE(e.find("引用不存在") == std::string::npos);
    }
}

TEST_CASE("spill: 目录名映射与 Dart 侧一致", "[spill][spill_write]") {
    // 与 `test/unit/spill_config_test.dart` 的同一组样例逐字对应（两侧共读
    // `sidecar/test/spill_session_names.tsv`）：只留 `[a-z0-9_-]`，其余字节写成
    // `%XX`（大写十六进制）。
    REQUIRE(spill::session_dir_name("abc-123_def-4") == "abc-123_def-4");
    REQUIRE(spill::session_dir_name("abc-123_DEF.4") == "abc-123_%44%45%46%2E4");
    REQUIRE(spill::session_dir_name("a/b\\c:d*e") == "a%2Fb%5Cc%3Ad%2Ae");
    REQUIRE(spill::session_dir_name("") == "no-session");
    // `..` 必须编码掉，否则目录会跑到 spill 根目录之外。
    REQUIRE(spill::session_dir_name("..") == "%2E%2E");
    REQUIRE(spill::session_dir_name("会话甲") == "%E4%BC%9A%E8%AF%9D%E7%94%B2");
    // 只差大小写的两个名字必须落到不同目录（Windows 不区分大小写）。
    REQUIRE(spill::session_dir_name("Agent-7") != spill::session_dir_name("agent-7"));
    INFO("a/b:c ⇒ " << spill::session_dir_name("a/b:c"));
}

// ---------------------------------------------------------------------------
// 2.1 原子写
// ---------------------------------------------------------------------------

TEST_CASE("spill: 写完的文件与输入逐字节相同", "[spill][spill_write]") {
    TempDir tmp;
    SpillRootGuard guard(tmp.path());

    // 内容里同时有中文、CRLF、以及"结尾没有换行"。任何"顺手规范化"都会让它不同，
    // 所以这一条同时钉住"写入不改变字节"。
    const std::string content = "第一行\r\n第二行\n尾巴没有换行";
    const spill::Written w = spill::write("s1", "stdout", content);
    INFO("error = " << w.error);
    INFO("path = " << w.path);
    REQUIRE(w.ok);
    REQUIRE(w.bytes == content.size());
    REQUIRE(read_all(w.path) == content);
    // 引用落在 spill 根目录下，且文件名里带调用序号
    REQUIRE(w.path.find("\\s1\\") != std::string::npos);
    REQUIRE(w.path.find("000001-stdout.txt") != std::string::npos);
}

TEST_CASE("spill: 同一序号重复写会覆盖而不是失败", "[spill][spill_write]") {
    TempDir tmp;
    SpillRootGuard guard(tmp.path());

    const spill::Written first = spill::write("s1", "stdout", "FIRST");
    REQUIRE(first.ok);

    // 模拟"应用重启后调用序号又从 1 开始"：此时目标文件已经存在。
    // 用 `std::rename` 的实现在这里会失败（Windows 的 CRT `rename` 不覆盖），
    // 症状是大输出在第二次启动后直接报写盘失败 —— 这条就是那个守卫。
    spill::reset_call_seq_for_tests();
    const spill::Written second = spill::write("s1", "stdout", "SECOND");
    INFO("error = " << second.error);
    REQUIRE(second.ok);
    REQUIRE(second.path == first.path);
    REQUIRE(read_all(second.path) == "SECOND");
}

TEST_CASE("spill: 中途写失败时目标文件保持原状（原子写）", "[spill][spill_write]") {
    TempDir tmp;
    SpillRootGuard guard(tmp.path());

    // 预置：目标文件（本次调用的最终名）已经存在，内容是上一次写好的。
    const std::string session_dir = spill::root() + "\\s1";
    REQUIRE(mkdir_impl(session_dir.c_str()) == 0);
    const std::string target = spill::path_for("s1", "stdout", 1);
    {
        std::ofstream f(target, std::ios::binary);
        f << "OLD-CONTENT";
    }
    REQUIRE(read_all(target) == "OLD-CONTENT");

    // 注入：只写出 5 个字节就失败（模拟磁盘满 / 中途出错）
    spill::set_fail_after_bytes_for_tests(5);
    const spill::Written w = spill::write("s1", "stdout", std::string(100, 'A'));
    INFO("error = " << w.error);
    REQUIRE(w.ok == false);
    REQUIRE(w.error.find("模拟写盘中断") != std::string::npos);

    // 判据：目标文件仍是上一次的完整内容，临时文件没有残留。
    // 把 rename 换成"直接写目标文件"之后，这里会读到 5 个 A —— 这条就是那个守卫。
    REQUIRE(read_all(target) == "OLD-CONTENT");
    REQUIRE(file_exists(target + ".tmp") == false);
}

// ---------------------------------------------------------------------------
// 2.4（change add-context-handles）共享样例表、跨上下文拒绝、重启续号
// ---------------------------------------------------------------------------

TEST_CASE("spill: 编码样例表（C++ 与 Dart 共读同一份）逐行一致", "[spill][spill_write]") {
    std::ifstream f(SPILL_NAMES_TSV);
    REQUIRE(f.good());
    std::string line;
    std::set<std::string> dirs;
    int rows = 0;
    while (std::getline(f, line)) {
        if (line.empty() || line[0] == '#') continue;
        const size_t tab1 = line.find('\t');
        REQUIRE(tab1 != std::string::npos);
        const size_t tab2 = line.find('\t', tab1 + 1);
        REQUIRE(tab2 != std::string::npos);
        const std::string name = line.substr(0, tab1);
        const std::string expected = line.substr(tab1 + 1, tab2 - tab1 - 1);
        INFO("name=[" << name << "] expected=[" << expected << "]");
        REQUIRE(spill::session_dir_name(name) == expected);
        ++rows;
        dirs.insert(expected);
    }
    // 含中文、`.`、`..`、空串、大小写、UUID：样例表至少 9 行。
    REQUIRE(rows >= 9);
    // 不同的非空名字不得落到同一个目录（空名字那一行单独算 no-session）。
    REQUIRE(dirs.size() == static_cast<size_t>(rows));
}

TEST_CASE("spill: 用另一个上下文的句柄读引用被拒（含 .. 绕行）", "[spill][spill_write]") {
    TempDir root;
    SpillRootGuard guard(root.path());
    context::reset_registry_for_tests();
    auto a = context_api::ensure_context("owner-a", nullptr);
    auto b = context_api::ensure_context("owner-b", nullptr);
    a->reset_spill_seq_for_tests();
    b->reset_spill_seq_for_tests();

    const spill::Written wa = spill::write_for_context(*a, a->name(), "stdout", "SECRET-A");
    REQUIRE(wa.ok);

    // ① 直接引用甲的绝对路径：乙的句柄必须拒绝，且不返回内容。
    const json direct = json::parse(spill::read_request(
        *b, json{{"ref", wa.path}, {"offset", 0}, {"limit", 100}}.dump()));
    INFO("direct -> " << direct.dump());
    REQUIRE(direct["ok"] == false);
    REQUIRE(direct["error"].get<std::string>().find("不属于该上下文的目录") != std::string::npos);
    REQUIRE(direct.dump().find("SECRET-A") == std::string::npos);

    // ② 乙目录/../甲目录/文件名：规范化之后落在甲目录，同样被拒。
    const std::string file_name = wa.path.substr(wa.path.find_last_of("\\") + 1);
    const std::string crossed = spill::root() + "\\" +
                                spill::session_dir_name(b->name()) + "\\..\\" +
                                spill::session_dir_name(a->name()) + "\\" + file_name;
    const json cross = json::parse(spill::read_request(
        *b, json{{"ref", crossed}, {"offset", 0}, {"limit", 100}}.dump()));
    INFO("crossed -> " << cross.dump());
    REQUIRE(cross["ok"] == false);
    REQUIRE(cross.dump().find("SECRET-A") == std::string::npos);

    // ③ 自己的句柄能读到全文（区间必须落在文件内：这里内容是 8 字节）。
    const json own = json::parse(spill::read_request(
        *a, json{{"ref", wa.path}, {"offset", 0}, {"limit", 8}}.dump()));
    INFO("own -> " << own.dump());
    REQUIRE(own["ok"] == true);
    REQUIRE(own["text"] == "SECRET-A");

    // ④ 不存在的引用仍报"引用不存在"，不能被规范化失败误报成越界。
    const std::string missing = spill::context_dir(a->name()) + "\\nope.txt";
    const json miss = json::parse(spill::read_request(
        *a, json{{"ref", missing}, {"offset", 0}, {"limit", 10}}.dump()));
    INFO("missing -> " << miss.dump());
    REQUIRE(miss["ok"] == false);
    REQUIRE(miss["error"].get<std::string>().find("引用不存在") != std::string::npos);

    context::reset_registry_for_tests();
}

TEST_CASE("spill: 重建同名上下文后序号继续，旧引用不被覆盖", "[spill][spill_write]") {
    TempDir root;
    SpillRootGuard guard(root.path());
    context::reset_registry_for_tests();

    std::string old_ref;
    {
        auto ctx = context_api::ensure_context("restart-ctx", nullptr);
        spill::initialize_sequence_for_context(*ctx);
        ctx->reset_spill_seq_for_tests();
        // 模拟"进程里第一次写 1 号"：先清号再重建目录里的已有文件。
        const spill::Written first =
            spill::write_for_context(*ctx, ctx->name(), "stdout", "FIRST");
        REQUIRE(first.ok);
        REQUIRE(first.path.find("000001-stdout.txt") != std::string::npos);
        old_ref = first.path;
    }

    // 模拟进程重启：只清注册表（spill 目录保留），再用同名上下文重建。
    context::reset_registry_for_tests();
    {
        auto ctx = context_api::ensure_context("restart-ctx", nullptr);
        spill::initialize_sequence_for_context(*ctx);
        const spill::Written second =
            spill::write_for_context(*ctx, ctx->name(), "stdout", "SECOND");
        INFO("second path = " << second.path);
        REQUIRE(second.ok);
        REQUIRE(second.path != old_ref);
        REQUIRE(second.path.find("000002-stdout.txt") != std::string::npos);
        // 旧引用内容不变。
        REQUIRE(read_all(old_ref) == "FIRST");
        // 旧引用仍读得回来（"FIRST" 是 5 字节，区间必须落在文件内）。
        const json old_read = json::parse(spill::read_request(
            *ctx, json{{"ref", old_ref}, {"offset", 0}, {"limit", 5}}.dump()));
        INFO("old read -> " << old_read.dump());
        REQUIRE(old_read["ok"] == true);
        REQUIRE(old_read["text"] == "FIRST");
    }

    context::reset_registry_for_tests();
}
