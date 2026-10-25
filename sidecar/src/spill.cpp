#include "spill.h"

#include <algorithm>
#include <cctype>
#include <cerrno>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <string>

#include <nlohmann/json.hpp>

#include "subprocess.h"

#ifdef _WIN32
#include <windows.h>
#include <direct.h>
#else
#include <dirent.h>
#include <sys/stat.h>
#include <unistd.h>
#endif

using nlohmann::json;

namespace spill {

namespace {

/// 测试注入的"写到这么多字节后失败"；`kNoInjectedFailure` 表示不注入。
size_t g_fail_after = kNoInjectedFailure;

std::string g_root_override;
unsigned g_call_seq = 0;

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

/// 统一成原生分隔符：Windows 上后续所有文件操作都用 `\`。
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

std::string last_os_error() {
#ifdef _WIN32
    const DWORD code = GetLastError();
    if (code == 0) return "没有系统错误码";
    LPWSTR buf = nullptr;
    const DWORD n = FormatMessageW(
        FORMAT_MESSAGE_ALLOCATE_BUFFER | FORMAT_MESSAGE_FROM_SYSTEM | FORMAT_MESSAGE_IGNORE_INSERTS,
        nullptr, code, MAKELANGID(LANG_NEUTRAL, SUBLANG_DEFAULT), reinterpret_cast<LPWSTR>(&buf), 0,
        nullptr);
    std::string text;
    if (n > 0 && buf) {
        // 宽字符只取 ASCII 部分即可：这里只要一个能看懂的短原因
        for (DWORD i = 0; i < n; ++i) {
            const wchar_t w = buf[i];
            if (w == L'\r' || w == L'\n') break;
            text += (w < 128) ? static_cast<char>(w) : '?';
        }
        LocalFree(buf);
    }
    if (text.empty()) text = "系统错误 " + std::to_string(code);
    return text + "（错误码 " + std::to_string(code) + "）";
#else
    return std::string(std::strerror(errno));
#endif
}

bool make_dir(const std::string& path) {
#ifdef _WIN32
    return _mkdir(path.c_str()) == 0 || errno == EEXIST;
#else
    return mkdir(path.c_str(), 0755) == 0 || errno == EEXIST;
#endif
}

/// 逐级建目录（`<根>/<会话>`），已存在的层不算错。
bool make_dirs(const std::string& path) {
    std::string current;
    for (size_t i = 0; i < path.size(); ++i) {
        const char c = path[i];
        current += c;
#ifdef _WIN32
        const bool sep = (c == '\\' || c == '/');
#else
        const bool sep = (c == '/');
#endif
        if (!sep) continue;
#ifdef _WIN32
        if (current.size() == 3 && current[1] == ':' && (current[2] == '\\' || current[2] == '/'))
            continue;  // 盘符根
#endif
        if (current.size() <= 1) continue;
        std::string trimmed = current;
        while (!trimmed.empty() && (trimmed.back() == '\\' || trimmed.back() == '/')) trimmed.pop_back();
        if (trimmed.empty()) continue;
        if (!make_dir(trimmed)) return false;
    }
    if (!path.empty() && !make_dir(path)) return false;
    return true;
}

/// 目录能不能列（用来区分"根目录不可读"和别的错）。
bool dir_readable(const std::string& path) {
#ifdef _WIN32
    const std::string pattern = native(path + "/*");
    WIN32_FIND_DATAA fd;
    HANDLE h = FindFirstFileA(pattern.c_str(), &fd);
    if (h == INVALID_HANDLE_VALUE) return false;
    FindClose(h);
    return true;
#else
    DIR* d = opendir(path.c_str());
    if (!d) return false;
    closedir(d);
    return true;
#endif
}

/// 规范化为绝对路径（不要求文件存在）。失败返回空串。
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

/// `path` 是否落在 `dir` 之内（含 dir 自身）。两边都必须是已规范化的绝对路径。
bool is_inside(const std::string& path, const std::string& dir) {
    std::string prefix = dir;
    while (!prefix.empty() && (prefix.back() == '\\' || prefix.back() == '/')) prefix.pop_back();
    if (prefix.empty()) return false;
    if (!same_prefix_ci(path, prefix)) return false;
    if (path.size() == prefix.size()) return true;
    const char next = path[prefix.size()];
    return next == '\\' || next == '/';
}

std::string fail(const std::string& reason) {
    return json{{"ok", false}, {"error", reason}}.dump(-1, ' ', false, json::error_handler_t::replace);
}

long long int_field(const json& req, const char* key, long long fallback, long long minimum) {
    if (!req.contains(key)) return fallback;
    const json& v = req[key];
    if (!v.is_number_integer() && !v.is_number_float()) return fallback;
    const long long n = v.get<long long>();
    return n < minimum ? fallback : n;
}

/// 该位置是不是一个码点的起点（续字节 `10xxxxxx` 不是）。
bool is_char_start(const std::string& s, size_t i) {
    if (i >= s.size()) return false;
    return (static_cast<unsigned char>(s[i]) & 0xC0) != 0x80;
}

}  // namespace

std::string root() {
    if (!g_root_override.empty()) return native(g_root_override);
    return native(home_dir() + "/.aliasagent/spill");
}

void set_root_for_tests(const std::string& path) { g_root_override = path; }

void reset_call_seq_for_tests() { g_call_seq = 0; }

void set_fail_after_bytes_for_tests(size_t bytes) { g_fail_after = bytes; }

std::string session_dir_name(const std::string& session) {
    if (session.empty()) return "no-session";
    std::string out;
    out.reserve(session.size());
    for (const char ch : session) {
        const unsigned char b = static_cast<unsigned char>(ch);
        const bool keep = (b >= 'A' && b <= 'Z') || (b >= 'a' && b <= 'z') || (b >= '0' && b <= '9') ||
                          b == '.' || b == '_' || b == '-';
        out += keep ? ch : '_';
    }
    if (out.empty() || out == "." || out == "..") return "no-session";
    return out;
}

std::string path_for(const std::string& session, const std::string& tag, unsigned seq) {
    char name[128];
    std::snprintf(name, sizeof(name), "%06u-%s.txt", seq, tag.c_str());
    return join(join(root(), session_dir_name(session)), name);
}

/// 把 `tmp` 原子地换成 `dst`。**目标已存在时必须覆盖** —— 用 `std::rename` 会失败
/// （Windows 的 CRT `rename` 拒绝覆盖），症状是"应用重启后序号又从 1 开始，撞上上次
/// 留下的同名文件，于是大输出直接报写盘失败"。NTFS 上 `MoveFileExW` 带
/// `MOVEFILE_REPLACE_EXISTING` 是原子替换，正好是这个语义。
bool replace_file(const std::string& tmp, const std::string& dst) {
#ifdef _WIN32
    const std::wstring wtmp = subprocess::utf8_to_wide(tmp);
    const std::wstring wdst = subprocess::utf8_to_wide(dst);
    if (wtmp.empty() || wdst.empty()) return false;
    return MoveFileExW(wtmp.c_str(), wdst.c_str(),
                       MOVEFILE_REPLACE_EXISTING | MOVEFILE_WRITE_THROUGH) != 0;
#else
    return std::rename(tmp.c_str(), dst.c_str()) == 0;
#endif
}

Written write(const std::string& session, const std::string& tag, const std::string& content) {
    Written w;
    const std::string dir = join(root(), session_dir_name(session));
    if (!make_dirs(dir)) {
        w.error = "无法创建 spill 目录：" + dir + "（" + last_os_error() + "）";
        return w;
    }
    const unsigned seq = ++g_call_seq;
    const std::string final_path = path_for(session, tag, seq);
    const std::string tmp_path = final_path + ".tmp";

    FILE* f = std::fopen(tmp_path.c_str(), "wb");
    if (!f) {
        w.error = "无法打开 spill 临时文件：" + tmp_path + "（" + last_os_error() + "）";
        return w;
    }
    const size_t budget = (g_fail_after == kNoInjectedFailure)
                              ? content.size()
                              : std::min(content.size(), g_fail_after);
    const size_t written = std::fwrite(content.data(), 1, budget, f);
    bool ok = (std::fflush(f) == 0);
    if (std::fclose(f) != 0) ok = false;
    if (!ok || written != budget || budget != content.size()) {
        std::remove(tmp_path.c_str());
        if (budget != content.size() && ok) {
            w.error = "写入 spill 文件失败：" + tmp_path + "（模拟写盘中断：只写出 " +
                      std::to_string(written) + " / " + std::to_string(content.size()) + " 字节）";
        } else {
            w.error = "写入 spill 文件失败：" + tmp_path + "（" + last_os_error() + "）";
        }
        return w;
    }
    if (!replace_file(tmp_path, final_path)) {
        std::remove(tmp_path.c_str());
        w.error = "无法把 spill 临时文件改名到：" + final_path + "（" + last_os_error() + "）";
        return w;
    }
    w.ok = true;
    w.path = final_path;
    w.bytes = content.size();
    return w;
}

bool is_valid_utf8(const std::string& s) {
    size_t i = 0;
    while (i < s.size()) {
        const unsigned char b = static_cast<unsigned char>(s[i]);
        size_t len = 0;
        if (b < 0x80) {
            ++i;
            continue;
        } else if ((b & 0xE0) == 0xC0) {
            len = 2;
        } else if ((b & 0xF0) == 0xE0) {
            len = 3;
        } else if ((b & 0xF8) == 0xF0) {
            len = 4;
        } else {
            return false;  // 续字节出现在这里，或 0xF8 以上
        }
        if (i + len > s.size()) return false;
        for (size_t k = 1; k < len; ++k) {
            if ((static_cast<unsigned char>(s[i + k]) & 0xC0) != 0x80) return false;
        }
        // 过长编码 / 代理区 / 超出 U+10FFFF
        const unsigned char b1 = static_cast<unsigned char>(s[i + 1]);
        if (len == 2 && b < 0xC2) return false;
        if (len == 3) {
            if (b == 0xE0 && b1 < 0xA0) return false;
            if (b == 0xED && b1 > 0x9F) return false;
        }
        if (len == 4) {
            if (b == 0xF0 && b1 < 0x90) return false;
            if (b == 0xF4 && b1 > 0x8F) return false;
            if (b > 0xF4) return false;
        }
        i += len;
    }
    return true;
}

size_t char_count(const std::string& s) {
    size_t n = 0;
    for (size_t i = 0; i < s.size(); ++i)
        if (is_char_start(s, i)) ++n;
    return n;
}

std::string head_chars(const std::string& s, size_t n) {
    if (n == 0) return std::string();
    size_t seen = 0;
    for (size_t i = 0; i < s.size(); ++i) {
        if (!is_char_start(s, i)) continue;
        if (seen == n) return s.substr(0, i);
        ++seen;
    }
    return s;
}

std::string tail_chars(const std::string& s, size_t n) {
    if (n == 0) return std::string();
    size_t seen = 0;
    for (size_t i = s.size(); i > 0;) {
        --i;
        if (!is_char_start(s, i)) continue;
        ++seen;
        if (seen == n) return s.substr(i);
    }
    return s;
}

std::string read_request(const std::string& request_json) {
    json req;
    try {
        req = json::parse(request_json.empty() ? "{}" : request_json);
    } catch (const std::exception& e) {
        return fail(std::string("请求不是合法的 JSON：") + e.what());
    }
    if (!req.is_object()) return fail("请求必须是一个 JSON 对象");
    if (!req.contains("ref") || !req["ref"].is_string())
        return fail("缺少 ref（spill 引用）");

    const std::string ref = req["ref"].get<std::string>();
    const long long offset = int_field(req, "offset", 0, 0);
    const long long preview = int_field(req, "preview_chars", 1000, 1);
    const long long limit = int_field(req, "limit", preview * 2, 1);

    // ① 根目录得能读（不可读时给一条与其它情况都不同的说法）
    const std::string root_dir = root();
    if (!dir_readable(root_dir)) {
        return fail("spill 根目录不可读：" + root_dir + "（" + last_os_error() + "）");
    }

    // ② 引用必须落在 spill 根目录之内 —— 先规范化再比前缀，不许被 `..` 绕过
    const std::string want = canonical(ref);
    if (want.empty()) return fail("引用无法解析为绝对路径：" + ref);
    const std::string base = canonical(root_dir);
    if (base.empty()) return fail("spill 根目录无法解析为绝对路径：" + root_dir);
    if (!is_inside(want, base)) return fail("引用不在 spill 根目录内：" + ref);

    // ③ 引用存在
    FILE* f = std::fopen(want.c_str(), "rb");
    if (!f) return fail("引用不存在：" + want);
    std::string bytes;
    {
        char buf[65536];
        size_t got = 0;
        while ((got = std::fread(buf, 1, sizeof(buf), f)) > 0) bytes.append(buf, got);
    }
    std::fclose(f);
    const long long total = static_cast<long long>(bytes.size());

    // ④ 区间越界（严格：不许静默只返回能读到的部分）
    if (offset > total || offset + limit > total) {
        return fail("读取区间越界：offset=" + std::to_string(offset) + " limit=" +
                    std::to_string(limit) + " total_bytes=" + std::to_string(total));
    }

    // ⑤ 切点必须落在字符边界上（否则返回的会是半个字符）
    if (offset > 0 && !is_char_start(bytes, static_cast<size_t>(offset))) {
        return fail("切点落在多字节字符中间：offset=" + std::to_string(offset));
    }
    if (offset + limit < total && !is_char_start(bytes, static_cast<size_t>(offset + limit))) {
        return fail("区间末尾落在多字节字符中间：offset+limit=" +
                    std::to_string(offset + limit));
    }

    const std::string text = bytes.substr(static_cast<size_t>(offset), static_cast<size_t>(limit));
    return json{{"ok", true},
                {"text", text},
                {"bytes_read", static_cast<long long>(text.size())},
                {"total_bytes", total}}
        .dump(-1, ' ', false, json::error_handler_t::replace);
}

}  // namespace spill
