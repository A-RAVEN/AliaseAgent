#include <catch2/catch_all.hpp>
#include "subprocess.h"
#include "temp_dir.h"
#include <chrono>
#include <iostream>

#ifdef _WIN32
#include <direct.h>  // _mkdir（TempDir 已带，但用例里直接用到了它）
#endif

// ============================================================================
// 2.3 — subprocess command-line escaping (CommandLineToArgvW quoting rules)
// ============================================================================

TEST_CASE("subprocess: simple args need no quoting", "[subprocess]") {
    REQUIRE(subprocess::build_command_line({"rg", "--json"}) == "rg --json");
    REQUIRE(subprocess::build_command_line({"rg"}) == "rg");
}

TEST_CASE("subprocess: arg with space is quoted", "[subprocess]") {
    REQUIRE(subprocess::build_command_line({"rg", "hello world"}) == "rg \"hello world\"");
    // pattern with space (rg scenario) must survive round-trip quoting
    REQUIRE(subprocess::build_command_line({"rg", "foo bar"}) == "rg \"foo bar\"");
}

TEST_CASE("subprocess: empty arg is quoted as empty pair", "[subprocess]") {
    REQUIRE(subprocess::build_command_line({"rg", ""}) == "rg \"\"");
}

TEST_CASE("subprocess: embedded quote is escaped", "[subprocess]") {
    // rg scenario: pattern containing a double quote
    std::string line = subprocess::build_command_line({"rg", "say \"hi\""});
    REQUIRE(line.find("\\\"") != std::string::npos);
    // The quoted form must contain the escaped quote and be wrapped
    REQUIRE(line.find("say \\\"hi\\\"") != std::string::npos);
}

TEST_CASE("subprocess: trailing backslash inside a quoted arg is doubled", "[subprocess]") {
    // An arg with a space is quoted; a trailing backslash inside the quotes
    // must be doubled so CommandLineToArgvW does not treat it as escaping the
    // closing quote.
    std::string line = subprocess::build_command_line({"rg", "path dir\\"});
    REQUIRE(line == "rg \"path dir\\\\\"");
}

TEST_CASE("subprocess: argv with dash-leading pattern unaffected", "[subprocess]") {
    // No spaces/quotes → unquoted even if it starts with '-'
    REQUIRE(subprocess::build_command_line({"rg", "-foo"}) == "rg -foo");
}

// ============================================================================
// 宽字符启动（tasks.md 1.5）：真实启动走 CreateProcessW，命令行与工作目录都不再
// 按 ANSI 码页解释。本机 ANSI 码页实测 1252，所以含中文的参数与工作目录在改之前
// 会被弄坏（探针实测：`中文参数` 传到子进程里变成 c3a4c2b8…）。
// ============================================================================

#ifdef _WIN32

namespace {

/// 十六进制，用来核对"子进程收到的字节"而不是"子进程的打印编码"。
std::string probe_hex(const std::string& s) {
    static const char* kDigits = "0123456789abcdef";
    std::string out;
    for (unsigned char c : s) {
        out.push_back(kDigits[c >> 4]);
        out.push_back(kDigits[c & 0x0F]);
    }
    return out;
}

/// 让子进程把 argv 的每一项（以及可选的当前目录）按十六进制打出来。
/// PYTHONIOENCODING=utf-8 钉住子进程自己的输出编码，免得测到的是它的打印编码。
subprocess::Result run_python_hex_probe(const std::vector<std::string>& extra_args,
                                        const std::string& cwd) {
    const std::string script =
        "import os, sys\n"
        "for i, a in enumerate(sys.argv[1:]):\n"
        "    print('arg' + str(i) + '=' + a.encode('utf-8', 'surrogateescape').hex())\n"
        "print('cwd=' + os.getcwd().encode('utf-8', 'surrogateescape').hex())\n";
    std::vector<std::string> argv = {"python", "-c", script};
    for (const auto& a : extra_args) argv.push_back(a);
    subprocess::Options opts;
    opts.timeout_seconds = 30;
    opts.cwd = cwd;
    return subprocess::run(argv, opts);
}

}  // namespace

TEST_CASE("subprocess: 宽字符命令行与字节命令行对同一组 argv 分段一致", "[subprocess]") {
    const std::vector<std::vector<std::string>> cases = {
        {"rg", "--json"},
        {"rg", "hello world"},
        {"rg", "say \"hi\""},
        {"rg", "path dir\\"},
        {"rg", ""},
        {"rg", "-foo"},
    };
    for (const auto& argv : cases) {
        const std::wstring wide = subprocess::build_command_line_wide(argv);
        std::string narrow = subprocess::build_command_line(argv);
        // 宽字符结果按 ASCII 收窄后必须与字节结果逐字节相同（这些用例只含 ASCII）
        std::string wide_as_narrow(wide.begin(), wide.end());
        INFO("argv[1] = " << (argv.size() > 1 ? argv[1] : std::string()));
        REQUIRE(wide_as_narrow == narrow);
    }
}

TEST_CASE("subprocess: 非 ASCII 的工作目录被采用", "[subprocess]") {
    // 目录本身用 ASCII 名（这样 TempDir 的清理能正常走），只有**工作目录**里
    // 的那一段是中文 —— 要验的就是这一段经过 CreateProcess 之后还在不在。
    TempDir tmp;
    std::string base = tmp.path();
    for (auto& c : base)
        if (c == '/') c = '\\';
    const std::string dir = base + "\\中文目录";

    // 必须用宽字符的建目录接口：`_mkdir` 是 ANSI 版，遇到非 ASCII 名会失败或建出
    // 乱码目录（这正是同一类缺陷的另一个面）。这里同时输出实测字节，便于归因。
    // 建目录必须先把 UTF-8 转成 UTF-16（用系统的转换函数，别自己手写解码器：
    // 手写那版实测就是错的）。建完立刻核对"它真的在那个位置"。
    const std::wstring wide_dir = [&] {
        int n = MultiByteToWideChar(CP_UTF8, 0, dir.data(),
                                    static_cast<int>(dir.size()), nullptr, 0);
        std::wstring w(static_cast<size_t>(n), L'\0');
        MultiByteToWideChar(CP_UTF8, 0, dir.data(), static_cast<int>(dir.size()),
                            w.data(), n);
        return w;
    }();
    const int mk = _wmkdir(wide_dir.c_str());
    REQUIRE(mk == 0);
    REQUIRE(GetFileAttributesW(wide_dir.c_str()) != INVALID_FILE_ATTRIBUTES);

    subprocess::Result res = run_python_hex_probe({}, dir);
    INFO("目录（UTF-8） = " << dir);
    INFO("期望 cwd 十六进制 = " << probe_hex(dir));
    INFO("started=" << res.started << " exit=" << res.exit_code);
    INFO("stdout:\n" << res.stdout_data);
    INFO("stderr:\n" << res.stderr_data);
    REQUIRE(res.started);
    REQUIRE(res.exit_code == 0);
    REQUIRE(res.stdout_data.find("cwd=" + probe_hex(dir)) != std::string::npos);
}

TEST_CASE("subprocess: 非 ASCII 参数逐字节到达（1.2 探针结论固化）", "[subprocess]") {
    const std::string chinese = "中文参数";
    subprocess::Result res = run_python_hex_probe({chinese}, "");
    INFO("期望 arg0 十六进制 = " << probe_hex(chinese));
    INFO("started=" << res.started << " exit=" << res.exit_code);
    INFO("stdout:\n" << res.stdout_data);
    INFO("stderr:\n" << res.stderr_data);
    REQUIRE(res.started);
    REQUIRE(res.exit_code == 0);
    REQUIRE(res.stdout_data.find("arg0=" + probe_hex(chinese)) != std::string::npos);
}

TEST_CASE("subprocess: 尾反斜杠与连续反斜杠参数逐字节到达（1.2 探针结论固化）", "[subprocess]") {
    const std::string trailing = "C:\\dir\\";
    const std::string doubled = "a\\\\b";
    subprocess::Result res = run_python_hex_probe({trailing, doubled}, "");
    INFO("期望 arg0 = " << probe_hex(trailing) << "  arg1 = " << probe_hex(doubled));
    INFO("started=" << res.started << " exit=" << res.exit_code);
    INFO("stdout:\n" << res.stdout_data);
    REQUIRE(res.started);
    REQUIRE(res.exit_code == 0);
    REQUIRE(res.stdout_data.find("arg0=" + probe_hex(trailing)) != std::string::npos);
    REQUIRE(res.stdout_data.find("arg1=" + probe_hex(doubled)) != std::string::npos);
}

#endif  // _WIN32

TEST_CASE("subprocess: 注入环境变量是并入而不是替换", "[subprocess]") {
    // 三项都要满足：①注入的项看得见；②父进程本来就有的变量还在；
    // ③PATH 仍然能按名字解析到真命令（这条最要紧 —— 把环境整个替换掉时，
    // PATH 会一起没掉，flutter/git/python 全部找不到）。
    _putenv_s("PROBE_PARENT_ONLY", "parent-value-123");
    subprocess::Options opts;
    opts.timeout_seconds = 30;
    opts.extra_env = {{"NO_COLOR", "1"}, {"PAGER", "cat"}, {"GIT_PAGER", "cat"}};
    const std::string script =
        "import os, shutil\n"
        "print('injected=' + (os.environ.get('NO_COLOR') or '<missing>'))\n"
        "print('pager=' + (os.environ.get('PAGER') or '<missing>'))\n"
        "print('gitpager=' + (os.environ.get('GIT_PAGER') or '<missing>'))\n"
        "print('parent=' + (os.environ.get('PROBE_PARENT_ONLY') or '<missing>'))\n"
        "print('path_len=' + str(len(os.environ.get('PATH') or '')))\n"
        "print('found_python=' + str(shutil.which('python') is not None))\n";
    subprocess::Result res = subprocess::run({"python", "-c", script}, opts);

    INFO("started=" << res.started << " exit=" << res.exit_code);
    INFO("stdout:\n" << res.stdout_data);
    INFO("stderr:\n" << res.stderr_data);
    REQUIRE(res.started);
    REQUIRE(res.exit_code == 0);
    REQUIRE(res.stdout_data.find("injected=1") != std::string::npos);
    REQUIRE(res.stdout_data.find("pager=cat") != std::string::npos);
    REQUIRE(res.stdout_data.find("gitpager=cat") != std::string::npos);
    REQUIRE(res.stdout_data.find("parent=parent-value-123") != std::string::npos);
    REQUIRE(res.stdout_data.find("path_len=0") == std::string::npos);
    REQUIRE(res.stdout_data.find("found_python=True") != std::string::npos);
}

TEST_CASE("subprocess: 毫秒超时按毫秒判定（不被截成整秒）", "[subprocess]") {
    // 一个必然跑得比 500 毫秒久的命令。若毫秒被截断成整秒（500 → 0 立即触发、
    // 或 500 → 1 秒才触发），下面关于耗时的断言就会失败。
    subprocess::Options opts;
    opts.timeout_ms = 500;
    opts.timeout_seconds = 30;  // 故意留一个更大的整秒值，证明毫秒字段优先
    const std::string script = "import time; time.sleep(5); print('should-not-print')";
    const auto t0 = std::chrono::steady_clock::now();
    subprocess::Result res = subprocess::run({"python", "-c", script}, opts);
    const long long ms = std::chrono::duration_cast<std::chrono::milliseconds>(
                             std::chrono::steady_clock::now() - t0)
                             .count();

    INFO("耗时毫秒 = " << ms);
    INFO("stdout:\n" << res.stdout_data);
    REQUIRE(res.started);
    REQUIRE(res.timed_out);
    REQUIRE(res.stdout_data.find("should-not-print") == std::string::npos);
    REQUIRE(ms >= 400);    // 没有被截成 0（立即触发会远小于这个数）
    REQUIRE(ms <= 3000);   // 也没有被抬成整秒（5 秒睡眠会跑满）
}

TEST_CASE("subprocess: 不填两个新字段时行为不变", "[subprocess]") {
    // 既有调用方（web_fetch / glob_file / grep_file / 浏览器探针）走的就是这条路：
    // 只设 timeout_seconds、不设 extra_env。
    subprocess::Options opts;
    opts.timeout_seconds = 30;
    const std::string script =
        "import os\n"
        "print('no_color=' + (os.environ.get('NO_COLOR') or '<none>'))\n"
        "print('ok')\n";
    subprocess::Result res = subprocess::run({"python", "-c", script}, opts);
    INFO("stdout:\n" << res.stdout_data);
    REQUIRE(res.started);
    REQUIRE_FALSE(res.timed_out);
    REQUIRE(res.exit_code == 0);
    REQUIRE(res.stdout_data.find("ok") != std::string::npos);
    // 没有注入就没理由多出 NO_COLOR（父进程本来就有的话不算，故只要求命令能跑通）
    REQUIRE(res.stdout_data.find("no_color=") != std::string::npos);
}

// ============================================================================
// run() smoke test — spawn a real subprocess and capture stdout + exit code
// ============================================================================

TEST_CASE("subprocess: run captures stdout and exit code", "[subprocess]") {
#ifdef _WIN32
    std::vector<std::string> argv = {"cmd.exe", "/C", "echo", "subprocess-ok"};
#else
    std::vector<std::string> argv = {"echo", "subprocess-ok"};
#endif
    subprocess::Result res = subprocess::run(argv, {});
    REQUIRE(res.started);
    REQUIRE_FALSE(res.timed_out);
    REQUIRE(res.exit_code == 0);
    REQUIRE(res.stdout_data.find("subprocess-ok") != std::string::npos);
}

TEST_CASE("subprocess: run reports non-zero exit code", "[subprocess]") {
#ifdef _WIN32
    std::vector<std::string> argv = {"cmd.exe", "/C", "exit", "3"};
#else
    std::vector<std::string> argv = {"sh", "-c", "exit 3"};
#endif
    subprocess::Result res = subprocess::run(argv, {});
    REQUIRE(res.started);
    REQUIRE_FALSE(res.timed_out);
    REQUIRE(res.exit_code == 3);
}

TEST_CASE("subprocess: empty argv fails without crash", "[subprocess]") {
    subprocess::Result res = subprocess::run({}, {});
    REQUIRE_FALSE(res.started);
    REQUIRE(res.exit_code == -1);
}

TEST_CASE("subprocess: timeout kills a sleeping process", "[subprocess]") {
    // Validates the timeout-and-kill mechanism end-to-end (the search tools use
    // the same machinery with a 30s constant).
#ifdef _WIN32
    std::vector<std::string> argv = {"cmd.exe", "/C", "ping", "127.0.0.1", "-n", "8"};
#else
    std::vector<std::string> argv = {"sleep", "8"};
#endif
    subprocess::Options opts;
    opts.timeout_seconds = 1;
    auto start = std::chrono::steady_clock::now();
    subprocess::Result res = subprocess::run(argv, opts);
    auto elapsed = std::chrono::duration_cast<std::chrono::seconds>(
        std::chrono::steady_clock::now() - start).count();
    REQUIRE(res.started);
    REQUIRE(res.timed_out);
    REQUIRE(elapsed <= 5);  // must NOT wait the full 8s
}
