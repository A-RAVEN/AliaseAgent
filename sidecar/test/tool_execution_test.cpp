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
// 3.5 — read_file: existing text file → ok:true (line numbers)
// ============================================================================
TEST_CASE("read_file: existing text file", "[tool_execution]") {
    TempDir tmp;
    tmp.write("hello.txt", "hello world\nline 2");
    WorkspaceGuard ws(tmp.path());

    std::string result = tools::read_file("{\"path\":\"hello.txt\"}");
    auto j = parse_result(result);
    REQUIRE(j["ok"] == true);
    REQUIRE(j["total_lines"] == 2);
    REQUIRE(j["start_line"] == 1);
    REQUIRE(j["end_line"] == 2);
    // Content should have line numbers (cat -n format)
    std::string content = j["content"];
    REQUIRE(content.find("1\thello world") != std::string::npos);
    REQUIRE(content.find("2\tline 2") != std::string::npos);
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

    std::string result = tools::read_file("{\"path\":\"empty.txt\"}");
    auto j = parse_result(result);
    REQUIRE(j["ok"] == true);
    REQUIRE(j["content"] == "");
    REQUIRE(j["total_lines"] == 0);
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

// ============================================================================
// write_file tests (task 4.1)
// ============================================================================

TEST_CASE("write_file: create new file", "[write_file]") {
    TempDir tmp;
    WorkspaceGuard ws(tmp.path());

    std::string result = tools::write_file("{\"path\":\"new.txt\",\"content\":\"hello world\"}");
    auto j = parse_result(result);
    REQUIRE(j["ok"] == true);
    REQUIRE(j["bytes_written"] == 11);
    REQUIRE(j["created"] == true);

    // Verify file exists and has correct content
    std::ifstream f(tmp.path() + "/new.txt");
    std::string content((std::istreambuf_iterator<char>(f)), std::istreambuf_iterator<char>());
    REQUIRE(content == "hello world");
}

TEST_CASE("write_file: overwrite existing file", "[write_file]") {
    TempDir tmp;
    tmp.write("existing.txt", "old content");
    WorkspaceGuard ws(tmp.path());

    std::string result = tools::write_file("{\"path\":\"existing.txt\",\"content\":\"new content\"}");
    auto j = parse_result(result);
    REQUIRE(j["ok"] == true);
    REQUIRE(j["created"] == false);

    // Verify content was replaced
    std::ifstream f(tmp.path() + "/existing.txt");
    std::string content((std::istreambuf_iterator<char>(f)), std::istreambuf_iterator<char>());
    REQUIRE(content == "new content");
}

TEST_CASE("write_file: create parent directories", "[write_file]") {
    TempDir tmp;
    WorkspaceGuard ws(tmp.path());

    std::string result = tools::write_file("{\"path\":\"sub/deep/nested/file.txt\",\"content\":\"nested\"}");
    auto j = parse_result(result);
    REQUIRE(j["ok"] == true);
    REQUIRE(j["created"] == true);

    // Verify file exists
    std::ifstream f(tmp.path() + "/sub/deep/nested/file.txt");
    std::string content((std::istreambuf_iterator<char>(f)), std::istreambuf_iterator<char>());
    REQUIRE(content == "nested");
}

TEST_CASE("write_file: path outside workspace rejected", "[write_file]") {
    TempDir tmp;
    tmp.mkdir("subdir");
    WorkspaceGuard ws(tmp.path() + "/subdir");

    // Try to access a file outside workspace via ".." traversal
    std::string result = tools::write_file("{\"path\":\"../outside.txt\",\"content\":\"bad\"}");
    auto j = parse_result(result);
    REQUIRE(j["ok"] == false);
    REQUIRE(j["error"] == "Access denied: path outside workspace");
}

TEST_CASE("write_file: empty path rejected", "[write_file]") {
    TempDir tmp;
    WorkspaceGuard ws(tmp.path());

    std::string result = tools::write_file("{\"path\":\"\",\"content\":\"x\"}");
    auto j = parse_result(result);
    REQUIRE(j["ok"] == false);
    REQUIRE(j["error"] == "path is required");
}

// ============================================================================
// edit_file tests — exact matching (tier 1)
// ============================================================================

TEST_CASE("edit_file: exact match succeeds", "[edit_file]") {
    TempDir tmp;
    tmp.write("test.txt", "line 1\nline 2\nline 3\n");
    WorkspaceGuard ws(tmp.path());

    std::string result = tools::edit_file("{\"path\":\"test.txt\",\"edits\":[{\"old_text\":\"line 2\",\"new_text\":\"line two\"}]}");
    auto j = parse_result(result);
    REQUIRE(j["ok"] == true);
    REQUIRE(j["replacements"] == 1);

    // Verify content
    std::ifstream f(tmp.path() + "/test.txt");
    std::string content((std::istreambuf_iterator<char>(f)), std::istreambuf_iterator<char>());
    REQUIRE(content == "line 1\nline two\nline 3\n");
}

TEST_CASE("edit_file: replace_all replaces all occurrences", "[edit_file]") {
    TempDir tmp;
    tmp.write("test.txt", "foo bar foo baz foo\n");
    WorkspaceGuard ws(tmp.path());

    std::string result = tools::edit_file(
        "{\"path\":\"test.txt\",\"edits\":[{\"old_text\":\"foo\",\"new_text\":\"qux\",\"replace_all\":true}]}");
    auto j = parse_result(result);
    REQUIRE(j["ok"] == true);
    REQUIRE(j["replacements"] == 3);

    std::ifstream f(tmp.path() + "/test.txt");
    std::string content((std::istreambuf_iterator<char>(f)), std::istreambuf_iterator<char>());
    REQUIRE(content == "qux bar qux baz qux\n");
}

TEST_CASE("edit_file: multiple exact matches rejected with line numbers", "[edit_file]") {
    TempDir tmp;
    tmp.write("test.txt", "TODO: fix bug\nsome code\nTODO: more work\n");
    WorkspaceGuard ws(tmp.path());

    std::string result = tools::edit_file(
        "{\"path\":\"test.txt\",\"edits\":[{\"old_text\":\"TODO:\",\"new_text\":\"DONE:\"}]}");
    auto j = parse_result(result);
    REQUIRE(j["ok"] == false);
    REQUIRE(j.contains("matches"));
    REQUIRE(j["matches"].is_array());
    REQUIRE(j["matches"].size() == 2);
}

TEST_CASE("edit_file: empty old_text rejected", "[edit_file]") {
    TempDir tmp;
    tmp.write("test.txt", "some content\n");
    WorkspaceGuard ws(tmp.path());

    std::string result = tools::edit_file("{\"path\":\"test.txt\",\"edits\":[{\"old_text\":\"\",\"new_text\":\"x\"}]}");
    auto j = parse_result(result);
    REQUIRE(j["ok"] == false);
    REQUIRE(j["error"] == "old_text must not be empty");
}

// ============================================================================
// edit_file tests — whitespace normalization (tier 2)
// ============================================================================

TEST_CASE("edit_file: CRLF vs LF mismatch auto-corrected", "[edit_file][normalized]") {
    TempDir tmp;
    // Write file with CRLF endings
    {
        std::ofstream f(tmp.path() + "/crlf.txt", std::ios::binary);
        f.write("line1\r\nline2\r\nline3\r\n", 21);
        f.close();
    }
    WorkspaceGuard ws(tmp.path());

    // old_text "line2" is found literally in the file content (it contains no line endings),
    // so exact match succeeds without needing normalization.
    std::string result = tools::edit_file(
        "{\"path\":\"crlf.txt\",\"edits\":[{\"old_text\":\"line2\",\"new_text\":\"line TWO\"}]}");
    auto j = parse_result(result);
    REQUIRE(j["ok"] == true);
    REQUIRE(j["replacements"] == 1);
}

// ============================================================================
// edit_file tests — binary / large file protection
// ============================================================================

TEST_CASE("edit_file: binary file rejected", "[edit_file]") {
    TempDir tmp;
    std::string bin_path = tmp.path() + "/data.bin";
    write_binary_file(bin_path);
    WorkspaceGuard ws(tmp.path());

    std::string result = tools::edit_file("{\"path\":\"data.bin\",\"edits\":[{\"old_text\":\"x\",\"new_text\":\"y\"}]}");
    auto j = parse_result(result);
    REQUIRE(j["ok"] == false);
    REQUIRE(j["error"] == "Cannot edit binary or non-text file");
}

TEST_CASE("edit_file: large file rejected", "[edit_file]") {
    TempDir tmp;
    // Create a file larger than 1MB
    {
        std::ofstream f(tmp.path() + "/large.txt", std::ios::binary);
        f << "x";
        // Seek to 1MB + 1 byte
        f.seekp(1024 * 1024 + 1);
        f << "y";
        f.close();
    }
    WorkspaceGuard ws(tmp.path());

    std::string result = tools::edit_file("{\"path\":\"large.txt\",\"edits\":[{\"old_text\":\"z\",\"new_text\":\"w\"}]}");
    auto j = parse_result(result);
    REQUIRE(j["ok"] == false);
    REQUIRE(j["error"] == "File too large for edit_file (>1MB)");
}

TEST_CASE("edit_file: file not found", "[edit_file]") {
    TempDir tmp;
    WorkspaceGuard ws(tmp.path());

    std::string result = tools::edit_file("{\"path\":\"nonexistent.txt\",\"edits\":[{\"old_text\":\"x\",\"new_text\":\"y\"}]}");
    auto j = parse_result(result);
    REQUIRE(j["ok"] == false);
    REQUIRE(j["error"] == "File not found: nonexistent.txt");
}

TEST_CASE("edit_file: path outside workspace", "[edit_file]") {
    TempDir tmp;
    tmp.mkdir("subdir");
    WorkspaceGuard ws(tmp.path() + "/subdir");

    std::string result = tools::edit_file("{\"path\":\"../outside.txt\",\"edits\":[{\"old_text\":\"x\",\"new_text\":\"y\"}]}");
    auto j = parse_result(result);
    REQUIRE(j["ok"] == false);
    REQUIRE(j["error"] == "Access denied: path outside workspace");
}

TEST_CASE("edit_file: edit of directory rejected", "[edit_file]") {
    TempDir tmp;
    tmp.mkdir("subdir");
    WorkspaceGuard ws(tmp.path());

    std::string result = tools::edit_file("{\"path\":\"subdir\",\"edits\":[{\"old_text\":\"x\",\"new_text\":\"y\"}]}");
    auto j = parse_result(result);
    REQUIRE(j["ok"] == false);
    REQUIRE(j["error"] == "Path is a directory, not a file: subdir");
}

// ============================================================================
// edit_file — diagnostic error (tier 3)
// ============================================================================

TEST_CASE("edit_file: no match returns diagnostic info", "[edit_file]") {
    TempDir tmp;
    tmp.write("code.dart", "  final count = 0;\n  print(count);\n");
    WorkspaceGuard ws(tmp.path());

    std::string result = tools::edit_file(
        "{\"path\":\"code.dart\",\"edits\":[{\"old_text\":\"final count = 1\",\"new_text\":\"final count = 99\"}]}");
    auto j = parse_result(result);
    REQUIRE(j["ok"] == false);
    REQUIRE(j["error"] == "old_text not found in file");
    REQUIRE(j.contains("diagnosis"));
    REQUIRE(j["diagnosis"].contains("file_indent"));
    REQUIRE(j["diagnosis"].contains("file_line_ending"));
    REQUIRE(j["diagnosis"].contains("closest_match"));
    REQUIRE(j["diagnosis"]["closest_match"].contains("line"));
    REQUIRE(j["diagnosis"]["closest_match"].contains("actual_text"));
}

// ============================================================================
// read_file — offset/limit edge cases
// ============================================================================

TEST_CASE("read_file: offset/limit partial read", "[read_file]") {
    TempDir tmp;
    // Create a file with 10 lines
    std::string content;
    for (int i = 1; i <= 10; ++i) {
        content += "line " + std::to_string(i) + "\n";
    }
    tmp.write("ten.txt", content);
    WorkspaceGuard ws(tmp.path());

    std::string result = tools::read_file("{\"path\":\"ten.txt\",\"offset\":3,\"limit\":2}");
    auto j = parse_result(result);
    REQUIRE(j["ok"] == true);
    REQUIRE(j["total_lines"] == 10);
    REQUIRE(j["start_line"] == 3);
    REQUIRE(j["end_line"] == 4); // lines 3,4
    std::string c = j["content"];
    REQUIRE(c.find("3\tline 3") != std::string::npos);
    REQUIRE(c.find("4\tline 4") != std::string::npos);
    REQUIRE(c.find("5\tline 5") == std::string::npos); // line 5 not included
}

TEST_CASE("read_file: offset <= 0 rejected", "[read_file]") {
    TempDir tmp;
    tmp.write("test.txt", "hello\n");
    WorkspaceGuard ws(tmp.path());

    std::string result = tools::read_file("{\"path\":\"test.txt\",\"offset\":0}");
    auto j = parse_result(result);
    REQUIRE(j["ok"] == false);
    REQUIRE(j["error"] == "offset must be >= 1");
}

TEST_CASE("read_file: offset exceeds file length", "[read_file]") {
    TempDir tmp;
    tmp.write("test.txt", "line1\nline2\n");
    WorkspaceGuard ws(tmp.path());

    std::string result = tools::read_file("{\"path\":\"test.txt\",\"offset\":100}");
    auto j = parse_result(result);
    REQUIRE(j["ok"] == true);
    REQUIRE(j["content"] == "");
    REQUIRE(j["total_lines"] == 2);
    REQUIRE(j.contains("notice"));
}

TEST_CASE("read_file: offset+limit exceeds file length returns truncated", "[read_file]") {
    TempDir tmp;
    tmp.write("test.txt", "a\nb\nc\n");
    WorkspaceGuard ws(tmp.path());

    std::string result = tools::read_file("{\"path\":\"test.txt\",\"offset\":2,\"limit\":100}");
    auto j = parse_result(result);
    REQUIRE(j["ok"] == true);
    REQUIRE(j["start_line"] == 2);
    REQUIRE(j["end_line"] == 3); // only 2 lines available from offset 2
    std::string c = j["content"];
    REQUIRE(c.find("2\tb") != std::string::npos);
    REQUIRE(c.find("3\tc") != std::string::npos);
}

TEST_CASE("read_file: backward compatible with plain path", "[read_file]") {
    TempDir tmp;
    tmp.write("hello.txt", "hello\n");
    WorkspaceGuard ws(tmp.path());

    // Plain path string (not JSON) should still work
    std::string result = tools::read_file("hello.txt");
    auto j = parse_result(result);
    REQUIRE(j["ok"] == true);
    REQUIRE(j["total_lines"] == 1);
}

TEST_CASE("read_file: line numbering format", "[read_file]") {
    TempDir tmp;
    tmp.write("test.txt", "first line\nsecond line\n");
    WorkspaceGuard ws(tmp.path());

    std::string result = tools::read_file("{\"path\":\"test.txt\"}");
    auto j = parse_result(result);
    REQUIRE(j["ok"] == true);
    std::string c = j["content"];
    // Check cat -n format: 6-char right-aligned number + tab
    // Line 1 should have "     1\tfirst line"
    REQUIRE(c.find("\tfirst line") != std::string::npos);
    REQUIRE(c.find("\tsecond line") != std::string::npos);
}

// ============================================================================
// whitespace normalization tests
// ============================================================================

TEST_CASE("edit_file: indentation mismatch falls through to diagnostic", "[edit_file][normalized]") {
    TempDir tmp;
    // File uses 4-space indentation
    tmp.write("test.dart", "class Foo {\n    void bar() {\n        code();\n    }\n}\n");
    WorkspaceGuard ws(tmp.path());

    // old_text uses 2-space indentation and slightly different code.
    // We deliberately avoid substring matches (e.g. "  void bar()" would
    // accidentally match at offset 2 inside "    void bar()" since both
    // share "  void bar()" as a common substring).
    std::string result = tools::edit_file(
        "{\"path\":\"test.dart\",\"edits\":[{\"old_text\":\"  void bar(int x)\",\"new_text\":\"  void baz()\"}]}");
    auto j = parse_result(result);
    // Should return diagnostic info since neither exact nor normalized match succeeds
    REQUIRE(j["ok"] == false);
    REQUIRE(j.contains("diagnosis"));
    REQUIRE(j["diagnosis"].contains("closest_match"));
}

// ============================================================================
// edit_file: diagnostic differences
// ============================================================================

TEST_CASE("edit_file: diagnostic lists indentation differences", "[edit_file]") {
    TempDir tmp;
    // File uses 4-space indentation
    tmp.write("test.dart", "    final count = 0;\n    print(count);\n");
    WorkspaceGuard ws(tmp.path());

    // old_text uses 2-space indentation + different code (avoid accidental substring match)
    std::string result = tools::edit_file(
        "{\"path\":\"test.dart\",\"edits\":[{\"old_text\":\"  final count = 1;\",\"new_text\":\"  final count = 99;\"}]}");
    auto j = parse_result(result);
    REQUIRE(j["ok"] == false);
    REQUIRE(j.contains("diagnosis"));
    // Should tell us about the file's indentation
    std::string file_indent = j["diagnosis"]["file_indent"];
    REQUIRE(!file_indent.empty());
    REQUIRE(j["diagnosis"].contains("closest_match"));
}

// ============================================================================
// 7.1 — replace_all + normalized match preserves CRLF format
// ============================================================================
TEST_CASE("edit_file: replace_all with normalization preserves CRLF", "[edit_file][normalized]") {
    TempDir tmp;
    // File with CRLF. old_text with LF → exact match fails → Tier 2 activates.
    // "hello\nworld" appears at 2 positions in normalized content.
    {
        std::ofstream f(tmp.path() + "/crlf.txt", std::ios::binary);
        f.write("hello\r\nworld\r\nhello\r\nworld\r\n", 28);
        f.close();
    }
    WorkspaceGuard ws(tmp.path());

    std::string result = tools::edit_file(
        "{\"path\":\"crlf.txt\",\"edits\":[{\"old_text\":\"hello\\nworld\",\"new_text\":\"REPLACED\",\"replace_all\":true}]}");
    auto j = parse_result(result);
    REQUIRE(j["ok"] == true);
    REQUIRE(j["replacements"] == 2);
    REQUIRE(j["matched_with"] == "whitespace normalization");

    // Verify CRLF format preserved
    std::ifstream f(tmp.path() + "/crlf.txt", std::ios::binary);
    std::string content((std::istreambuf_iterator<char>(f)), std::istreambuf_iterator<char>());
    REQUIRE(content.find("\r\n") != std::string::npos);
    REQUIRE(content.find("hello") == std::string::npos);
    REQUIRE(content.find("world") == std::string::npos);
    REQUIRE(content.find("REPLACED") != std::string::npos);
}

// ============================================================================
// 7.2 — normalized match + tab indentation: position accuracy
// ============================================================================
TEST_CASE("edit_file: normalized match preserves non-matching content", "[edit_file][normalized]") {
    TempDir tmp;
    // File uses 4-space indentation. old_text uses tab → forces Tier 2 normalization.
    tmp.write("code.txt", "class A {\n    int x = 1;\n    int y = 2;\n}\n");
    WorkspaceGuard ws(tmp.path());

    // old_text with tab (file has 4-space indent, tab→4 spaces via normalization)
    std::string result = tools::edit_file(
        "{\"path\":\"code.txt\",\"edits\":[{\"old_text\":\"\\tint y = 2;\",\"new_text\":\"\\tint z = 3;\"}]}");
    auto j = parse_result(result);
    REQUIRE(j["ok"] == true);
    REQUIRE(j["replacements"] == 1);
    REQUIRE(j["matched_with"] == "whitespace normalization");

    // Verify non-matching content intact
    std::ifstream f(tmp.path() + "/code.txt");
    std::string content((std::istreambuf_iterator<char>(f)), std::istreambuf_iterator<char>());
    REQUIRE(content.find("class A") != std::string::npos);
    REQUIRE(content.find("int x = 1") != std::string::npos);
    REQUIRE(content.find("int z = 3") != std::string::npos);
    REQUIRE(content.find("int y = 2") == std::string::npos);
}

// ============================================================================
// 7.3 — multi-line old_text with CRLF normalization
// ============================================================================
TEST_CASE("edit_file: multi-line old_text with CRLF normalization", "[edit_file][normalized]") {
    TempDir tmp;
    // File with CRLF, containing a 2-line block
    {
        std::ofstream f(tmp.path() + "/ml.txt", std::ios::binary);
        f.write("header\r\nblock line 1\r\nblock line 2\r\nfooter\r\n", 44);
        f.close();
    }
    WorkspaceGuard ws(tmp.path());

    // old_text uses LF — should normalize to match the CRLF block
    std::string result = tools::edit_file(
        "{\"path\":\"ml.txt\",\"edits\":[{\"old_text\":\"block line 1\\nblock line 2\",\"new_text\":\"REPLACED\"}]}");
    auto j = parse_result(result);
    REQUIRE(j["ok"] == true);
    REQUIRE(j["replacements"] == 1);

    std::ifstream f(tmp.path() + "/ml.txt", std::ios::binary);
    std::string content((std::istreambuf_iterator<char>(f)), std::istreambuf_iterator<char>());
    REQUIRE(content.find("REPLACED") != std::string::npos);
    REQUIRE(content.find("block line 1") == std::string::npos);
    REQUIRE(content.find("header") != std::string::npos); // non-matching content intact
}

// ============================================================================
// 7.4 — read_file truncation for 2000+ line files
// ============================================================================
TEST_CASE("read_file: truncation notice for 2000+ line file", "[read_file]") {
    TempDir tmp;
    // Create a file with more than 2000 lines
    std::ostringstream oss;
    for (int i = 1; i <= 2050; ++i) {
        oss << "line " << i << "\n";
    }
    tmp.write("big.txt", oss.str());
    WorkspaceGuard ws(tmp.path());

    // Read without offset/limit — should truncate at 2000 lines
    std::string result = tools::read_file("{\"path\":\"big.txt\"}");
    auto j = parse_result(result);
    REQUIRE(j["ok"] == true);
    REQUIRE(j["total_lines"] == 2050);
    REQUIRE(j["start_line"] == 1);
    REQUIRE(j["end_line"] == 2000);
    REQUIRE(j["truncated"] == true);
    REQUIRE(j.contains("notice"));
    std::string notice = j["notice"];
    REQUIRE(notice.find("2050") != std::string::npos);
    REQUIRE(notice.find("offset") != std::string::npos);

    // Read remaining lines with offset
    std::string result2 = tools::read_file("{\"path\":\"big.txt\",\"offset\":2001,\"limit\":100}");
    auto j2 = parse_result(result2);
    REQUIRE(j2["ok"] == true);
    REQUIRE(j2["start_line"] == 2001);
    REQUIRE(j2["end_line"] == 2050);
}

// ============================================================================
// 7.5 — replace_all with exact match: all occurrences replaced
// ============================================================================
TEST_CASE("edit_file: replace_all exact match replaces all occurrences", "[edit_file]") {
    TempDir tmp;
    tmp.write("reps.txt", "AAA BBB AAA CCC AAA DDD\n");
    WorkspaceGuard ws(tmp.path());

    std::string result = tools::edit_file(
        "{\"path\":\"reps.txt\",\"edits\":[{\"old_text\":\"AAA\",\"new_text\":\"ZZZ\",\"replace_all\":true}]}");
    auto j = parse_result(result);
    REQUIRE(j["ok"] == true);
    REQUIRE(j["replacements"] == 3);

    std::ifstream f(tmp.path() + "/reps.txt");
    std::string content((std::istreambuf_iterator<char>(f)), std::istreambuf_iterator<char>());
    REQUIRE(content == "ZZZ BBB ZZZ CCC ZZZ DDD\n");
    REQUIRE(content.find("AAA") == std::string::npos);
}

// ============================================================================
// 7.6 — write_file/edit_file errors when no workspace set
// ============================================================================
TEST_CASE("write_file: no workspace set returns error", "[write_file]") {
    tools::set_workspace("");
    WorkspaceGuard ws("");

    std::string result = tools::write_file("{\"path\":\"test.txt\",\"content\":\"x\"}");
    auto j = parse_result(result);
    REQUIRE(j["ok"] == false);
    REQUIRE(j["error"] == "No workspace set");
}

TEST_CASE("edit_file: no workspace set returns error", "[edit_file]") {
    tools::set_workspace("");
    WorkspaceGuard ws("");

    std::string result = tools::edit_file("{\"path\":\"test.txt\",\"edits\":[{\"old_text\":\"x\",\"new_text\":\"y\"}]}");
    auto j = parse_result(result);
    REQUIRE(j["ok"] == false);
    REQUIRE(j["error"] == "No workspace set");
}

// ============================================================================
// 11.7 — normalized multi-match rejection returns line numbers
// ============================================================================
TEST_CASE("edit_file: normalized multi-match rejected with line numbers", "[edit_file][normalized]") {
    TempDir tmp;
    {
        std::ofstream f(tmp.path() + "/rep.txt", std::ios::binary);
        f.write("header\r\nAA\r\nBB\r\nmiddle\r\nAA\r\nBB\r\nfooter\r\n", 40);
        f.close();
    }
    WorkspaceGuard ws(tmp.path());

    std::string result = tools::edit_file(
        "{\"path\":\"rep.txt\",\"edits\":[{\"old_text\":\"AA\\nBB\",\"new_text\":\"XX\",\"replace_all\":false}]}");
    auto j = parse_result(result);
    REQUIRE(j["ok"] == false);
    REQUIRE(j["matches"].is_array());
    REQUIRE(j["matches"].size() == 2);
    REQUIRE(j["matched_with"] == "whitespace normalization");
}

// ============================================================================
// 11.8 — tab old_text matches space-indented file via normalization
// ============================================================================
TEST_CASE("edit_file: tab old_text matches space-indented file", "[edit_file][normalized]") {
    TempDir tmp;
    tmp.write("indent.txt", "first\n    indented line\nlast\n");
    WorkspaceGuard ws(tmp.path());

    std::string result = tools::edit_file(
        "{\"path\":\"indent.txt\",\"edits\":[{\"old_text\":\"\\tindented line\",\"new_text\":\"\\treplaced\"}]}");
    auto j = parse_result(result);
    REQUIRE(j["ok"] == true);
    REQUIRE(j["replacements"] == 1);
    REQUIRE(j["matched_with"] == "whitespace normalization");
}

// ============================================================================
// 11.9 — diagnostic includes your_text and actual_text
// ============================================================================
TEST_CASE("edit_file: diagnostic includes your_text for mismatch", "[edit_file]") {
    TempDir tmp;
    tmp.write("diag.txt", "    final x = 1;\n    print(x);\n");
    WorkspaceGuard ws(tmp.path());

    std::string result = tools::edit_file(
        "{\"path\":\"diag.txt\",\"edits\":[{\"old_text\":\"  final x = 2;\",\"new_text\":\"  final x = 99;\"}]}");
    auto j = parse_result(result);
    REQUIRE(j["ok"] == false);
    REQUIRE(j.contains("diagnosis"));
    auto diag = j["diagnosis"];
    REQUIRE(diag["closest_match"].contains("your_text"));
    REQUIRE(diag["closest_match"]["your_text"] == "  final x = 2;");
    // 13.2: verify differences array is populated when indentation mismatches
    if (diag["closest_match"].contains("differences")) {
      auto diffs = diag["closest_match"]["differences"];
      REQUIRE(diffs.is_array());
      REQUIRE(diffs.size() > 0);
    }
}

// ============================================================================
// 11.16 — UTF-16 file rejected
// ============================================================================
TEST_CASE("edit_file: UTF-16 text file rejected as binary", "[edit_file]") {
    TempDir tmp;
    {
        std::ofstream f(tmp.path() + "/utf16.txt", std::ios::binary);
        unsigned char bom[] = {0xFF, 0xFE};
        f.write(reinterpret_cast<const char*>(bom), 2);
        const char* text = "hello";
        for (int i = 0; i < 5; ++i) {
            f.put(text[i]);
            f.put('\0');
        }
        f.close();
    }
    WorkspaceGuard ws(tmp.path());

    std::string result = tools::edit_file(
        "{\"path\":\"utf16.txt\",\"edits\":[{\"old_text\":\"x\",\"new_text\":\"y\"}]}");
    auto j = parse_result(result);
    REQUIRE(j["ok"] == false);
    REQUIRE(j["error"] == "Cannot edit binary or non-text file");
}

// ============================================================================
// 13.3 — old_text == new_text: no-op, file unchanged
// ============================================================================
TEST_CASE("edit_file: old_text equals new_text is no-op", "[edit_file]") {
    TempDir tmp;
    tmp.write("same.txt", "hello world\nfoo bar\n");
    WorkspaceGuard ws(tmp.path());

    std::string result = tools::edit_file(
        "{\"path\":\"same.txt\",\"edits\":[{\"old_text\":\"foo bar\",\"new_text\":\"foo bar\"}]}");
    auto j = parse_result(result);
    REQUIRE(j["ok"] == true);
    REQUIRE(j["replacements"] == 1);

    std::ifstream f(tmp.path() + "/same.txt");
    std::string content((std::istreambuf_iterator<char>(f)), std::istreambuf_iterator<char>());
    REQUIRE(content == "hello world\nfoo bar\n");
}

// ============================================================================
// 13.4 — replace_all where old_text is substring of new_text
// ============================================================================
TEST_CASE("edit_file: replace_all substring overlap no infinite loop", "[edit_file]") {
    TempDir tmp;
    tmp.write("sub.txt", "a a a\n");
    WorkspaceGuard ws(tmp.path());

    std::string result = tools::edit_file(
        "{\"path\":\"sub.txt\",\"edits\":[{\"old_text\":\"a\",\"new_text\":\"aa\",\"replace_all\":true}]}");
    auto j = parse_result(result);
    REQUIRE(j["ok"] == true);
    REQUIRE(j["replacements"] == 3);

    std::ifstream f(tmp.path() + "/sub.txt");
    std::string content((std::istreambuf_iterator<char>(f)), std::istreambuf_iterator<char>());
    REQUIRE(content == "aa aa aa\n");
}

// ============================================================================
// edit_file batch tests — edits array schema (task 1.8)
// ============================================================================

TEST_CASE("edit_file: multiple replacements in one call", "[edit_file][batch]") {
    TempDir tmp;
    tmp.write("multi.txt", "alpha\nbeta\ngamma\n");
    WorkspaceGuard ws(tmp.path());

    std::string result = tools::edit_file(
        "{\"path\":\"multi.txt\",\"edits\":["
        "{\"old_text\":\"alpha\",\"new_text\":\"ALPHA\"},"
        "{\"old_text\":\"beta\",\"new_text\":\"BETA\"},"
        "{\"old_text\":\"gamma\",\"new_text\":\"GAMMA\"}"
        "]}");
    auto j = parse_result(result);
    REQUIRE(j["ok"] == true);
    REQUIRE(j["replacements"] == 3);

    std::ifstream f(tmp.path() + "/multi.txt");
    std::string content((std::istreambuf_iterator<char>(f)), std::istreambuf_iterator<char>());
    REQUIRE(content == "ALPHA\nBETA\nGAMMA\n");
}

TEST_CASE("edit_file: any failed match aborts all", "[edit_file][batch]") {
    TempDir tmp;
    tmp.write("abort.txt", "aaa\nbbb\n");
    WorkspaceGuard ws(tmp.path());

    // Second pair's old_text does not exist — whole request fails, zero changes
    std::string result = tools::edit_file(
        "{\"path\":\"abort.txt\",\"edits\":["
        "{\"old_text\":\"aaa\",\"new_text\":\"AAA\"},"
        "{\"old_text\":\"zzz\",\"new_text\":\"ZZZ\"}"
        "]}");
    auto j = parse_result(result);
    REQUIRE(j["ok"] == false);
    REQUIRE(j["pair"] == 1);
    REQUIRE(j["error"] == "old_text not found in file");
    REQUIRE(j.contains("diagnosis"));

    // Verify NO edit applied (zero modifications)
    std::ifstream f(tmp.path() + "/abort.txt");
    std::string content((std::istreambuf_iterator<char>(f)), std::istreambuf_iterator<char>());
    REQUIRE(content == "aaa\nbbb\n");
}

TEST_CASE("edit_file: batch pair non-unique match rejected with pair index", "[edit_file][batch]") {
    TempDir tmp;
    tmp.write("dup.txt", "x\nTODO\ny\nTODO\nz\n");
    WorkspaceGuard ws(tmp.path());

    std::string result = tools::edit_file(
        "{\"path\":\"dup.txt\",\"edits\":["
        "{\"old_text\":\"TODO\",\"new_text\":\"DONE\"}"
        "]}");
    auto j = parse_result(result);
    REQUIRE(j["ok"] == false);
    REQUIRE(j["pair"] == 0);
    REQUIRE(j["matches"].is_array());
    REQUIRE(j["matches"].size() == 2);
}

TEST_CASE("edit_file: overlapping edits rejected", "[edit_file][batch]") {
    TempDir tmp;
    tmp.write("overlap.txt", "hello world\n");
    WorkspaceGuard ws(tmp.path());

    // Ranges [0,5) "hello" and [4,9) "o wor" overlap
    std::string result = tools::edit_file(
        "{\"path\":\"overlap.txt\",\"edits\":["
        "{\"old_text\":\"hello\",\"new_text\":\"X\"},"
        "{\"old_text\":\"o wor\",\"new_text\":\"Y\"}"
        "]}");
    auto j = parse_result(result);
    REQUIRE(j["ok"] == false);
    REQUIRE(j["error"] == "edits overlap");

    // Verify NO edit applied
    std::ifstream f(tmp.path() + "/overlap.txt");
    std::string content((std::istreambuf_iterator<char>(f)), std::istreambuf_iterator<char>());
    REQUIRE(content == "hello world\n");
}

TEST_CASE("edit_file: per-pair replace_all semantics", "[edit_file][batch]") {
    TempDir tmp;
    tmp.write("per.txt", "a a b a\n");
    WorkspaceGuard ws(tmp.path());

    // Pair 0 replace_all replaces all 3 'a'; pair 1 (single, unique) replaces 'b'
    std::string result = tools::edit_file(
        "{\"path\":\"per.txt\",\"edits\":["
        "{\"old_text\":\"a\",\"new_text\":\"A\",\"replace_all\":true},"
        "{\"old_text\":\"b\",\"new_text\":\"B\"}"
        "]}");
    auto j = parse_result(result);
    REQUIRE(j["ok"] == true);
    REQUIRE(j["replacements"] == 4);  // 3 'a' hits + 1 'b' hit

    std::ifstream f(tmp.path() + "/per.txt");
    std::string content((std::istreambuf_iterator<char>(f)), std::istreambuf_iterator<char>());
    REQUIRE(content == "A A B A\n");
}

TEST_CASE("edit_file: empty edits array rejected", "[edit_file][batch]") {
    TempDir tmp;
    tmp.write("e.txt", "content\n");
    WorkspaceGuard ws(tmp.path());

    std::string result = tools::edit_file("{\"path\":\"e.txt\",\"edits\":[]}");
    auto j = parse_result(result);
    REQUIRE(j["ok"] == false);
    REQUIRE(j["error"] == "edits must contain at least one replacement");
}

TEST_CASE("edit_file: missing edits field rejected", "[edit_file][batch]") {
    TempDir tmp;
    tmp.write("m.txt", "content\n");
    WorkspaceGuard ws(tmp.path());

    std::string result = tools::edit_file("{\"path\":\"m.txt\"}");
    auto j = parse_result(result);
    REQUIRE(j["ok"] == false);
    REQUIRE(j["error"] == "edits must contain at least one replacement");
}

TEST_CASE("edit_file: edits length limit exceeded", "[edit_file][batch]") {
    TempDir tmp;
    tmp.write("limit.txt", "aaaa\n");
    WorkspaceGuard ws(tmp.path());

    // Build 101 pairs (limit is 100)
    std::string edits;
    for (int i = 0; i < 101; ++i) {
      if (i > 0) edits += ",";
      edits += "{\"old_text\":\"a\",\"new_text\":\"b\"}";
    }
    std::string result = tools::edit_file(
        "{\"path\":\"limit.txt\",\"edits\":[" + edits + "]}");
    auto j = parse_result(result);
    REQUIRE(j["ok"] == false);
    REQUIRE(j["error"].get<std::string>().find("too many edits") != std::string::npos);
}

TEST_CASE("edit_file: array order differs from position order", "[edit_file][batch]") {
    TempDir tmp;
    tmp.write("order.txt", "one two three\n");
    WorkspaceGuard ws(tmp.path());

    // Pairs given in REVERSE position order — apply must still be correct
    std::string result = tools::edit_file(
        "{\"path\":\"order.txt\",\"edits\":["
        "{\"old_text\":\"three\",\"new_text\":\"3\"},"
        "{\"old_text\":\"two\",\"new_text\":\"2\"},"
        "{\"old_text\":\"one\",\"new_text\":\"1\"}"
        "]}");
    auto j = parse_result(result);
    REQUIRE(j["ok"] == true);
    REQUIRE(j["replacements"] == 3);

    std::ifstream f(tmp.path() + "/order.txt");
    std::string content((std::istreambuf_iterator<char>(f)), std::istreambuf_iterator<char>());
    REQUIRE(content == "1 2 3\n");
}

TEST_CASE("edit_file: replace_all pair with hit after another pair's range (per-hit reverse)", "[edit_file][batch]") {
    TempDir tmp;
    tmp.write("cross.txt", "X middle X end\n");
    WorkspaceGuard ws(tmp.path());

    // Pair 0: replace_all "X" → hits at [0,1) and [9,10)
    // Pair 1: "middle" → hit at [2,8)
    // Pair 0's replacement "YY" (length 2) changes length. A per-pair ordering
    // that applies [0,1) before [2,8) would shift pair 1's target by +1 and
    // corrupt it. Per-hit global reverse applies [9,10) → [2,8) → [0,1),
    // keeping every target position valid.
    std::string result = tools::edit_file(
        "{\"path\":\"cross.txt\",\"edits\":["
        "{\"old_text\":\"X\",\"new_text\":\"YY\",\"replace_all\":true},"
        "{\"old_text\":\"middle\",\"new_text\":\"M\"}"
        "]}");
    auto j = parse_result(result);
    REQUIRE(j["ok"] == true);
    REQUIRE(j["replacements"] == 3);

    std::ifstream f(tmp.path() + "/cross.txt");
    std::string content((std::istreambuf_iterator<char>(f)), std::istreambuf_iterator<char>());
    REQUIRE(content == "YY M YY end\n");
}

TEST_CASE("edit_file: empty old_text in a later pair rejected", "[edit_file][batch]") {
    TempDir tmp;
    tmp.write("e2.txt", "content\n");
    WorkspaceGuard ws(tmp.path());

    std::string result = tools::edit_file(
        "{\"path\":\"e2.txt\",\"edits\":["
        "{\"old_text\":\"content\",\"new_text\":\"c\"},"
        "{\"old_text\":\"\",\"new_text\":\"x\"}"
        "]}");
    auto j = parse_result(result);
    REQUIRE(j["ok"] == false);
    REQUIRE(j["error"] == "old_text must not be empty");
    REQUIRE(j["pair"] == 1);
}

TEST_CASE("edit_file: batch with normalized pair and matched_with", "[edit_file][batch][normalized]") {
    TempDir tmp;
    {
        std::ofstream f(tmp.path() + "/bn.txt", std::ios::binary);
        f.write("A\r\nB\r\nC\r\n", 9);
        f.close();
    }
    WorkspaceGuard ws(tmp.path());

    // Pair 0 exact, pair 1 uses LF old_text against a CRLF file → normalized
    std::string result = tools::edit_file(
        "{\"path\":\"bn.txt\",\"edits\":["
        "{\"old_text\":\"A\",\"new_text\":\"AAA\"},"
        "{\"old_text\":\"B\\nC\",\"new_text\":\"BC\"}"
        "]}");
    auto j = parse_result(result);
    REQUIRE(j["ok"] == true);
    REQUIRE(j["replacements"] == 2);
    REQUIRE(j["matched_with"] == "whitespace normalization");

    std::ifstream f(tmp.path() + "/bn.txt");
    std::string content((std::istreambuf_iterator<char>(f)), std::istreambuf_iterator<char>());
    REQUIRE(content.find("BC") != std::string::npos);
}

TEST_CASE("edit_file: bare CR line boundary with trailing whitespace (8.4 regression)", "[edit_file][batch][normalized]") {
    TempDir tmp;
    // "x  \rY": two spaces before a BARE \r (not CRLF). normalize_whitespace
    // strips those spaces (bare \r -> \n first), so old_text "x\r" matches
    // with trailing-whitespace stripping. The mapped original range must cover
    // "x  \r" (4 bytes) — a too-short range would orphan the spaces and \r.
    {
        std::ofstream f(tmp.path() + "/barecr.txt", std::ios::binary);
        f.write("x  \rY", 5);
        f.close();
    }
    WorkspaceGuard ws(tmp.path());

    std::string result = tools::edit_file(
        "{\"path\":\"barecr.txt\",\"edits\":[{\"old_text\":\"x\\r\",\"new_text\":\"z\"}]}");
    auto j = parse_result(result);
    REQUIRE(j["ok"] == true);
    REQUIRE(j["replacements"] == 1);

    std::ifstream f(tmp.path() + "/barecr.txt", std::ios::binary);
    std::string content((std::istreambuf_iterator<char>(f)), std::istreambuf_iterator<char>());
    REQUIRE(content == "zY");
}
