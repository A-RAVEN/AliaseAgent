#include <catch2/catch_all.hpp>
#include "subprocess.h"
#include <chrono>

// ============================================================================
// 2.3 — subprocess command-line escaping (CreateProcessA quoting rules)
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
