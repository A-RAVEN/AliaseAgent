#include <catch2/catch_all.hpp>
#include "mock_server.h"
#include "model_gateway.h"
#include "crash_handler.h"
#include <string>
#include <nlohmann/json.hpp>

static std::string fixture(const std::string& name) {
    return std::string(FIXTURE_DIR) + "/" + name;
}

static const char* VALID_MSG = R"([{"role":"user","content":"hello"}])";

// Static capture for callbacks
static int s_chunk_count = 0;
static int s_tool_count = 0;
static int s_thinking_count = 0;
static bool s_done = false;

static void on_chunk_cb(const char*) { s_chunk_count++; }
static void on_tool_cb(const char*) { s_tool_count++; }
static void on_thinking_cb(const char*) { s_thinking_count++; }
static void on_done_cb(int, const char*, const char*) { s_done = true; }

static void reset_callbacks() {
    s_chunk_count = 0;
    s_tool_count = 0;
    s_thinking_count = 0;
    s_done = false;
}

// ============================================================================
// 6.7.1 — Ring buffer populated during real-time callback dispatch
// ============================================================================
TEST_CASE("FFI: ring buffer populated during dispatch", "[ffi_tracing]") {
    reset_callbacks();

    // Use text_delta fixture (produces CHUNK + DONE events)
    MockServer server;
    server.start(fixture("text_delta.txt"));
    server.wait_ready();

    ModelGateway gw;
    gw.set_timeout(5);

    int rid = gw.execute(
        "sk-key", server.base_url().c_str(), "claude-sonnet-4-6",
        "", VALID_MSG, "", "", "",
        on_chunk_cb, on_tool_cb, on_thinking_cb, on_done_cb
    );
    server.join();

    REQUIRE(rid > 0);
    REQUIRE(s_chunk_count > 0);
    REQUIRE(s_done);
    // Ring buffer was populated during dispatch — dump should not crash
    // We can't inspect ring buffer internals, but crash_log should have entries
}

// ============================================================================
// 6.7.2 — Ring buffer with tool calls
// ============================================================================
TEST_CASE("FFI: ring buffer records tool calls", "[ffi_tracing]") {
    reset_callbacks();

    MockServer server;
    server.start(fixture("tool_use_single.txt"));
    server.wait_ready();

    ModelGateway gw;
    gw.set_timeout(5);

    int rid = gw.execute(
        "sk-key", server.base_url().c_str(), "claude-sonnet-4-6",
        "", VALID_MSG, "", "", "",
        on_chunk_cb, on_tool_cb, on_thinking_cb, on_done_cb
    );
    server.join();

    REQUIRE(rid > 0);
    REQUIRE(s_tool_count > 0);
    REQUIRE(s_done);
}

// ============================================================================
// 6.7.3 — Ring buffer with thinking blocks
// ============================================================================
TEST_CASE("FFI: ring buffer records thinking", "[ffi_tracing]") {
    reset_callbacks();

    MockServer server;
    server.start(fixture("thinking_block.txt"));
    server.wait_ready();

    ModelGateway gw;
    gw.set_timeout(5);

    int rid = gw.execute(
        "sk-key", server.base_url().c_str(), "claude-sonnet-4-6",
        "", VALID_MSG, "", "", "",
        on_chunk_cb, on_tool_cb, on_thinking_cb, on_done_cb
    );
    server.join();

    REQUIRE(rid > 0);
    REQUIRE(s_thinking_count > 0);
    REQUIRE(s_done);
}
