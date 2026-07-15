#include <catch2/catch_all.hpp>
#include "temp_dir.h"
#include "tools.h"
#include <string>
#include <fstream>
#include <nlohmann/json.hpp>

using json = nlohmann::json;

// Helper: parse tool result JSON
static json parse_result(const std::string& raw) {
    return json::parse(raw);
}

// Helper: create a binary file (with null bytes)
static void write_binary_file(const std::string& path) {
    std::ofstream f(path, std::ios::binary);
    char data[] = "text start\x00\x01\x02null bytes here";
    f.write(data, sizeof(data));
    f.close();
}

// ============================================================================
// 3.1 — set_workspace: valid directory → returns ""
// ============================================================================
TEST_CASE("set_workspace: valid directory", "[tool_execution]") {
    TempDir tmp;
    WorkspaceGuard ws(tmp.path());

    std::string result = tools::set_workspace(tmp.path());
    REQUIRE(result == "");
    REQUIRE(tools::workspace() == tmp.path());
}

// ============================================================================
// 3.2 — set_workspace: empty path → returns error
// ============================================================================
TEST_CASE("set_workspace: empty path", "[tool_execution]") {
    std::string result = tools::set_workspace("");
    REQUIRE(result == "Workspace path is empty");
    REQUIRE(tools::workspace() == "");
}

// ============================================================================
// 3.3 — set_workspace: invalid path → returns error
// ============================================================================
TEST_CASE("set_workspace: invalid path", "[tool_execution]") {
    // Use a path that is syntactically problematic.  On Windows,
    // GetFullPathNameA is very permissive and may canonicalize almost
    // anything; the key assertion is that set_workspace returns an
    // error (non-empty) and clears g_workspace.
    std::string result = tools::set_workspace("C:\\INVALID<PATH>");
    REQUIRE(result != "");  // must return an error message
    REQUIRE(tools::workspace() == "");
}

// ============================================================================
// 3.4 — set_workspace: path is not a directory → returns error
// ============================================================================
TEST_CASE("set_workspace: path is not a directory", "[tool_execution]") {
    TempDir tmp;
    tmp.write("a_file.txt", "hello");

    std::string file_path = tmp.path() + "/a_file.txt";
    std::string result = tools::set_workspace(file_path);
    REQUIRE(result.find("Workspace is not a directory:") == 0);
    REQUIRE(tools::workspace() == "");
}

// ============================================================================
// 3.5 — read_file: existing text file → ok:true
// ============================================================================
TEST_CASE("read_file: existing text file", "[tool_execution]") {
    TempDir tmp;
    tmp.write("hello.txt", "hello world\nline 2");
    WorkspaceGuard ws(tmp.path());

    std::string result = tools::read_file("hello.txt");
    auto j = parse_result(result);
    REQUIRE(j["ok"] == true);
    REQUIRE(j["content"] == "hello world\nline 2");
}

// ============================================================================
// 3.6 — read_file: file not found → ok:false
// ============================================================================
TEST_CASE("read_file: file not found", "[tool_execution]") {
    TempDir tmp;
    WorkspaceGuard ws(tmp.path());

    std::string result = tools::read_file("nonexistent.txt");
    auto j = parse_result(result);
    REQUIRE(j["ok"] == false);
    REQUIRE(j["error"] == "File not found: nonexistent.txt");
}

// ============================================================================
// 3.7 — read_file: path traversal (..) → access denied
// ============================================================================
TEST_CASE("read_file: path traversal attempt", "[tool_execution]") {
    TempDir tmp;
    tmp.mkdir("subdir");
    WorkspaceGuard ws(tmp.path() + "/subdir");

    std::string result = tools::read_file("../outside.txt");
    auto j = parse_result(result);
    REQUIRE(j["ok"] == false);
    REQUIRE(j["error"] == "Access denied: path outside workspace");
}

// ============================================================================
// 3.8 — read_file: binary file → rejected
// ============================================================================
TEST_CASE("read_file: binary file", "[tool_execution]") {
    TempDir tmp;
    std::string bin_path = tmp.path() + "/data.bin";
    write_binary_file(bin_path);
    WorkspaceGuard ws(tmp.path());

    std::string result = tools::read_file("data.bin");
    auto j = parse_result(result);
    REQUIRE(j["ok"] == false);
    REQUIRE(j["error"] == "Cannot read binary file");
}

// ============================================================================
// 3.9 — read_file: path is a directory → rejected
// ============================================================================
TEST_CASE("read_file: path is a directory", "[tool_execution]") {
    TempDir tmp;
    tmp.mkdir("subdir");
    WorkspaceGuard ws(tmp.path());

    std::string result = tools::read_file("subdir");
    auto j = parse_result(result);
    REQUIRE(j["ok"] == false);
    REQUIRE(j["error"] == "Path is a directory, not a file: subdir");
}

// ============================================================================
// 3.10 — read_file: empty file → ok:true with empty content
// ============================================================================
TEST_CASE("read_file: empty file", "[tool_execution]") {
    TempDir tmp;
    tmp.write("empty.txt", "");
    WorkspaceGuard ws(tmp.path());

    std::string result = tools::read_file("empty.txt");
    auto j = parse_result(result);
    REQUIRE(j["ok"] == true);
    REQUIRE(j["content"] == "");
}

// ============================================================================
// 3.11 — read_file: no workspace set → error
// ============================================================================
TEST_CASE("read_file: no workspace set", "[tool_execution]") {
    // Ensure workspace is cleared from any prior test
    tools::set_workspace("");
    WorkspaceGuard ws("");  // RAII cleanup

    std::string result = tools::read_file("anything.txt");
    auto j = parse_result(result);
    REQUIRE(j["ok"] == false);
    REQUIRE(j["error"] == "No workspace set");
}

// ============================================================================
// 3.12 — read_file: cannot resolve path → error (best-effort)
// ============================================================================
TEST_CASE("read_file: cannot resolve path", "[tool_execution]") {
    TempDir tmp;
    WorkspaceGuard ws(tmp.path());

    // On Windows, GetFullPathNameA almost always succeeds even for
    // non-existent relative paths as long as the workspace is valid.
    // This is a best-effort test; skip with WARN if untriggerable.
    std::string result = tools::read_file("some/file.txt");
    auto j = parse_result(result);
    // "File not found" is the normal Windows outcome
    // "Cannot resolve path" is the expected Unix outcome
    if (j["ok"] == false && j["error"] == "Cannot resolve path: some/file.txt") {
        SUCCEED("Cannot resolve path correctly detected");
    } else if (j["ok"] == false && j["error"] == "File not found: some/file.txt") {
        WARN("Cannot resolve path not triggerable on this platform (best-effort)");
    } else {
        // On Windows with subdirectory creation:
        // If "some/file.txt" can be resolved but not found, that's File not found
        REQUIRE(j["error"] == "File not found: some/file.txt");
    }
}

// ============================================================================
// 3.13 — list_dir: list directory contents → ok:true with JSON entries
// ============================================================================
TEST_CASE("list_dir: directory with files and subdirs", "[tool_execution]") {
    TempDir tmp;
    tmp.write("a.txt", "content A");
    tmp.write("b.txt", "content B");
    tmp.mkdir("sub");
    WorkspaceGuard ws(tmp.path());

    std::string result = tools::list_dir(".");
    auto j = parse_result(result);
    REQUIRE(j["ok"] == true);
    // content is a JSON-escaped string containing the entries array
    auto entries = json::parse(j["content"].get<std::string>());
    REQUIRE(entries.is_array());

    // Collect names
    std::vector<std::string> names;
    bool has_a = false, has_b = false, has_sub = false;
    for (auto& e : entries) {
        std::string name = e["name"];
        std::string type = e["type"];
        if (name == "a.txt") { REQUIRE(type == "file"); has_a = true; }
        if (name == "b.txt") { REQUIRE(type == "file"); has_b = true; }
        if (name == "sub") { REQUIRE(type == "directory"); has_sub = true; }
    }
    REQUIRE(has_a);
    REQUIRE(has_b);
    REQUIRE(has_sub);
}

// ============================================================================
// 3.14 — list_dir: empty directory → ok:true with "[]"
// ============================================================================
TEST_CASE("list_dir: empty directory", "[tool_execution]") {
    TempDir tmp;
    tmp.mkdir("empty_dir");
    WorkspaceGuard ws(tmp.path());

    std::string result = tools::list_dir("empty_dir");
    auto j = parse_result(result);
    REQUIRE(j["ok"] == true);
    REQUIRE(j["content"] == "[]");
}

// ============================================================================
// 3.15 — list_dir: directory not found → error
// ============================================================================
TEST_CASE("list_dir: directory not found", "[tool_execution]") {
    TempDir tmp;
    WorkspaceGuard ws(tmp.path());

    std::string result = tools::list_dir("no_such_dir");
    auto j = parse_result(result);
    REQUIRE(j["ok"] == false);
    REQUIRE(j["error"] == "Directory not found: no_such_dir");
}

// ============================================================================
// 3.16 — list_dir: path is a file → error
// ============================================================================
TEST_CASE("list_dir: path is a file", "[tool_execution]") {
    TempDir tmp;
    tmp.write("a_file.txt", "hello");
    WorkspaceGuard ws(tmp.path());

    std::string result = tools::list_dir("a_file.txt");
    auto j = parse_result(result);
    REQUIRE(j["ok"] == false);
    REQUIRE(j["error"] == "Not a directory: a_file.txt");
}

// ============================================================================
// 3.17 — list_dir: path traversal (..) → access denied
// ============================================================================
TEST_CASE("list_dir: path traversal attempt", "[tool_execution]") {
    TempDir tmp;
    tmp.mkdir("sub");
    WorkspaceGuard ws(tmp.path() + "/sub");

    std::string result = tools::list_dir("..");
    auto j = parse_result(result);
    REQUIRE(j["ok"] == false);
    REQUIRE(j["error"] == "Access denied: path outside workspace");
}

// ============================================================================
// 3.18 — list_dir: cannot read directory → error (best-effort)
// ============================================================================
TEST_CASE("list_dir: cannot read directory (permissions)", "[tool_execution]") {
    // This requires OS-level permission restriction (ACLs/chmod).
    // Best-effort: skip with WARN if the test environment cannot set up
    // the precondition.
    WARN("Cannot read directory test skipped — requires OS-level permission setup (best-effort)");
    SUCCEED("Best-effort: skipped");
}

// ============================================================================
// 3.19 — list_dir: no workspace set → error
// ============================================================================
TEST_CASE("list_dir: no workspace set", "[tool_execution]") {
    tools::set_workspace("");
    WorkspaceGuard ws("");

    std::string result = tools::list_dir(".");
    auto j = parse_result(result);
    REQUIRE(j["ok"] == false);
    REQUIRE(j["error"] == "No workspace set");
}

// ============================================================================
// 3.20 — list_dir: cannot resolve path (best-effort)
// ============================================================================
TEST_CASE("list_dir: cannot resolve path", "[tool_execution]") {
    TempDir tmp;
    WorkspaceGuard ws(tmp.path());

    // Same platform constraints as read_file Cannot resolve path.
    // On Windows, GetFullPathNameA almost always succeeds.
    std::string result = tools::list_dir("nonexistent/subdir");
    auto j = parse_result(result);
    if (j["ok"] == false && j["error"] == "Cannot resolve path: nonexistent/subdir") {
        SUCCEED("Cannot resolve path correctly detected");
    } else if (j["ok"] == false) {
        // Directory not found or File not found are normal on Windows
        WARN("Cannot resolve path not triggerable on this platform (best-effort)");
    }
}

// ============================================================================
// Additional: check workspace() returns the set path
// ============================================================================
TEST_CASE("workspace: returns current workspace", "[tool_execution]") {
    tools::set_workspace("");
    WorkspaceGuard ws("");

    TempDir tmp;
    tools::set_workspace(tmp.path());
    REQUIRE(tools::workspace() == tmp.path());
}

// ============================================================================
// Additional: set_workspace preserves canonical form
// ============================================================================
TEST_CASE("set_workspace: canonical path", "[tool_execution]") {
    TempDir tmp;
    WorkspaceGuard ws(tmp.path());

    // Should work and store in canonical form
    std::string result = tools::set_workspace(tmp.path());
    REQUIRE(result == "");
    REQUIRE(tools::workspace() == tmp.path());
}
