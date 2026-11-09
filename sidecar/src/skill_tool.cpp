#include "skill_tool.h"

#include <algorithm>
#include <cctype>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <string>

#include <nlohmann/json.hpp>

#include "context.h"
#include "spill.h"

#ifdef _WIN32
#include <windows.h>
#include <direct.h>
#else
#include <sys/stat.h>
#include <unistd.h>
#endif

using nlohmann::json;

namespace skill_tool {

namespace {

/// 测试注入的技能根（空串 = 用缺省 `<主目录>/.aliasagent/skills`）。
std::string g_root_override;

/// 主目录解析：与 `spill.cpp` 的 `home_dir()` 逐字同源（Windows 取 `USERPROFILE`，
/// 回落到 `HOMEDRIVE`，再回落到 `.`）。两侧必须算出同一个家目录，否则 Dart 扫描到
/// 的目录与 C++ 读的目录会是两个地方。
std::string home_dir() {
#ifdef _WIN32
    const char* h = std::getenv("USERPROFILE");
    if (!h || !*h) h = std::getenv("HOMEDRIVE");
    return (h && *h) ? std::string(h) : std::string(".");
#else
    const char* h = std::getenv("HOME");
    return (h && *h) ? std::string(h) : std::string(".");
#endif
}

/// 统一成原生分隔符（与 `spill.cpp` 同法）。
std::string native(std::string p) {
#ifdef _WIN32
    for (auto& c : p)
        if (c == '/') c = '\\';
#endif
    return p;
}

std::string join(const std::string& dir, const std::string& name) {
    return native(dir + "/" + name);
}

bool path_is_file(const std::string& path) {
#ifdef _WIN32
    const DWORD attr = GetFileAttributesA(path.c_str());
    return attr != INVALID_FILE_ATTRIBUTES && !(attr & FILE_ATTRIBUTE_DIRECTORY);
#else
    struct stat st;
    return stat(path.c_str(), &st) == 0 && S_ISREG(st.st_mode);
#endif
}

/// 规范化为绝对路径（不要求文件存在）。失败返回空串。
/// 与 `spill.cpp` / `tools.cpp` 用的是同一个平台 API（`GetFullPathNameA`），
/// 因此 `..` 会被词汇化消解 —— 越界判定靠它，不靠字符串前缀猜。
std::string canonical(const std::string& path) {
#ifdef _WIN32
    const size_t need = GetFullPathNameA(path.c_str(), 0, nullptr, nullptr);
    if (need == 0) return std::string();
    std::string buf(need + 1, '\0');
    const DWORD n = GetFullPathNameA(path.c_str(), static_cast<DWORD>(buf.size()), &buf[0], nullptr);
    if (n == 0 || n >= buf.size()) return std::string();
    buf.resize(n);
    return buf;
#else
    if (!path.empty() && path[0] == '/') return path;
    char cwd[4096];
    if (!getcwd(cwd, sizeof(cwd))) return std::string();
    return std::string(cwd) + "/" + path;
#endif
}

bool same_prefix_ci(const std::string& path, const std::string& prefix) {
    if (path.size() < prefix.size()) return false;
    for (size_t i = 0; i < prefix.size(); ++i) {
#ifdef _WIN32
        const char a = static_cast<char>(::tolower(static_cast<unsigned char>(path[i])));
        const char b = static_cast<char>(::tolower(static_cast<unsigned char>(prefix[i])));
        if (a != b) return false;
#else
        if (path[i] != prefix[i]) return false;
#endif
    }
    return true;
}

/// `path` 是否落在 `dir` 之内（含 dir 自身）。两边必须先规范化成绝对路径。
/// 前缀判定与 `tools.cpp` 的 `is_within_workspace` 同款：还要求下一个字符是分隔符，
/// 否则 `/a/bc` 会被当成落在 `/a/b` 之内。
bool is_inside(const std::string& path, const std::string& dir) {
    std::string prefix = dir;
    while (!prefix.empty() && (prefix.back() == '\\' || prefix.back() == '/')) prefix.pop_back();
    if (prefix.empty()) return false;
    if (!same_prefix_ci(path, prefix)) return false;
    if (path.size() == prefix.size()) return true;
    const char next = path[prefix.size()];
    return next == '\\' || next == '/';
}

/// `file` 是不是绝对路径（盘符开头 / 以分隔符开头）。绝对路径一律拒，不做拼接尝试。
bool looks_absolute(const std::string& rel) {
    if (rel.empty()) return false;
    if (rel[0] == '/' || rel[0] == '\\') return true;
    return rel.size() >= 2 && rel[1] == ':';
}

bool read_whole_file(const std::string& path, std::string* out, std::string* error) {
    FILE* f = std::fopen(path.c_str(), "rb");
    if (!f) {
        *error = "打不开文件：" + path;
        return false;
    }
    std::string data;
    char buf[65536];
    size_t got = 0;
    while ((got = std::fread(buf, 1, sizeof(buf), f)) > 0) data.append(buf, got);
    std::fclose(f);
    *out = std::move(data);
    return true;
}

std::string fail(const std::string& reason) {
    return json{{"ok", false}, {"error", reason}}
        .dump(-1, ' ', false, json::error_handler_t::replace);
}

long long int_field(const json& req, const char* key, long long fallback, long long minimum) {
    if (!req.contains(key)) return fallback;
    const json& v = req[key];
    if (!v.is_number_integer() && !v.is_number_float()) return fallback;
    const long long n = v.get<long long>();
    return n < minimum ? fallback : n;
}

/// 该行（`[start, end)`）去掉行尾 `\r` 之后是不是恰好 `---`。
bool is_delimiter_line(const std::string& raw, size_t start, size_t end) {
    if (end > start && raw[end - 1] == '\r') --end;
    return (end - start) == 3 && raw.compare(start, 3, "---") == 0;
}

}  // namespace

std::string root() {
    if (!g_root_override.empty()) return native(g_root_override);
    return native(home_dir() + "/.aliasagent/skills");
}

void set_root_for_tests(const std::string& path) { g_root_override = path; }

std::string strip_frontmatter(const std::string& raw) {
    if (raw.empty()) return raw;
    // ① 首行必须**恰**为 `---`（允许行尾 `\r`，CRLF 文件同样识别）。
    size_t first_end = raw.find('\n');
    if (first_end == std::string::npos) first_end = raw.size();
    if (!is_delimiter_line(raw, 0, first_end)) return raw;
    if (first_end == raw.size()) return raw;  // 只有一行 `---`：没有闭合行

    // ② 从第二行起找下一个独立成行的 `---`；找到就把**它之后**的内容作为正文。
    //    正文里再出现独立 `---` 行也不会再切（只切一处）。
    size_t line_start = first_end + 1;
    while (line_start <= raw.size()) {
        size_t line_end = raw.find('\n', line_start);
        if (line_end == std::string::npos) line_end = raw.size();
        if (is_delimiter_line(raw, line_start, line_end)) {
            return line_end == raw.size() ? std::string() : raw.substr(line_end + 1);
        }
        if (line_end == raw.size()) break;
        line_start = line_end + 1;
    }
    // 有开头没闭合：按"无 frontmatter"处理，整个文件都是正文。
    return raw;
}

bool is_valid_skill_name(const std::string& name) {
    if (name.empty() || name.size() > 64) return false;
    if (name.front() == '-' || name.back() == '-') return false;
    bool previous_hyphen = false;
    for (const char ch : name) {
        const unsigned char b = static_cast<unsigned char>(ch);
        if (b == '-') {
            if (previous_hyphen) return false;  // 连续 `--`
            previous_hyphen = true;
            continue;
        }
        previous_hyphen = false;
        const bool ok = (b >= 'a' && b <= 'z') || (b >= '0' && b <= '9');
        if (!ok) return false;
    }
    return true;
}

std::string load_skill(context::Context& ctx, const std::string& request_json) {
    json req;
    try {
        req = json::parse(request_json.empty() ? "{}" : request_json);
    } catch (const std::exception& e) {
        return fail(std::string("请求不是合法的 JSON：") + e.what());
    }
    if (!req.is_object()) return fail("请求必须是一个 JSON 对象");

    if (!req.contains("skill") || !req["skill"].is_string()) {
        return fail("缺少 skill（技能名）");
    }
    const std::string skill = req["skill"].get<std::string>();

    // ---- 第二道闸：字符集。不合规的名字**不碰文件系统**。----
    if (!is_valid_skill_name(skill)) {
        return fail("技能名不合法（规范：1–64 字符，仅小写字母、数字与单个连字符，"
                    "不以 \"-\" 开头或结尾，不得含连续 \"--\"）：\"" +
                    skill + "\"");
    }

    bool has_file = false;
    std::string rel;
    if (req.contains("file")) {
        if (!req["file"].is_string()) return fail("file 必须是字符串（技能 " + skill + "）");
        rel = req["file"].get<std::string>();
        has_file = !rel.empty();
    }

    const std::string root_dir = root();
    const std::string skill_dir = join(root_dir, skill);

    std::string content;
    if (has_file) {
        // ---- 第三道闸：路径。先拒绝对路径，再规范化后比前缀。----
        if (looks_absolute(rel)) {
            return fail("路径超出技能目录：file=\"" + rel +
                        "\" 是绝对路径，只接受技能目录内的相对路径（技能 " + skill + "）");
        }
        const std::string target = join(skill_dir, rel);
        const std::string want = canonical(target);
        const std::string base = canonical(skill_dir);
        if (want.empty()) {
            return fail("文件路径无法解析为绝对路径：file=\"" + rel + "\"（技能 " + skill +
                        "，技能目录 " + skill_dir + "）");
        }
        if (base.empty()) {
            return fail("技能目录无法解析为绝对路径：" + skill_dir + "（技能 " + skill + "）");
        }
        if (!is_inside(want, base)) {
            return fail("路径超出技能目录：file=\"" + rel + "\" 解析到 " + want +
                        "，不在技能目录 " + base + " 之内（技能 " + skill + "）");
        }
        if (!path_is_file(want)) {
            return fail("技能文件不存在：技能 \"" + skill + "\" 的文件 \"" + rel + "\"（" +
                        want + "）");
        }
        std::string error;
        if (!read_whole_file(want, &content, &error)) {
            return fail("读取技能文件失败：技能 \"" + skill + "\" 的文件 \"" + rel + "\"（" +
                        error + "）");
        }
    } else {
        const std::string md = join(skill_dir, "SKILL.md");
        if (!path_is_file(md)) {
            return fail("技能不存在或缺少 SKILL.md：技能 \"" + skill + "\"（" + md + "）");
        }
        std::string raw;
        std::string error;
        if (!read_whole_file(md, &raw, &error)) {
            return fail("读取技能正文失败：技能 \"" + skill + "\"（" + error + "）");
        }
        // 正文 = 闭合 `---` 之后的内容（design D2；不解析 YAML 语义）。
        content = strip_frontmatter(raw);
    }

    // ---- 交付形状：与 run_command / web_fetch 共用同一份实现，流名固定 `skill`。----
    const long long preview_chars =
        int_field(req, "preview_chars", spill::kDefaultPreviewChars, 1);
    spill::Written written;
    const spill::StreamShape shape =
        spill::shape_stream(ctx, content, static_cast<size_t>(preview_chars), ctx.name(),
                            "skill", &written);

    if (!written.ok) {
        const size_t limit = static_cast<size_t>(preview_chars) * 2;
        if (spill::char_count(content) <= limit) {
            // 内容本身不超过预览阈值：全文已经能内联，写盘失败不丢内容（规范
            // 「写盘失败必须可见」的第一种处置）。没有引用可给，就不编一个。
            return json{{"ok", true}, {"content", shape.inline_text}, {"truncated", false}}
                .dump(-1, ' ', false, json::error_handler_t::replace);
        }
        // 超过阈值且没能落盘：不许只给头尾预览冒充完整内容。
        return fail("load_skill 的内容没能写进 spill 文件，且内容超过了预览阈值"
                    "（无法只给一部分冒充完整内容）：" +
                    written.error);
    }

    json result{{"ok", true},
                {"content", shape.inline_text},
                {"truncated", shape.truncated}};
    result["spill"] = json{{"skill", shape.envelope}};
    // `error_handler_t::replace`：内联文本里可能有非法 UTF-8 字节（sanitize 已替换，
    // 这里再兜一层），文件里仍是原始字节。
    return result.dump(-1, ' ', false, json::error_handler_t::replace);
}

}  // namespace skill_tool
