#include <catch2/catch_all.hpp>
#include "temp_dir.h"
#include "tools.h"
#include <string>
#include <algorithm>
#include <fstream>
#include <iostream>
#include <nlohmann/json.hpp>

using json = nlohmann::json;

static json parse_result(const std::string& raw) {
    return json::parse(raw);
}

// True when the tool returned the rg-not-found install guidance. Used to guard
// functional tests that require a real rg binary (matching the project's
// live-test precedent: skip with a WARN when the environment lacks the tool).
static bool is_rg_missing(const json& j) {
    if (!j.contains("ok") || j["ok"] != false) return false;
    if (!j.contains("error")) return false;
    std::string err = j["error"].get<std::string>();
    return err.find("rg not found") != std::string::npos;
}

// ============================================================================
// glob_file — validation (no rg required)
// ============================================================================

TEST_CASE("glob_file: path traversal segment rejected", "[glob_file]") {
    TempDir tmp;
    WorkspaceGuard ws(tmp.path());

    auto j = parse_result(tools::glob_file("{\"pattern\":\"../secret\"}"));
    REQUIRE(j["ok"] == false);
    REQUIRE(j["error"] == "path traversal not allowed (..)");
}

TEST_CASE("glob_file: absolute path rejected", "[glob_file]") {
    TempDir tmp;
    WorkspaceGuard ws(tmp.path());

#ifdef _WIN32
    auto j = parse_result(tools::glob_file("{\"pattern\":\"C:/Windows\"}"));
#else
    auto j = parse_result(tools::glob_file("{\"pattern\":\"/etc\"}"));
#endif
    REQUIRE(j["ok"] == false);
    REQUIRE(j["error"] == "absolute path not allowed");
}

TEST_CASE("glob_file: invalid character rejected", "[glob_file]") {
    TempDir tmp;
    WorkspaceGuard ws(tmp.path());

    auto j = parse_result(tools::glob_file("{\"pattern\":\"foo&bar\"}"));
    REQUIRE(j["ok"] == false);
    REQUIRE(j["error"].get<std::string>().find("invalid character") != std::string::npos);
}

TEST_CASE("glob_file: empty pattern rejected", "[glob_file]") {
    TempDir tmp;
    WorkspaceGuard ws(tmp.path());

    auto j = parse_result(tools::glob_file("{\"pattern\":\"\"}"));
    REQUIRE(j["ok"] == false);
    REQUIRE(j["error"] == "pattern is required");
}

TEST_CASE("glob_file: no workspace set", "[glob_file]") {
    tools::set_workspace("");
    WorkspaceGuard ws("");

    auto j = parse_result(tools::glob_file("{\"pattern\":\"*.txt\"}"));
    REQUIRE(j["ok"] == false);
    REQUIRE(j["error"] == "No workspace set");
}

TEST_CASE("glob_file: rg missing returns install guidance", "[glob_file]") {
    TempDir tmp;
    WorkspaceGuard ws(tmp.path());

    auto j = parse_result(tools::glob_file("{\"pattern\":\"*.txt\"}"));
    if (!is_rg_missing(j)) {
        WARN("rg present — skipping rg-missing assertion");
        SUCCEED();
        return;
    }
    REQUIRE(j["ok"] == false);
    REQUIRE(j["error"].get<std::string>().find("rg not found") != std::string::npos);
}

// ============================================================================
// glob_file — functional (requires rg; skipped with WARN when absent)
// ============================================================================

TEST_CASE("glob_file: recursive extension match", "[glob_file]") {
    TempDir tmp;
    tmp.write("lib/a.dart", "x");
    tmp.write("lib/sub/b.dart", "y");
    WorkspaceGuard ws(tmp.path());

    auto j = parse_result(tools::glob_file("{\"pattern\":\"lib/**/*.dart\"}"));
    if (is_rg_missing(j)) { WARN("rg not installed — skipping functional assertion"); SUCCEED(); return; }
    REQUIRE(j["ok"] == true);
    std::vector<std::string> paths;
    for (auto& p : j["paths"]) paths.push_back(p.get<std::string>());
    REQUIRE(std::find(paths.begin(), paths.end(), "lib/a.dart") != paths.end());
    REQUIRE(std::find(paths.begin(), paths.end(), "lib/sub/b.dart") != paths.end());
}

TEST_CASE("glob_file: 'foo' does not match foo/bar", "[glob_file]") {
    TempDir tmp;
    tmp.mkdir("foo");
    tmp.write("foo/bar", "x");
    WorkspaceGuard ws(tmp.path());

    // man page counter-example: "foo/bar does not match the glob foo"
    auto j = parse_result(tools::glob_file("{\"pattern\":\"foo\"}"));
    if (is_rg_missing(j)) { WARN("rg not installed — skipping functional assertion"); SUCCEED(); return; }
    REQUIRE(j["ok"] == true);
    std::vector<std::string> paths;
    for (auto& p : j["paths"]) paths.push_back(p.get<std::string>());
    REQUIRE(std::find(paths.begin(), paths.end(), "foo/bar") == paths.end());

    // the man page remedy: -g 'foo/**' matches inside foo
    auto j2 = parse_result(tools::glob_file("{\"pattern\":\"foo/**\"}"));
    if (is_rg_missing(j2)) { WARN("rg not installed — skipping functional assertion"); SUCCEED(); return; }
    REQUIRE(j2["ok"] == true);
    std::vector<std::string> paths2;
    for (auto& p : j2["paths"]) paths2.push_back(p.get<std::string>());
    REQUIRE(std::find(paths2.begin(), paths2.end(), "foo/bar") != paths2.end());
}

TEST_CASE("glob_file: question mark matches single character", "[glob_file]") {
    TempDir tmp;
    tmp.write("test/aa_x.dart", "x");
    tmp.write("test/ab_y.dart", "x");
    tmp.write("test/xyz.dart", "x");
    WorkspaceGuard ws(tmp.path());

    auto j = parse_result(tools::glob_file("{\"pattern\":\"test/??_*.dart\"}"));
    if (is_rg_missing(j)) { WARN("rg not installed — skipping functional assertion"); SUCCEED(); return; }
    REQUIRE(j["ok"] == true);
    std::vector<std::string> paths;
    for (auto& p : j["paths"]) paths.push_back(p.get<std::string>());
    REQUIRE(std::find(paths.begin(), paths.end(), "test/aa_x.dart") != paths.end());
    REQUIRE(std::find(paths.begin(), paths.end(), "test/ab_y.dart") != paths.end());
    REQUIRE(std::find(paths.begin(), paths.end(), "test/xyz.dart") == paths.end());
}

TEST_CASE("glob_file: ! negation excludes matching files", "[glob_file]") {
    TempDir tmp;
    tmp.write("keep.txt", "x");
    tmp.write("skip.log", "x");
    WorkspaceGuard ws(tmp.path());

    auto j = parse_result(tools::glob_file("{\"pattern\":\"!**/*.log\"}"));
    if (is_rg_missing(j)) { WARN("rg not installed — skipping functional assertion"); SUCCEED(); return; }
    REQUIRE(j["ok"] == true);
    std::vector<std::string> paths;
    for (auto& p : j["paths"]) paths.push_back(p.get<std::string>());
    REQUIRE(std::find(paths.begin(), paths.end(), "skip.log") == paths.end());
    REQUIRE(std::find(paths.begin(), paths.end(), "keep.txt") != paths.end());
}

TEST_CASE("glob_file: no matches is success with empty list", "[glob_file]") {
    TempDir tmp;
    tmp.write("only.txt", "x");
    WorkspaceGuard ws(tmp.path());

    auto j = parse_result(tools::glob_file("{\"pattern\":\"nomatch*.xyz\"}"));
    if (is_rg_missing(j)) { WARN("rg not installed — skipping functional assertion"); SUCCEED(); return; }
    REQUIRE(j["ok"] == true);
    REQUIRE(j["count"] == 0);
    REQUIRE(j["paths"].size() == 0);
}

TEST_CASE("glob_file: truncation marks truncated:true beyond max_results", "[glob_file]") {
    TempDir tmp;
    for (int i = 0; i < 205; ++i) tmp.write("f" + std::to_string(i) + ".txt", "x");
    WorkspaceGuard ws(tmp.path());

    auto j = parse_result(tools::glob_file("{\"pattern\":\"*.txt\",\"max_results\":200}"));
    if (is_rg_missing(j)) { WARN("rg not installed — skipping functional assertion"); SUCCEED(); return; }
    REQUIRE(j["ok"] == true);
    REQUIRE(j["count"] == 200);
    REQUIRE(j["paths"].size() == 200);
    REQUIRE(j["truncated"] == true);
}

TEST_CASE("glob_file: exactly max_results is not truncated", "[glob_file]") {
    TempDir tmp;
    for (int i = 0; i < 200; ++i) tmp.write("g" + std::to_string(i) + ".txt", "x");
    WorkspaceGuard ws(tmp.path());

    auto j = parse_result(tools::glob_file("{\"pattern\":\"*.txt\",\"max_results\":200}"));
    if (is_rg_missing(j)) { WARN("rg not installed — skipping functional assertion"); SUCCEED(); return; }
    REQUIRE(j["ok"] == true);
    REQUIRE(j["count"] == 200);
    REQUIRE(j["paths"].size() == 200);
    REQUIRE_FALSE(j.contains("truncated"));
}

TEST_CASE("glob_file: paths are workspace-relative (de-rooted)", "[glob_file]") {
    TempDir tmp;
    tmp.write("rel.txt", "x");
    tmp.mkdir("deep");
    tmp.write("deep/nested.txt", "x");
    WorkspaceGuard ws(tmp.path());

    auto j = parse_result(tools::glob_file("{\"pattern\":\"**/*.txt\"}"));
    if (is_rg_missing(j)) { WARN("rg not installed — skipping functional assertion"); SUCCEED(); return; }
    REQUIRE(j["ok"] == true);
    std::vector<std::string> paths;
    for (auto& p : j["paths"]) paths.push_back(p.get<std::string>());
    std::string root = tmp.path();
    for (auto& p : paths) {
        REQUIRE(p.find(root) == std::string::npos);
#ifdef _WIN32
        REQUIRE_FALSE((p.size() >= 2 && p[1] == ':'));
#endif
    }
    REQUIRE(std::find(paths.begin(), paths.end(), "rel.txt") != paths.end());
    REQUIRE(std::find(paths.begin(), paths.end(), "deep/nested.txt") != paths.end());
}

TEST_CASE("glob_file: filename with .. inside a segment is legal", "[glob_file]") {
    TempDir tmp;
    tmp.write("a..b.txt", "x");
    WorkspaceGuard ws(tmp.path());

    auto j = parse_result(tools::glob_file("{\"pattern\":\"a..b.txt\"}"));
    if (is_rg_missing(j)) {
        // Validation must have passed — any error is NOT traversal/invalid char
        REQUIRE(j["ok"] == false);
        std::string err = j["error"].get<std::string>();
        REQUIRE(err.find("path traversal") == std::string::npos);
        REQUIRE(err.find("invalid character") == std::string::npos);
        SUCCEED("rg missing — validation-only check");
        return;
    }
    REQUIRE(j["ok"] == true);
    std::vector<std::string> paths;
    for (auto& p : j["paths"]) paths.push_back(p.get<std::string>());
    REQUIRE(std::find(paths.begin(), paths.end(), "a..b.txt") != paths.end());
}

// ============================================================================
// grep_file — validation (no rg required)
// ============================================================================

TEST_CASE("grep_file: empty pattern rejected", "[grep_file]") {
    TempDir tmp;
    WorkspaceGuard ws(tmp.path());

    auto j = parse_result(tools::grep_file("{\"pattern\":\"\"}"));
    REQUIRE(j["ok"] == false);
    REQUIRE(j["error"] == "pattern is required");
}

TEST_CASE("grep_file: glob path traversal rejected", "[grep_file]") {
    TempDir tmp;
    WorkspaceGuard ws(tmp.path());

    auto j = parse_result(tools::grep_file("{\"pattern\":\"x\",\"glob\":\"../secret\"}"));
    REQUIRE(j["ok"] == false);
    REQUIRE(j["error"] == "path traversal not allowed (..)");
}

TEST_CASE("grep_file: no workspace set", "[grep_file]") {
    tools::set_workspace("");
    WorkspaceGuard ws("");

    auto j = parse_result(tools::grep_file("{\"pattern\":\"x\"}"));
    REQUIRE(j["ok"] == false);
    REQUIRE(j["error"] == "No workspace set");
}

// ============================================================================
// grep_file — functional (requires rg; skipped with WARN when absent)
// ============================================================================

TEST_CASE("grep_file: find symbol references with relative paths", "[grep_file]") {
    TempDir tmp;
    tmp.write("code.cpp", "int request_mutex = 0;\nint main() {\n  return request_mutex;\n}\n");
    tmp.write("other.txt", "no match here\n");
    WorkspaceGuard ws(tmp.path());

    auto j = parse_result(tools::grep_file("{\"pattern\":\"request_mutex\"}"));
    if (is_rg_missing(j)) { WARN("rg not installed — skipping functional assertion"); SUCCEED(); return; }
    REQUIRE(j["ok"] == true);
    REQUIRE(j["count"] == 2);
    for (auto& m : j["matches"]) {
        REQUIRE(m["path"].get<std::string>().find(tmp.path()) == std::string::npos);
    }
}

TEST_CASE("grep_file: glob filter restricts search", "[grep_file]") {
    TempDir tmp;
    tmp.write("sidecar/a.cpp", "TODO: fix\n");
    tmp.write("sidecar/b.txt", "TODO: fix\n");
    WorkspaceGuard ws(tmp.path());

    auto j = parse_result(tools::grep_file("{\"pattern\":\"TODO\",\"glob\":\"sidecar/*.cpp\"}"));
    if (is_rg_missing(j)) { WARN("rg not installed — skipping functional assertion"); SUCCEED(); return; }
    REQUIRE(j["ok"] == true);
    REQUIRE(j["count"] == 1);
    REQUIRE(j["matches"][0]["path"].get<std::string>() == "sidecar/a.cpp");
}

TEST_CASE("grep_file: ignore_case matches all case variants", "[grep_file]") {
    TempDir tmp;
    tmp.write("t.txt", "today Today TODAY\n");
    WorkspaceGuard ws(tmp.path());

    auto j = parse_result(tools::grep_file("{\"pattern\":\"today\",\"ignore_case\":true}"));
    if (is_rg_missing(j)) { WARN("rg not installed — skipping functional assertion"); SUCCEED(); return; }
    REQUIRE(j["ok"] == true);
    REQUIRE(j["count"] == 1);  // one matching line
    REQUIRE(j["matches"][0]["line"] == 1);
}

TEST_CASE("grep_file: dash-leading pattern is literal", "[grep_file]") {
    TempDir tmp;
    tmp.write("d.txt", "-foo bar\n");
    WorkspaceGuard ws(tmp.path());

    auto j = parse_result(tools::grep_file("{\"pattern\":\"-foo\"}"));
    if (is_rg_missing(j)) { WARN("rg not installed — skipping functional assertion"); SUCCEED(); return; }
    REQUIRE(j["ok"] == true);
    REQUIRE(j["count"] == 1);
    REQUIRE(j["matches"][0]["text"].get<std::string>().find("-foo") != std::string::npos);
}

TEST_CASE("grep_file: invalid regex returns invalid regex error", "[grep_file]") {
    TempDir tmp;
    tmp.write("x.txt", "hello\n");
    WorkspaceGuard ws(tmp.path());

    auto j = parse_result(tools::grep_file("{\"pattern\":\"(?<unclosed\"}"));
    if (is_rg_missing(j)) { WARN("rg not installed — skipping functional assertion"); SUCCEED(); return; }
    REQUIRE(j["ok"] == false);
    REQUIRE(j["error"].get<std::string>().find("invalid regex") != std::string::npos);
}

TEST_CASE("grep_file: no matches is success with empty list", "[grep_file]") {
    TempDir tmp;
    tmp.write("n.txt", "hello world\n");
    WorkspaceGuard ws(tmp.path());

    auto j = parse_result(tools::grep_file("{\"pattern\":\"zzznomatch\"}"));
    if (is_rg_missing(j)) { WARN("rg not installed — skipping functional assertion"); SUCCEED(); return; }
    REQUIRE(j["ok"] == true);
    REQUIRE(j["count"] == 0);
}

TEST_CASE("grep_file: truncation beyond max_results", "[grep_file]") {
    TempDir tmp;
    std::string content;
    for (int i = 0; i < 250; ++i) content += "match line " + std::to_string(i) + "\n";
    tmp.write("big.txt", content);
    WorkspaceGuard ws(tmp.path());

    auto j = parse_result(tools::grep_file("{\"pattern\":\"match\",\"max_results\":100}"));
    if (is_rg_missing(j)) { WARN("rg not installed — skipping functional assertion"); SUCCEED(); return; }
    REQUIRE(j["ok"] == true);
    REQUIRE(j["count"] == 100);
    REQUIRE(j["matches"].size() == 100);
    REQUIRE(j["truncated"] == true);
}

TEST_CASE("grep_file: exactly max_results not truncated", "[grep_file]") {
    TempDir tmp;
    std::string content;
    for (int i = 0; i < 100; ++i) content += "exact " + std::to_string(i) + "\n";
    tmp.write("exact.txt", content);
    WorkspaceGuard ws(tmp.path());

    auto j = parse_result(tools::grep_file("{\"pattern\":\"exact\",\"max_results\":100}"));
    if (is_rg_missing(j)) { WARN("rg not installed — skipping functional assertion"); SUCCEED(); return; }
    REQUIRE(j["ok"] == true);
    REQUIRE(j["count"] == 100);
    REQUIRE(j["matches"].size() == 100);
    REQUIRE_FALSE(j.contains("truncated"));
}

TEST_CASE("grep_file: pattern with space survives command-line construction", "[grep_file]") {
    TempDir tmp;
    tmp.write("s.txt", "hello world here\n");
    WorkspaceGuard ws(tmp.path());

    auto j = parse_result(tools::grep_file("{\"pattern\":\"hello world\"}"));
    if (is_rg_missing(j)) { WARN("rg not installed — skipping functional assertion"); SUCCEED(); return; }
    REQUIRE(j["ok"] == true);
    REQUIRE(j["count"] == 1);
}

TEST_CASE("grep_file: pattern with double quote survives command-line construction", "[grep_file]") {
    TempDir tmp;
    tmp.write("q.txt", "say \"hi\" now\n");
    WorkspaceGuard ws(tmp.path());

    auto j = parse_result(tools::grep_file("{\"pattern\":\"say \\\"hi\\\"\"}"));
    if (is_rg_missing(j)) { WARN("rg not installed — skipping functional assertion"); SUCCEED(); return; }
    REQUIRE(j["ok"] == true);
    REQUIRE(j["count"] == 1);
}

TEST_CASE("grep_file: rg missing returns install guidance", "[grep_file]") {
    TempDir tmp;
    WorkspaceGuard ws(tmp.path());

    auto j = parse_result(tools::grep_file("{\"pattern\":\"x\"}"));
    if (!is_rg_missing(j)) {
        WARN("rg present — skipping rg-missing assertion");
        SUCCEED();
        return;
    }
    REQUIRE(j["ok"] == false);
    REQUIRE(j["error"].get<std::string>().find("rg not found") != std::string::npos);
}

// ============================================================================
// grep_file — stderr classification (soft error vs regex error discrimination)
// ============================================================================

TEST_CASE("grep_file: stderr classifier distinguishes regex vs soft errors", "[grep_file]") {
    // Regex parse error (rg's typical regex-error stderr format) → regex
    REQUIRE(tools::classify_grep_regex_error(
        "regex parse error:\n    (?<foo\n    ^\nerror: unclosed group") == true);
    REQUIRE(tools::classify_grep_regex_error("regex parse error") == true);
    // Soft error (e.g. unreadable file) → NOT a regex error → "search failed"
    REQUIRE(tools::classify_grep_regex_error("file.txt: Permission denied (os error 13)") == false);
    REQUIRE(tools::classify_grep_regex_error("") == false);
    REQUIRE(tools::classify_grep_regex_error("failed to open directory: No such file") == false);
}

// ============================================================================
// grep_file — lenient --json match-entry parsing degradation
// ============================================================================

TEST_CASE("grep_file: lenient match-entry parsing degrades gracefully", "[grep_file]") {
    using json = nlohmann::json;
    const std::string root = "C:/ws";

    // path.text + line_number + lines.text → normal entry, path de-rooted
    json data1 = {
        {"path", {{"text", "C:/ws/a.txt"}}},
        {"line_number", 3},
        {"lines", {{"text", "hello world\n"}}},
    };
    auto e1 = tools::build_match_entry(data1, root);
    REQUIRE(e1["path"] == "a.txt");
    REQUIRE(e1["line"] == 3);
    REQUIRE(e1["text"] == "hello world\n");

    // path.bytes (base64) instead of text → decoded; no line_number → omitted
    // ("a.txt" in base64 is "YS50eHQ=")
    json data2 = {
        {"path", {{"bytes", "YS50eHQ="}}},
        {"lines", {{"text", "x\n"}}},
    };
    auto e2 = tools::build_match_entry(data2, root);
    REQUIRE(e2["path"] == "a.txt");
    REQUIRE_FALSE(e2.contains("line"));

    // lines.bytes (base64) instead of text → decoded ("hi\n" is "aGkK")
    json data3 = {
        {"path", {{"text", "b.txt"}}},
        {"line_number", 1},
        {"lines", {{"bytes", "aGkK"}}},
    };
    auto e3 = tools::build_match_entry(data3, root);
    REQUIRE(e3["text"] == "hi\n");

    // path entirely absent → no path field (degraded)
    json data4 = {{"line_number", 1}, {"lines", {{"text", "y\n"}}}};
    auto e4 = tools::build_match_entry(data4, root);
    REQUIRE_FALSE(e4.contains("path"));
    REQUIRE(e4["line"] == 1);

    // non-object data → empty entry (no crash)
    auto e5 = tools::build_match_entry(json("not an object"), root);
    REQUIRE(e5.empty());
}
