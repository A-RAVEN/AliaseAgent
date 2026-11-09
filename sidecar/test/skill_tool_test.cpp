// `load_skill` 的 C++ 单测（change `add-skill-mechanism` 任务 4.4）。
//
// 覆盖（每条对应 tasks 4.1 / 4.2 / 4.4 的一句）：
//   ① 短正文内联全文，且字节等于"切除 frontmatter 后的正文"；落盘文件形如
//      `<6 位序号>-skill.txt`，内容与正文逐字节相同；
//   ② 附属文件返回全文（**不**切除任何段落，即使它自己以 `---` 开头）；
//   ③ 跨侧互验：与 Dart 侧 `test/unit/skill_frontmatter_test.dart` 读**同一份夹具**
//      `test/fixtures/skills/edge-skill/SKILL.md`，两侧断言同一个正文串（design D2）；
//   ④ `../../` 穿越、绝对路径都被拒，原因里写明"超出技能目录"，且目标文件内容
//      没有出现在结果里；
//   ⑤ 大写 / 连字符非法技能名在字符集关卡即拒（不触文件系统 —— 用例把技能根指到
//      一个**文件**上，若碰了文件系统错误文本会变成"缺少 SKILL.md"）；
//   ⑥ 未知技能名 `ok:false` 且错误里含该名字与路径；
//   ⑦ 长正文：信封总字节 == spill 文件实际大小，`|head|+|tail|+omitted == total`；
//   ⑧ spill 目录不可写：长内容 ⇒ `ok:false` 且不许给内容片段；短内容 ⇒ 内联全文；
//   ⑨ 序号与同上下文的 `run_command` 共表自增（`000001-skill.txt` → `000002-stdout.txt`）。
//
// 用例里的数字都有出处：`preview_chars` 缺省 1000 = 用户 2026-10-25 的决定（见
// `spill.h` 的 `kDefaultPreviewChars`）；200000 字节沿用规范里"长正文"场景的样本规模。
#include <catch2/catch_all.hpp>

#include <cstdio>
#include <fstream>
#include <string>

#include <nlohmann/json.hpp>

#include "command_tool.h"
#include "context.h"
#include "skill_tool.h"
#include "spill.h"
#include "temp_dir.h"

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

bool ends_with(const std::string& value, const std::string& suffix) {
    return value.size() >= suffix.size() &&
           value.compare(value.size() - suffix.size(), suffix.size(), suffix) == 0;
}

/// 技能根 + spill 根的成对设置与恢复（照 `SpillRootGuard` 的写法）。
class RootsGuard {
public:
    RootsGuard(const std::string& skills_root, const std::string& spill_root) {
        skill_tool::set_root_for_tests(skills_root);
        spill::set_root_for_tests(spill_root);
        spill::reset_call_seq_for_tests();
        spill::set_fail_after_bytes_for_tests(spill::kNoInjectedFailure);
    }
    ~RootsGuard() {
        skill_tool::set_root_for_tests("");
        spill::set_root_for_tests("");
        spill::reset_call_seq_for_tests();
        spill::set_fail_after_bytes_for_tests(spill::kNoInjectedFailure);
    }
};

json call_load_skill(const json& request) {
    return json::parse(
        skill_tool::load_skill(context::Context::current(), request.dump()));
}

/// 与 Dart 侧 `test/unit/skill_frontmatter_test.dart` 的 `kEdgeSkillBodyLines` 逐行
/// 相同的正文（两侧断言同一个字面量 —— 任一侧改动切除规则，另一侧会红）。
const char* kEdgeSkillBody =
    "# 正文第一行\n"
    "\n"
    "这一段里有分隔线：\n"
    "\n"
    "---\n"
    "\n"
    "正文在第二个独立 `---` 之后必须继续（它属于正文，不能被当定界行）。\n";

std::string fixture_path(const std::string& relative) {
    return std::string(SKILL_FIXTURE_DIR) + "/" + relative;
}

}  // namespace

// ---------------------------------------------------------------------------
// 切除规则（design D2）
// ---------------------------------------------------------------------------

TEST_CASE("load_skill: 切除规则 —— 首行不是 --- 时整个文件是正文", "[skills]") {
    const std::string raw = "name: no-frontmatter\n# 正文\n";
    INFO("strip = " << skill_tool::strip_frontmatter(raw));
    REQUIRE(skill_tool::strip_frontmatter(raw) == raw);
}

TEST_CASE("load_skill: 切除规则 —— 正文里的 `---` 行不被再切", "[skills]") {
    const std::string raw =
        "---\nname: pdf-tools\ndescription: 处理 PDF\n---\n# 正文\n\n---\n分隔线之后仍然是正文\n";
    const std::string body = skill_tool::strip_frontmatter(raw);
    INFO("body = " << body);
    REQUIRE(body == "# 正文\n\n---\n分隔线之后仍然是正文\n");
}

TEST_CASE("load_skill: 切除规则 —— 只有开头 `---` 没有闭合行时整个文件是正文", "[skills]") {
    const std::string raw = "---\nname: dangling\ndescription: 缺闭合行\n";
    REQUIRE(skill_tool::strip_frontmatter(raw) == raw);
}

TEST_CASE("load_skill: 技能名字符集（规范 name 规则）", "[skills]") {
    // 合法：1–64、小写字母/数字/单个连字符
    REQUIRE(skill_tool::is_valid_skill_name("pdf-tools"));
    REQUIRE(skill_tool::is_valid_skill_name("a"));
    REQUIRE(skill_tool::is_valid_skill_name(std::string(64, 'a')));
    // 非法：超长、大写、前后连字符、连续连字符、空、带点/斜杠/空格
    REQUIRE_FALSE(skill_tool::is_valid_skill_name(std::string(65, 'a')));
    REQUIRE_FALSE(skill_tool::is_valid_skill_name("PDF-Tools"));
    REQUIRE_FALSE(skill_tool::is_valid_skill_name("-lead"));
    REQUIRE_FALSE(skill_tool::is_valid_skill_name("trail-"));
    REQUIRE_FALSE(skill_tool::is_valid_skill_name("a--b"));
    REQUIRE_FALSE(skill_tool::is_valid_skill_name(""));
    REQUIRE_FALSE(skill_tool::is_valid_skill_name("../evil"));
    REQUIRE_FALSE(skill_tool::is_valid_skill_name("a b"));
}

// ---------------------------------------------------------------------------
// 短正文：内联全文 + 落盘
// ---------------------------------------------------------------------------

TEST_CASE("load_skill: 短正文内联全文、字节等于切除后的正文、落盘名形如 <序号>-skill.txt",
          "[skills][spill]") {
    TempDir tmp;
    RootsGuard guard(tmp.path(), tmp.path() + "/spill");
    context::Context& ctx = context::Context::current();

    const std::string body = "# 说明\n\n先读这里。\n";
    tmp.write("short-skill/SKILL.md",
              std::string("---\nname: short-skill\ndescription: 短正文技能\n---\n") + body);

    json result = call_load_skill(json{{"skill", "short-skill"}});
    INFO("result = " << result.dump().substr(0, 400));
    REQUIRE(result["ok"] == true);
    REQUIRE(result["truncated"] == false);
    REQUIRE(result["content"].get<std::string>() == body);  // 全文，不是前 N 个
    // 短内容也要落盘（`tool-output-spill` 能力「小输出也先写盘」）
    REQUIRE(result.contains("spill"));
    const json& env = result["spill"]["skill"];
    const std::string ref = env["ref"].get<std::string>();
    INFO("ref = " << ref);
    REQUIRE(ref.find(spill::context_dir(ctx.name())) == 0);
    REQUIRE(ends_with(ref, "000001-skill.txt"));
    REQUIRE(read_all(ref) == body);  // 原始字节，逐字节相同
    REQUIRE(env["total_bytes"].get<size_t>() == body.size());
    REQUIRE(env["omitted_bytes"].get<size_t>() == 0);
}

TEST_CASE("load_skill: 附属文件返回全文，不被切除任何段落", "[skills][spill]") {
    TempDir tmp;
    RootsGuard guard(tmp.path(), tmp.path() + "/spill");

    // 附属文件自己也以 `---` 开头：它仍然要原样返回（只有 SKILL.md 才切 frontmatter）。
    const std::string reference =
        "---\n这是一份参考资料，不是 frontmatter\n---\n正文段一\n\n---\n正文段二\n";
    tmp.write("with-ref/SKILL.md",
              "---\nname: with-ref\ndescription: 带附属文件\n---\n# 主正文\n");
    tmp.write("with-ref/references/REFERENCE.md", reference);

    json result = call_load_skill(
        json{{"skill", "with-ref"}, {"file", "references/REFERENCE.md"}});
    INFO("result = " << result.dump().substr(0, 400));
    REQUIRE(result["ok"] == true);
    REQUIRE(result["content"].get<std::string>() == reference);
    const std::string ref = result["spill"]["skill"]["ref"].get<std::string>();
    REQUIRE(read_all(ref) == reference);
}

TEST_CASE("load_skill: 跨侧夹具 —— 与 Dart 侧读同一文件、断言同一正文（design D2）",
          "[skills][spill]") {
    const std::string raw = read_all(fixture_path("edge-skill/SKILL.md"));
    REQUIRE_FALSE(raw.empty());

    // ① 纯切除函数
    const std::string body = skill_tool::strip_frontmatter(raw);
    INFO("C++ body = " << body);
    REQUIRE(body == kEdgeSkillBody);

    // ② 真实调用路径（技能根指到夹具目录，技能名 = 夹具子目录名）
    TempDir tmp;
    RootsGuard guard(fixture_path("."), tmp.path() + "/spill");
    json result = call_load_skill(json{{"skill", "edge-skill"}});
    INFO("result = " << result.dump().substr(0, 400));
    REQUIRE(result["ok"] == true);
    REQUIRE(result["content"].get<std::string>() == kEdgeSkillBody);
    const std::string ref = result["spill"]["skill"]["ref"].get<std::string>();
    REQUIRE(read_all(ref) == kEdgeSkillBody);
}

// ---------------------------------------------------------------------------
// 路径与名字的两道闸
// ---------------------------------------------------------------------------

TEST_CASE("load_skill: ../../ 穿越被拒、原因在、目标内容不出现", "[skills]") {
    TempDir tmp;
    RootsGuard guard(tmp.path(), tmp.path() + "/spill");

    tmp.write("traversal-skill/SKILL.md",
              "---\nname: traversal-skill\ndescription: 穿越用例\n---\n# 正文\n");
    // 技能目录外的秘密文件：穿越成功的话它的内容会出现在结果里。
    tmp.write("secret.json", "TOP-SECRET-CONTENT");

    json result =
        call_load_skill(json{{"skill", "traversal-skill"}, {"file", "../../secret.json"}});
    INFO("result = " << result.dump());
    REQUIRE(result["ok"] == false);
    const std::string error = result["error"].get<std::string>();
    REQUIRE(error.find("超出技能目录") != std::string::npos);
    REQUIRE(error.find("secret.json") != std::string::npos);
    REQUIRE(result.contains("content") == false);
    REQUIRE(result.dump().find("TOP-SECRET-CONTENT") == std::string::npos);
}

TEST_CASE("load_skill: 绝对路径的 file 被拒", "[skills]") {
    TempDir tmp;
    RootsGuard guard(tmp.path(), tmp.path() + "/spill");
    tmp.write("abs-skill/SKILL.md",
              "---\nname: abs-skill\ndescription: 绝对路径用例\n---\n# 正文\n");

    json result =
        call_load_skill(json{{"skill", "abs-skill"}, {"file", "C:\\Windows\\win.ini"}});
    INFO("result = " << result.dump());
    REQUIRE(result["ok"] == false);
    const std::string error = result["error"].get<std::string>();
    REQUIRE(error.find("超出技能目录") != std::string::npos);
    REQUIRE(error.find("绝对路径") != std::string::npos);
    REQUIRE(result.contains("content") == false);
}

TEST_CASE("load_skill: 非法技能名在字符集关卡即拒（不触文件系统）", "[skills]") {
    TempDir tmp;
    // 技能根指向一个**文件**：如果代码碰了文件系统，错误文本会变成"缺少 SKILL.md"。
    const std::string root_file = tmp.path() + "/root-is-a-file";
    tmp.write("root-is-a-file", "not a directory");
    RootsGuard guard(root_file, tmp.path() + "/spill");

    for (const std::string bad : {std::string("../evil"), std::string("UPPER"),
                                  std::string("with space"), std::string("a--b"),
                                  std::string("-lead"), std::string(65, 'a')}) {
        json result = call_load_skill(json{{"skill", bad}});
        INFO("bad = " << bad << " result = " << result.dump());
        REQUIRE(result["ok"] == false);
        const std::string error = result["error"].get<std::string>();
        REQUIRE(error.find("技能名不合法") != std::string::npos);
        REQUIRE(error.find("SKILL.md") == std::string::npos);
    }
}

TEST_CASE("load_skill: 未知技能名 ok:false 且错误里含名字与路径", "[skills]") {
    TempDir tmp;
    RootsGuard guard(tmp.path(), tmp.path() + "/spill");
    tmp.write("known-skill/SKILL.md",
              "---\nname: known-skill\ndescription: 存在的技能\n---\n# 正文\n");

    json result = call_load_skill(json{{"skill", "missing-skill"}});
    INFO("result = " << result.dump());
    REQUIRE(result["ok"] == false);
    const std::string error = result["error"].get<std::string>();
    REQUIRE(error.find("missing-skill") != std::string::npos);
    REQUIRE(error.find("SKILL.md") != std::string::npos);
    REQUIRE(result.contains("content") == false);
}

TEST_CASE("load_skill: file 指向不存在的文件时 ok:false 且不返回空内容冒充成功", "[skills]") {
    TempDir tmp;
    RootsGuard guard(tmp.path(), tmp.path() + "/spill");
    tmp.write("no-file/SKILL.md",
              "---\nname: no-file\ndescription: 缺文件用例\n---\n# 正文\n");

    json result = call_load_skill(json{{"skill", "no-file"}, {"file", "references/none.md"}});
    INFO("result = " << result.dump());
    REQUIRE(result["ok"] == false);
    REQUIRE(result.contains("content") == false);
    const std::string error = result["error"].get<std::string>();
    REQUIRE(error.find("none.md") != std::string::npos);
    REQUIRE(error.find("no-file") != std::string::npos);
}

// ---------------------------------------------------------------------------
// 长正文、写盘失败与序号共表
// ---------------------------------------------------------------------------

TEST_CASE("load_skill: 长正文信封与落盘文件对得上", "[skills][spill]") {
    TempDir tmp;
    RootsGuard guard(tmp.path(), tmp.path() + "/spill");

    const std::string head_marker = "HEAD-MARKER-";
    const std::string middle_marker = "MIDDLE-MARKER";
    const std::string tail_marker = "-TAIL-MARKER";
    const size_t total = 200000;
    const size_t fill =
        total - head_marker.size() - middle_marker.size() - tail_marker.size();
    const std::string body = head_marker + std::string(fill / 2, 'a') + middle_marker +
                             std::string(fill - fill / 2, 'b') + tail_marker;
    REQUIRE(body.size() == total);
    tmp.write("big-skill/SKILL.md",
              "---\nname: big-skill\ndescription: 长正文技能\n---\n" + body);

    json result = call_load_skill(json{{"skill", "big-skill"}});
    REQUIRE(result["ok"] == true);
    REQUIRE(result["truncated"] == true);
    const std::string content = result["content"].get<std::string>();
    INFO("content 前 120 = " << content.substr(0, 120));
    REQUIRE(content.find(head_marker) != std::string::npos);
    REQUIRE(content.find(tail_marker) != std::string::npos);
    REQUIRE(content.find(middle_marker) == std::string::npos);

    const json& env = result["spill"]["skill"];
    const std::string ref = env["ref"].get<std::string>();
    const size_t omitted = env["omitted_bytes"].get<size_t>();
    INFO("ref = " << ref << " omitted = " << omitted);
    REQUIRE(ends_with(ref, "-skill.txt"));
    REQUIRE(omitted > 0);
    // 省略说明要写出与信封一致的省略量，并给出 read_spill 取回办法。
    REQUIRE(content.find(std::to_string(omitted) + " bytes omitted") != std::string::npos);
    REQUIRE(content.find("read_spill") != std::string::npos);

    // 外部真值：spill 文件的实际大小。
    REQUIRE(read_all(ref).size() == total);
    REQUIRE(env["total_bytes"].get<size_t>() == total);
    const std::string head = env["head"].get<std::string>();
    const std::string tail = env["tail"].get<std::string>();
    REQUIRE(head == body.substr(0, 1000));
    REQUIRE(tail == body.substr(body.size() - 1000));
    REQUIRE(head.size() + tail.size() + omitted == total);

    // 引用能按字节读回被省略的中段。
    const json read = json::parse(spill::read_request(
        context::Context::current(),
        json{{"ref", ref}, {"offset", 2000}, {"limit", 200}}.dump()));
    INFO("read = " << read.dump().substr(0, 200));
    REQUIRE(read["ok"] == true);
    REQUIRE(read["text"].get<std::string>() == body.substr(2000, 200));
}

TEST_CASE("load_skill: spill 目录不可写时长内容报错、短内容仍内联全文", "[skills][spill]") {
    TempDir tmp;
    tmp.write("afile.txt", "not a directory");
    // 技能根正常，spill 根落在"文件下面"，任何目录都建不出来。
    const std::string unwritable_spill = tmp.path() + "/afile.txt/spill";
    RootsGuard guard(tmp.path(), unwritable_spill);

    const std::string long_body(200000, 'z');
    tmp.write("long-skill/SKILL.md",
              "---\nname: long-skill\ndescription: 长内容\n---\n" + long_body);
    json long_result = call_load_skill(json{{"skill", "long-skill"}});
    INFO("long_result = " << long_result.dump().substr(0, 400));
    REQUIRE(long_result["ok"] == false);
    const std::string error = long_result["error"].get<std::string>();
    REQUIRE(error.find("spill") != std::string::npos);
    REQUIRE(error.find("afile.txt") != std::string::npos);  // 目录在错误里
    REQUIRE(long_result.contains("content") == false);      // 不许给内容片段
    REQUIRE(long_result.contains("spill") == false);        // 也不许编一个引用

    const std::string short_body(800, 's');
    tmp.write("short-skill/SKILL.md",
              "---\nname: short-skill\ndescription: 短内容\n---\n" + short_body);
    json short_result = call_load_skill(json{{"skill", "short-skill"}});
    INFO("short_result = " << short_result.dump().substr(0, 200));
    REQUIRE(short_result["ok"] == true);
    REQUIRE(short_result["content"].get<std::string>() == short_body);
    REQUIRE(short_result["truncated"] == false);
    REQUIRE(short_result.contains("spill") == false);
}

TEST_CASE("load_skill: 落盘序号与同上下文的 run_command 共表自增", "[skills][spill]") {
    TempDir tmp;
    RootsGuard guard(tmp.path(), tmp.path() + "/spill");
    tmp.write("seq-skill/SKILL.md",
              "---\nname: seq-skill\ndescription: 序号用例\n---\n# 正文\n");

    json skill_result = call_load_skill(json{{"skill", "seq-skill"}});
    REQUIRE(skill_result["ok"] == true);
    const std::string skill_ref =
        skill_result["spill"]["skill"]["ref"].get<std::string>();
    INFO("skill_ref = " << skill_ref);
    REQUIRE(ends_with(skill_ref, "000001-skill.txt"));

    // 同上下文再跑一条命令：它的 stdout 流必须接着拿 000002（同一张序号表）。
    const json command_result = json::parse(command_tool::run_command(
        json{{"command", "Write-Output 'seq-second'"}}.dump()));
    INFO("command_result = " << command_result.dump().substr(0, 300));
    REQUIRE(command_result["ok"] == true);
    const std::string stdout_ref =
        command_result["spill"]["stdout"]["ref"].get<std::string>();
    INFO("stdout_ref = " << stdout_ref);
    REQUIRE(ends_with(stdout_ref, "000002-stdout.txt"));
    REQUIRE(file_exists(skill_ref));
}
