// `run_command` 工具的 C++ 单测（tasks.md 6.1）。
//
// 覆盖：起进程 argv 的形状；编码前缀的位置与完整内容（含"前缀不改变报错行号"）；
// 可执行文件的解析顺序；输出上限的取舍（保留尾部 / 未超限不留文件 / 超写文件上限
// 不落文件）；生效超时的算法；工作目录真的被采用；输出含非法 UTF-8 时不崩。
//
// 用例里的数字全部来自实测读数（先跑出读数再写期望值），不是手算的。
#include <catch2/catch_all.hpp>

#include <chrono>
#include <cstdio>
#include <filesystem>
#include <fstream>
#include <iostream>
#include <string>
#include <vector>

#include <nlohmann/json.hpp>

#include "command_tool.h"
#include "spill.h"
#include "subprocess.h"
#include "temp_dir.h"
#include "tools.h"

#ifdef _WIN32
#include <windows.h>
#endif

using nlohmann::json;

namespace {

/// 递归删掉一个目录，用例结束把 `cpp-test` 这个会话目录清掉（不往用户主目录留垃圾）。
void remove_dir_recursive(const std::string& dir) {
    std::error_code ec;
    std::filesystem::remove_all(dir, ec);
}

json run_req(const std::string& request) {
    return json::parse(command_tool::run_command(request));
}

bool file_exists(const std::string& path) {
    std::ifstream f(path, std::ios::binary);
    return f.good();
}

/// 临时目录里现有多少个 run_command 留下的完整输出文件（用来断言"不该落文件"）。
int full_output_files() {
    char buf[MAX_PATH];
    const DWORD n = GetTempPathA(MAX_PATH, buf);
    if (n == 0 || n >= MAX_PATH) return -1;
    std::string pattern = std::string(buf) + "aliasagent_run_command_*.log";
    WIN32_FIND_DATAA fd;
    HANDLE h = FindFirstFileA(pattern.c_str(), &fd);
    if (h == INVALID_HANDLE_VALUE) return 0;
    int count = 0;
    do {
        ++count;
    } while (FindNextFileA(h, &fd));
    FindClose(h);
    return count;
}

}  // namespace

// ---------------------------------------------------------------------------
// argv 形状与编码前缀
// ---------------------------------------------------------------------------

TEST_CASE("run_command: argv 形状与编码前缀", "[command_tool]") {
    const std::string shell = "C:\\fake\\powershell.exe";
    const std::string command = "Write-Output 'hello world'";
    const std::vector<std::string> argv = command_tool::build_invocation(shell, command);

    // 工具层是 6 项（可执行文件 + 4 个开关 + `-Command` 的载荷）；到 subprocess 层
    // 才拼成命令行，那边的形状由 subprocess_test 守。
    INFO("argv 长度 = " << argv.size());
    REQUIRE(argv.size() == 6);
    REQUIRE(argv[0] == shell);
    REQUIRE(argv[1] == "-NoLogo");
    REQUIRE(argv[2] == "-NoProfile");
    REQUIRE(argv[3] == "-NonInteractive");
    REQUIRE(argv[4] == "-Command");
    REQUIRE(argv[5].substr(0, command.size()) != command);  // 前缀确实在前面

    // 前缀内容：两段编码赋值都要在，且命令接在同一行（前缀里有换行就是错的）
    REQUIRE(argv[5].find("[Console]::OutputEncoding = [System.Text.UTF8Encoding]::new($false); ") == 0);
    REQUIRE(argv[5].find("$OutputEncoding = [System.Text.UTF8Encoding]::new($false); ") !=
            std::string::npos);
    REQUIRE(argv[5].find('\n') == std::string::npos);
    REQUIRE(argv[5].size() > command.size());
    REQUIRE(argv[5].substr(argv[5].size() - command.size()) == command);  // 命令原文在尾部

    // 命令里的引号/空格/竖线一个都没被动过
    const std::string tricky = "Write-Output 'a b | c > d' \"q\" C:\\dir\\";
    const std::vector<std::string> argv2 = command_tool::build_invocation(shell, tricky);
    REQUIRE(argv2[5].substr(argv2[5].size() - tricky.size()) == tricky);
}

TEST_CASE("run_command: 前缀不改变 PowerShell 的报错行号", "[command_tool]") {
    // 三行命令、第二行故意写错。**注意 PowerShell 的"命令找不到"是非终止错误**，
    // 它不会把退出码变成非零，所以末尾显式给一个退出码，让这条判据确定性。
    // 前缀接在第一行之后，报错行号必须仍是第 2 行。
    const std::string cmd =
        "$x = 1\n"
        "ThisCmdletDefinitelyDoesNotExist12345 | Out-Null\n"
        "exit 7\n";
    const json r = run_req(json{{"command", cmd}, {"timeout_ms", 60000}}.dump());
    INFO("r = " << r.dump());
    REQUIRE(r["ok"] == true);
    REQUIRE(r["exit_code"] == 7);
    REQUIRE(r["stderr"].get<std::string>().find("At line:2") != std::string::npos);
}

// ---------------------------------------------------------------------------
// 可执行文件解析
// ---------------------------------------------------------------------------

TEST_CASE("run_command: 解释器落在本机真实存在的 PowerShell 上", "[command_tool]") {
    // 本机没有 PowerShell 7（三处候选都不存在），所以必须落到 Windows PowerShell 5.1。
    // 断言方式是"命令真的跑起来了"，而不是去读内部变量。
    const json r = run_req(json{{"command", "Write-Output 'alive'"}}.dump());
    INFO("r = " << r.dump());
    REQUIRE(r["ok"] == true);
    REQUIRE(r["exit_code"] == 0);
    REQUIRE(r["stdout"].get<std::string>().find("alive") != std::string::npos);

    const std::string root = [] {
        char buf[MAX_PATH];
        const DWORD n = GetEnvironmentVariableA("SystemRoot", buf, MAX_PATH);
        return n > 0 ? std::string(buf, n) : std::string("C:\\Windows");
    }();
    REQUIRE(file_exists(root + "\\System32\\WindowsPowerShell\\v1.0\\powershell.exe"));
}

// ---------------------------------------------------------------------------
// 输出的取舍
// ---------------------------------------------------------------------------

TEST_CASE("run_command: 超长输出头尾都保留、并给出 spill 引用", "[command_tool]") {
    const int before = full_output_files();
    // 先写一个可识别的头、再写大量内容、最后写一个可识别的尾
    const std::string cmd =
        "Write-Output 'HEAD-MARKER'\n"
        "1..400 | ForEach-Object { Write-Output ('x' * 40) }\n"
        "Write-Output 'TAIL-MARKER'\n";
    const json r = run_req(json{{"command", cmd}}.dump());
    INFO("r 摘要: ok=" << r["ok"] << " exit=" << r["exit_code"]
                       << " stdout_chars=" << r["stdout"].get<std::string>().size()
                       << " truncated=" << r["truncated"]["stdout"]);
    REQUIRE(r["ok"] == true);
    const std::string out = r["stdout"].get<std::string>();
    REQUIRE(r["truncated"]["stdout"] == true);
    REQUIRE(out.find("TAIL-MARKER") != std::string::npos);      // 尾部留下
    REQUIRE(out.find("HEAD-MARKER") != std::string::npos);      // 头部也留下（旧行为在这里丢过）

    // 完整输出改落 spill 文件并给出引用，不再写系统临时目录
    REQUIRE(r.contains("full_output_paths") == false);
    REQUIRE(r.contains("spill"));
    const std::string ref = r["spill"]["stdout"]["ref"].get<std::string>();
    INFO("引用 = " << ref);
    REQUIRE(ref.find(".aliasagent") != std::string::npos);
    REQUIRE(file_exists(ref));
    // 文件里两头的标记都在（它就是"完整输出"）
    std::ifstream f(ref, std::ios::binary);
    const std::string full((std::istreambuf_iterator<char>(f)), std::istreambuf_iterator<char>());
    REQUIRE(full.find("HEAD-MARKER") != std::string::npos);
    REQUIRE(full.find("TAIL-MARKER") != std::string::npos);
    REQUIRE(full.size() == r["spill"]["stdout"]["total_bytes"].get<size_t>());
    REQUIRE(full_output_files() == before);  // 系统临时目录里不再新增文件
}

TEST_CASE("run_command: 超长输出头尾都进结果、并给出 spill 引用", "[spill]") {
    const int before = full_output_files();
    // 构建失败的现场：第一条 error 在**头部**、总结在**尾部**，中间是大段日志。
    // 旧行为只留尾部，头部的 error 必被砍掉 —— 这条用例就是钉这件事。
    const std::string cmd =
        "[Console]::Out.Write(\"error C2065: 'foo': undeclared identifier`n\")\n"
        "[Console]::Out.Write('A' * 199950)\n"
        "[Console]::Out.Write(\"`nBuild FAILED.`n\")\n";
    const json r = run_req(json{{"command", cmd}, {"spill_session", "cpp-test"}}.dump());
    INFO("r 摘要: ok=" << r["ok"] << " exit=" << r["exit_code"]
                       << " stdout_chars=" << r["stdout"].get<std::string>().size());
    REQUIRE(r["ok"] == true);

    // ① 给模型看的那份里，头部那条 error 与尾部那句总结**都在**
    const std::string out = r["stdout"].get<std::string>();
    INFO("给模型的那份（前 200 字符）：" << out.substr(0, 200));
    REQUIRE(out.find("error C2065") != std::string::npos);   // 头部留下
    REQUIRE(out.find("Build FAILED.") != std::string::npos);  // 尾部留下

    // ② 信封带量，且引用指向的文件真的存着 200000 字节左右的内容
    REQUIRE(r.contains("spill"));
    const json& env = r["spill"]["stdout"];
    INFO("信封: " << env.dump());
    REQUIRE(env["total_bytes"].get<size_t>() > 100000);
    REQUIRE(env["omitted_bytes"].get<size_t>() > 0);
    REQUIRE(env["head"].get<std::string>().find("error C2065") != std::string::npos);
    REQUIRE(env["tail"].get<std::string>().find("Build FAILED.") != std::string::npos);

    const std::string ref = env["ref"].get<std::string>();
    INFO("引用 = " << ref);
    REQUIRE(file_exists(ref));
    // 信封的总量必须等于文件实际大小（不是信封自己说多少就是多少）
    std::ifstream f(ref, std::ios::binary);
    f.seekg(0, std::ios::end);
    REQUIRE(static_cast<size_t>(f.tellg()) == env["total_bytes"].get<size_t>());
    f.close();
    // 全长 / 内联 / 省略三个数必须闭合
    REQUIRE(env["head"].get<std::string>().size() +
                env["tail"].get<std::string>().size() +
                env["omitted_bytes"].get<size_t>() ==
            env["total_bytes"].get<size_t>());

    // ③ 不再有任何指向系统临时目录的东西：旧的 `full_output_paths` 与两个旧计数
    //    字段都不许出现，系统临时目录里也不许新增 `aliasagent_run_command_*.log`。
    REQUIRE(r.contains("full_output_paths") == false);
    REQUIRE(r.contains("stdout_original_chars") == false);
    REQUIRE(r.contains("stdout_kept_chars") == false);
    REQUIRE(ref.find(".aliasagent") != std::string::npos);
    REQUIRE(ref.find("spill") != std::string::npos);
    REQUIRE(full_output_files() == before);

    // 用例自己建的会话目录自己清掉（别往用户主目录里留测试垃圾）
    remove_dir_recursive(spill::root() + "\\cpp-test");
}

TEST_CASE("run_command: 两条流同时超限时各给一个引用", "[spill]") {
    // 规范 `command-tool` 的场景：stdout 与 stderr 都远超预览阈值。
    // 两边各写一个自己的 spill 文件，两个引用必须不同、文件各是 200000 字节。
    const std::string cmd =
        "[Console]::Out.Write('X' * 200000); "
        "[Console]::Error.Write('Y' * 200000)";
    const json r = run_req(json{{"command", cmd}, {"spill_session", "cpp-test"}}.dump());
    INFO("r 摘要: ok=" << r["ok"] << " truncated=" << r["truncated"].dump());
    REQUIRE(r["ok"] == true);
    REQUIRE(r["truncated"]["stdout"] == true);
    REQUIRE(r["truncated"]["stderr"] == true);

    const std::string outRef = r["spill"]["stdout"]["ref"].get<std::string>();
    const std::string errRef = r["spill"]["stderr"]["ref"].get<std::string>();
    INFO("outRef=" << outRef);
    INFO("errRef=" << errRef);
    REQUIRE(outRef != errRef);
    REQUIRE(file_exists(outRef));
    REQUIRE(file_exists(errRef));
    // 两个文件都装着 200000 字节的完整输出，且信封的总量与之相符
    for (const auto& pair : {std::make_pair(outRef, "stdout"), std::make_pair(errRef, "stderr")}) {
        std::ifstream f(pair.first, std::ios::binary);
        f.seekg(0, std::ios::end);
        REQUIRE(static_cast<size_t>(f.tellg()) == 200000);
        f.close();
        REQUIRE(r["spill"][pair.second]["total_bytes"].get<size_t>() == 200000);
        REQUIRE(r["spill"][pair.second]["omitted_bytes"].get<size_t>() > 0);
    }
    // 给模型的那份里两条流都被标成省略（不是只省略一条）
    const std::string out = r["stdout"].get<std::string>();
    const std::string err = r["stderr"].get<std::string>();
    REQUIRE(out.find("bytes omitted") != std::string::npos);
    REQUIRE(err.find("bytes omitted") != std::string::npos);

    remove_dir_recursive(spill::root() + "\\cpp-test");
}

TEST_CASE("run_command: 未超限时也落盘、内联全文、临时目录不新增文件", "[command_tool]") {
    const int before = full_output_files();
    const json r = run_req(json{{"command", "Write-Output 'short-output'"}}.dump());
    INFO("r = " << r.dump());
    REQUIRE(r["ok"] == true);
    REQUIRE(r["truncated"]["stdout"] == false);
    REQUIRE(r["truncated"]["stderr"] == false);
    REQUIRE(r.contains("full_output_paths") == false);
    REQUIRE(full_output_files() == before);  // 系统临时目录没有新增
    // 小输出也要落盘：引用在、文件在、一个字节都没省略
    REQUIRE(r.contains("spill"));
    const std::string ref = r["spill"]["stdout"]["ref"].get<std::string>();
    REQUIRE(file_exists(ref));
    REQUIRE(r["spill"]["stdout"]["omitted_bytes"].get<size_t>() == 0);
    REQUIRE(r["stdout"].get<std::string>().find("short-output") != std::string::npos);
}

TEST_CASE("run_command: preview_chars 非法时回落到缺省 1000", "[command_tool]") {
    // 0 不是合法的"每侧字符数"，必须回落到缺省 1000，而不是"什么都不留"。
    // （旧用例在这里传的是已废弃的 `max_output_chars`；那个键不再影响任何行为，
    //  它的"超过写文件上限就不落文件"分支也随系统临时文件一起删掉了 ——
    //  写盘失败的两种处置改由 `spill_write_test.cpp` 的 4.1 / 4.2 覆盖。）
    const std::string cmd = "1..400 | ForEach-Object { Write-Output ('y' * 40) }";
    const json r = run_req(json{{"command", cmd}, {"preview_chars", 0}}.dump());
    INFO("r 摘要: truncated=" << r["truncated"]["stdout"]
                              << " head_bytes="
                              << r["spill"]["stdout"]["head"].get<std::string>().size());
    REQUIRE(r["ok"] == true);
    REQUIRE(r["truncated"]["stdout"] == true);
    // head 是全 ASCII 的原始字节切片 ⇒ 字节数就是字符数，必须正好 1000
    REQUIRE(r["spill"]["stdout"]["head"].get<std::string>().size() == 1000);
}

// ---------------------------------------------------------------------------
// 生效超时的算法
// ---------------------------------------------------------------------------

TEST_CASE("run_command: 生效超时的算法", "[command_tool]") {
    // 不填超时 → 用缺省值（命令很快结束，这里只看它没被当成"立刻超时"）
    {
        const json r = run_req(json{{"command", "Write-Output 'no-timeout-given'"}}.dump());
        REQUIRE(r["ok"] == true);
        REQUIRE(r["timed_out"] == false);
    }
    // 给一个小于上限的超时 → 按给的值执行（500 毫秒对 5 秒睡眠，必然超时）
    {
        const json r = run_req(json{{"command", "Start-Sleep -Seconds 5"},
                                    {"timeout_ms", 500},
                                    {"max_timeout_ms", 600000}}
                                       .dump());
        INFO("r = " << r.dump());
        REQUIRE(r["ok"] == true);
        REQUIRE(r["timed_out"] == true);
        REQUIRE(r["duration_ms"].get<long long>() < 3000);  // 没有被抬成整秒
    }
    // 给一个大于上限的超时 → 按上限执行（上限设成 500，命令睡 5 秒）
    {
        const json r = run_req(json{{"command", "Start-Sleep -Seconds 5"},
                                    {"timeout_ms", 600000},
                                    {"max_timeout_ms", 500}}
                                       .dump());
        INFO("r = " << r.dump());
        REQUIRE(r["ok"] == true);
        REQUIRE(r["timed_out"] == true);
        REQUIRE(r["duration_ms"].get<long long>() < 3000);
    }
}

// ---------------------------------------------------------------------------
// 工作目录
// ---------------------------------------------------------------------------

TEST_CASE("run_command: workdir 真的成为本次命令的工作目录", "[command_tool]") {
    TempDir tmp;
    std::string base = tmp.path();
    for (auto& c : base)
        if (c == '/') c = '\\';
    const std::string sub = base + "\\sub工作目录";
    // 建目录要用**正确的** UTF-8→UTF-16 转换（`subprocess::utf8_to_wide`），
    // 不能把每个字节直接当码元塞进 std::wstring：那样建出来的是另一个名字
    // （本机实测：这么建出来的目录根本没有"sub工作目录"这个名字，而后面的
    // 查找又找不到它，症状是"目录明明建好了却说它不存在"）。
    const std::wstring wide = subprocess::utf8_to_wide(sub);
    REQUIRE(wide.empty() == false);
    REQUIRE(_wmkdir(wide.c_str()) == 0);
    REQUIRE(GetFileAttributesW(wide.c_str()) != INVALID_FILE_ATTRIBUTES);

    WorkspaceGuard guard(base);
    const json r = run_req(json{{"command", "(Get-Location).Path"}, {"workdir", "sub工作目录"}}.dump());
    INFO("r = " << r.dump());
    REQUIRE(r["ok"] == true);
    REQUIRE(r["stdout"].get<std::string>().find("sub工作目录") != std::string::npos);
}

TEST_CASE("run_command: 工作区之外的 workdir 被拒绝且命令不执行", "[command_tool]") {
    TempDir tmp;
    std::string base = tmp.path();
    for (auto& c : base)
        if (c == '/') c = '\\';
    WorkspaceGuard guard(base);
    const std::string marker = base + "\\REJECT-MARKER.txt";
    const json r = run_req(json{{"command", "Set-Content -Path '" + marker + "' -Value x"},
                                {"workdir", ".."}}
                               .dump());
    INFO("r = " << r.dump());
    REQUIRE(r["ok"] == false);
    REQUIRE(file_exists(marker) == false);  // 命令没被执行
}

// ---------------------------------------------------------------------------
// 非零退出码、两条流分开、输出含非法 UTF-8
// ---------------------------------------------------------------------------

TEST_CASE("run_command: 非零退出码仍是成功执行、两条流分开", "[command_tool]") {
    const json r = run_req(json{{"command",
                                 "[Console]::Out.Write('OUT-TOKEN'); "
                                 "[Console]::Error.Write('ERR-TOKEN'); exit 3"}}
                                .dump());
    INFO("r = " << r.dump());
    REQUIRE(r["ok"] == true);
    REQUIRE(r["exit_code"] == 3);
    REQUIRE(r["timed_out"] == false);
    REQUIRE(r["stdout"].get<std::string>().find("OUT-TOKEN") != std::string::npos);
    REQUIRE(r["stdout"].get<std::string>().find("ERR-TOKEN") == std::string::npos);
    REQUIRE(r["stderr"].get<std::string>().find("ERR-TOKEN") != std::string::npos);
    REQUIRE(r["stderr"].get<std::string>().find("OUT-TOKEN") == std::string::npos);
}

TEST_CASE("run_command: 输出含非法 UTF-8 字节时不崩、返回结构合法", "[command_tool]") {
    // 把坏字节写在一个脚本文件里再执行，而不是塞进命令行 —— 直接塞进命令行会被
    // PowerShell 的恶意脚本检测（AMSI）拦下，报 "contains malicious content"，
    // 那样测到的是检测器而不是我们的解码路径。
    TempDir tmp;
    tmp.write("bad.ps1", "$b = [byte[]](0x41,0x80,0x42)\n[Console]::OpenStandardOutput().Write($b,0,3)\n");
    std::string script = tmp.path();
    for (auto& c : script)
        if (c == '/') c = '\\';
    script += "\\bad.ps1";
    const json r = run_req(json{{"command", "& '" + script + "'"}}.dump());
    INFO("r = " << r.dump());
    REQUIRE(r["ok"] == true);
    REQUIRE(r["exit_code"] == 0);
    const std::string out = r["stdout"].get<std::string>();
    REQUIRE(out.find("A") != std::string::npos);
    REQUIRE(out.find("B") != std::string::npos);
    REQUIRE(out.find("\xEF\xBF\xBD") != std::string::npos);  // 坏字节被换成替换字符
}

TEST_CASE("run_command: 超时终止整棵进程树（子进程不残留）", "[command_tool]") {
    // 命令先拉起一个孙进程并打印它的 PID，然后自己长睡到被超时终止。
    // 超时之后那个孙进程必须不存在 —— 只杀直接子进程的实现会让它留下来。
    const std::string cmd =
        "$p = Start-Process -FilePath 'cmd.exe' -ArgumentList '/C','ping -n 60 127.0.0.1' "
        "-PassThru -WindowStyle Hidden\n"
        "Write-Output ('CHILD-PID=' + $p.Id)\n"
        "[System.Threading.Thread]::Sleep(20000)\n";
    const json r = run_req(json{{"command", cmd}, {"timeout_ms", 3000}}.dump());
    INFO("r = " << r.dump());
    INFO("r = " << r.dump());
    REQUIRE(r["ok"] == true);
    REQUIRE(r["timed_out"] == true);

    // 从输出里把孙进程的 PID 抠出来
    const std::string out = r["stdout"].get<std::string>();
    const size_t at = out.find("CHILD-PID=");
    REQUIRE(at != std::string::npos);  // 拿不到 PID 就没法判"残留"这件事
    std::string pid = out.substr(at + 10);
    const size_t nl = pid.find('\n');
    if (nl != std::string::npos) pid = pid.substr(0, nl);
    while (!pid.empty() && (pid.back() == '\r' || pid.back() == ' ')) pid.pop_back();

    // 给系统一点时间让终止生效，再查这个 PID 还在不在
    Sleep(1500);
    const std::string cmdline = "cmd.exe /C tasklist /FI \"PID eq " + pid + "\"";
    const json check = run_req(json{{"command", cmdline}}.dump());
    const std::string listing = check["stdout"].get<std::string>();
    INFO("孙进程 PID = " << pid);
    INFO("tasklist 输出:\n" << listing);
    REQUIRE(listing.find(pid) == std::string::npos);  // 不残留
}

TEST_CASE("run_command: 出错路径返回可读的中文说明", "[command_tool]") {
    {
        const json r = run_req("{}");
        REQUIRE(r["ok"] == false);
        REQUIRE(r["error"].get<std::string>().find("command") != std::string::npos);
    }
    {
        const json r = run_req("not json at all");
        REQUIRE(r["ok"] == false);
        REQUIRE(r["error"].get<std::string>().find("JSON") != std::string::npos);
    }
}
