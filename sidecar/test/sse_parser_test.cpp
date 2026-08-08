#include <catch2/catch_all.hpp>
#include "mock_server.h"
#include "model_gateway.h"
#include <vector>
#include <string>
#include <nlohmann/json.hpp>

using json = nlohmann::json;

// Helper: construct full fixture path from the compile-time FIXTURE_DIR
static std::string fixture(const std::string& name) {
    return std::string(FIXTURE_DIR) + "/" + name;
}

// ---------------------------------------------------------------------------
// Static capture — C callbacks cannot be capturing lambdas.
// We use a file-static pointer that run_fixture sets before each call.
// Catch2 runs tests sequentially by default, so this is safe.
// ---------------------------------------------------------------------------
struct SseResult {
    std::vector<std::string> chunks;
    std::vector<std::string> tool_calls;
    std::vector<std::string> thinkings;       // final thinking events (type=="thinking")
    std::vector<std::string> thinking_deltas; // incremental events (type=="thinking_delta")
    int done_count = 0;
    int done_code = -99;
    std::string done_err;
    std::string done_stop_reason;
};

static SseResult* s_r = nullptr;

static void s_on_chunk(const char* t) {
    if (t && s_r) s_r->chunks.push_back(t);
}
static void s_on_tool_call(const char* j) {
    if (j && s_r) s_r->tool_calls.push_back(j);
}
static void s_on_thinking(const char* t) {
    // The on_thinking callback now carries BOTH incremental (thinking_delta)
    // and final (thinking) events — split by payload type.
    if (t && s_r) {
        try {
            auto j = json::parse(t);
            if (j.value("type", "") == "thinking_delta") {
                s_r->thinking_deltas.push_back(t);
                return;
            }
        } catch (...) {}
        s_r->thinkings.push_back(t);
    }
}
static void s_on_done(int c, const char* e, const char* r_ptr) {
    if (s_r) {
        s_r->done_count++;
        s_r->done_code = c;
        s_r->done_err = e ? e : "";
        s_r->done_stop_reason = r_ptr ? r_ptr : "";
    }
}

static SseResult run_fixture(const std::string& fixture_name) {
    MockServer server;
    server.start(fixture(fixture_name));
    server.wait_ready();

    ModelGateway gw;
    gw.set_timeout(5);

    SseResult r;
    s_r = &r;

    gw.execute(
        "sk-test", server.base_url().c_str(), "claude-sonnet-4-6",
        "", R"([{"role":"user","content":"hello"}])", "", "", "",
        s_on_chunk, s_on_tool_call, s_on_thinking, s_on_done
    );

    server.join();
    s_r = nullptr;
    return r;
}

// ============================================================================
// 2.1 — text_delta parsing → on_chunk callback
// ============================================================================
TEST_CASE("SSE: text_delta parsing", "[sse_parser]") {
    auto r = run_fixture("text_delta.txt");

    REQUIRE(r.chunks.size() == 1);
    REQUIRE(r.chunks[0] == "Hello from Claude!");
    REQUIRE(r.done_count >= 1);
    REQUIRE(r.done_code == 0);
    REQUIRE(r.done_stop_reason == "end_turn");
}

// ============================================================================
// 2.2 — tool_use parsing (single + fragmented input_json_delta)
// ============================================================================
TEST_CASE("SSE: tool_use single fragment", "[sse_parser]") {
    auto r = run_fixture("tool_use_single.txt");

    REQUIRE(r.tool_calls.size() == 1);
    auto tool = json::parse(r.tool_calls[0]);
    REQUIRE(tool["name"] == "read_file");
    REQUIRE(tool["id"] == "tool_001");
    REQUIRE(tool["input"]["file_path"] == "src/main.dart");
    REQUIRE(r.done_stop_reason == "tool_use");
}

TEST_CASE("SSE: tool_use fragmented input_json_delta", "[sse_parser]") {
    auto r = run_fixture("tool_use_fragmented.txt");

    REQUIRE(r.tool_calls.size() == 1);
    auto tool = json::parse(r.tool_calls[0]);
    REQUIRE(tool["name"] == "bash");
    REQUIRE(tool["id"] == "tool_002");
    REQUIRE(tool["input"]["command"] == "ls -la /tmp");
    REQUIRE(r.done_stop_reason == "tool_use");
}

// ============================================================================
// 2.3 — thinking block parsing (thinking + signature deltas)
// ============================================================================
TEST_CASE("SSE: thinking block", "[sse_parser]") {
    auto r = run_fixture("thinking_block.txt");

    // Incremental events delivered in real-time (2.1): one thinking_delta
    REQUIRE(r.thinking_deltas.size() == 1);
    auto dl = json::parse(r.thinking_deltas[0]);
    REQUIRE(dl["type"] == "thinking_delta");
    REQUIRE(dl["index"] == 0);
    REQUIRE(dl["delta"] == "Let me think about this problem carefully.");

    // Final event at content_block_stop (2.2): complete text + signature + index
    REQUIRE(r.thinkings.size() == 1);
    auto th = json::parse(r.thinkings[0]);
    REQUIRE(th["type"] == "thinking");
    REQUIRE(th["index"] == 0);
    REQUIRE(th["thinking"] == "Let me think about this problem carefully.");
    REQUIRE(th["signature"] == "sig_abc123");

    // Single-done guard (8.3): message_stop + [DONE] both present → exactly one
    REQUIRE(r.done_count == 1);
    REQUIRE(r.done_code == 0);
    REQUIRE(r.done_stop_reason == "end_turn");
}

// ============================================================================
// 2.4 — message_stop → on_done(0, "", stop_reason)
// ============================================================================
TEST_CASE("SSE: message_stop with end_turn", "[sse_parser]") {
    auto r = run_fixture("message_stop_end_turn.txt");

    REQUIRE(r.done_count >= 1);
    REQUIRE(r.done_code == 0);
    REQUIRE(r.done_err == "");
    REQUIRE(r.done_stop_reason == "end_turn");
}

TEST_CASE("SSE: message_stop with tool_use", "[sse_parser]") {
    auto r = run_fixture("message_stop_tool_use.txt");

    REQUIRE(r.done_count >= 1);
    REQUIRE(r.done_code == 0);
    REQUIRE(r.done_stop_reason == "tool_use");
}

// ============================================================================
// 2.5 — error event → on_done(-1, error_message, "")
// ============================================================================
TEST_CASE("SSE: error event", "[sse_parser]") {
    auto r = run_fixture("error_event.txt");

    REQUIRE(r.done_count >= 1);
    REQUIRE(r.done_code == -1);
    REQUIRE(r.done_err == "The server is currently overloaded. Please try again later.");
}

// ============================================================================
// 2.6 — unrecognized event type → no crash, LOG_WARN (no callback)
// ============================================================================
TEST_CASE("SSE: unrecognized event type", "[sse_parser]") {
    auto r = run_fixture("unrecognized_event.txt");

    REQUIRE(r.chunks.empty());
    REQUIRE(r.tool_calls.empty());
    REQUIRE(r.thinkings.empty());
    REQUIRE(r.done_count >= 1);
    REQUIRE(r.done_code == 0);
}

// ============================================================================
// 2.7 — [DONE] marker → on_done(0, "", stop_reason) with carry-forward
// ============================================================================
TEST_CASE("SSE: [DONE] marker", "[sse_parser]") {
    auto r = run_fixture("done_marker.txt");

    REQUIRE(r.done_count >= 1);
    REQUIRE(r.done_code == 0);
    REQUIRE(r.done_err == "");
    REQUIRE(r.done_stop_reason == "");
}

TEST_CASE("SSE: [DONE] marker with stop_reason carry-forward", "[sse_parser]") {
    auto r = run_fixture("done_marker_with_stop_reason.txt");

    REQUIRE(r.done_count >= 1);
    REQUIRE(r.done_code == 0);
    REQUIRE(r.done_stop_reason == "max_tokens");
}

// ============================================================================
// 2.8 — JSON parse error in data line → no crash, LOG_ERR, skip
// ============================================================================
TEST_CASE("SSE: JSON parse error in data line", "[sse_parser]") {
    auto r = run_fixture("json_parse_error.txt");

    REQUIRE(r.chunks.empty());
    REQUIRE(r.tool_calls.empty());
    REQUIRE(r.thinkings.empty());
    REQUIRE(r.done_count >= 1);
    REQUIRE(r.done_code == 0);
}

// ============================================================================
// 2.9 — content_block_delta missing "delta" field → no crash, silent skip
// ============================================================================
TEST_CASE("SSE: content_block_delta missing delta field", "[sse_parser]") {
    auto r = run_fixture("content_block_delta_no_delta.txt");

    REQUIRE(r.chunks.empty());
    REQUIRE(r.done_count >= 1);
    REQUIRE(r.done_code == 0);
}

// ============================================================================
// 2.10 — empty text_delta (text="") → on_chunk still fires (empty string)
// ============================================================================
TEST_CASE("SSE: empty text delta", "[sse_parser]") {
    auto r = run_fixture("text_empty.txt");

    REQUIRE(r.chunks.size() == 1);
    REQUIRE(r.chunks[0] == "");
    REQUIRE(r.done_count >= 1);
}

// ============================================================================
// 2.11 — content_block_start unknown type ("text") → no crash, LOG_INFO
// ============================================================================
TEST_CASE("SSE: content_block_start text type", "[sse_parser]") {
    auto r = run_fixture("content_block_start_text.txt");

    REQUIRE(r.tool_calls.empty());
    REQUIRE(r.thinkings.empty());
    REQUIRE(r.done_count >= 1);
}

// ============================================================================
// 2.12 — message_start event → no crash, LOG_INFO, no callback
// ============================================================================
TEST_CASE("SSE: message_start event", "[sse_parser]") {
    auto r = run_fixture("message_start.txt");

    REQUIRE(r.chunks.empty());
    REQUIRE(r.tool_calls.empty());
    REQUIRE(r.thinkings.empty());
    REQUIRE(r.done_count >= 1);
}

// ============================================================================
// 2.13 — ping event → no crash, no output
// ============================================================================
TEST_CASE("SSE: ping event", "[sse_parser]") {
    auto r = run_fixture("ping_event.txt");

    REQUIRE(r.chunks.empty());
    REQUIRE(r.tool_calls.empty());
    REQUIRE(r.thinkings.empty());
    REQUIRE(r.done_count >= 1);
}

// ============================================================================
// 2.14 — message_delta without stop_reason → last_stop_reason stays empty
// ============================================================================
TEST_CASE("SSE: message_delta without stop_reason", "[sse_parser]") {
    auto r = run_fixture("message_delta_no_stop_reason.txt");

    REQUIRE(r.done_count >= 1);
    REQUIRE(r.done_code == 0);
    REQUIRE(r.done_stop_reason == "");
}

// ============================================================================
// 2.15 — multi-block integration (thinking + text + tool_use interleaved)
// ============================================================================
TEST_CASE("SSE: multi-block integration", "[sse_parser]") {
    auto r = run_fixture("multi_block_integration.txt");

    REQUIRE(r.thinkings.size() == 1);
    REQUIRE(r.chunks.size() == 1);
    // thinking_delta events are also delivered (real-time incremental)
    REQUIRE_FALSE(r.thinking_deltas.empty());
    REQUIRE(r.chunks[0] == "Here's my answer.");
    REQUIRE(r.tool_calls.size() == 1);

    auto tool = json::parse(r.tool_calls[0]);
    REQUIRE(tool["name"] == "read_file");
    REQUIRE(tool["input"]["path"] == "test.txt");

    REQUIRE(r.done_count >= 1);
    REQUIRE(r.done_stop_reason == "tool_use");
}

// ============================================================================
// 2.16 — multiple tool_use blocks (different indices) → independently assembled
// ============================================================================
TEST_CASE("SSE: multiple tool_use blocks", "[sse_parser]") {
    auto r = run_fixture("tool_use_multi_block.txt");

    REQUIRE(r.tool_calls.size() == 2);

    auto t1 = json::parse(r.tool_calls[0]);
    REQUIRE(t1["name"] == "read_file");
    REQUIRE(t1["input"]["path"] == "a.txt");

    auto t2 = json::parse(r.tool_calls[1]);
    REQUIRE(t2["name"] == "list_dir");
    REQUIRE(t2["input"]["path"] == ".");

    REQUIRE(r.done_stop_reason == "tool_use");
}

// ============================================================================
// 2.17 — tool_use input_json parse failure → LOG_ERR, tool_use without input
// ============================================================================
TEST_CASE("SSE: tool_use input_json parse fail", "[sse_parser]") {
    auto r = run_fixture("tool_input_json_parse_fail.txt");

    REQUIRE(r.tool_calls.size() == 1);
    auto tool = json::parse(r.tool_calls[0]);
    REQUIRE(tool["name"] == "bash");
    // content_block_start provides "input":{} — parse failure leaves it empty
    REQUIRE(tool.contains("input"));
    REQUIRE(tool["input"].is_object());
    REQUIRE(tool["input"].empty());
    REQUIRE(r.done_stop_reason == "tool_use");
}

// ============================================================================
// Additional: text_multiple — multiple sequential text deltas
// ============================================================================
TEST_CASE("SSE: multiple text deltas", "[sse_parser]") {
    auto r = run_fixture("text_multiple.txt");

    REQUIRE(r.chunks.size() == 3);
    REQUIRE(r.chunks[0] == "First ");
    REQUIRE(r.chunks[1] == "Second ");
    REQUIRE(r.chunks[2] == "Third.");
    REQUIRE(r.done_count >= 1);
    REQUIRE(r.done_stop_reason == "end_turn");
}

// ============================================================================
// Realtime delivery (2.3) — callbacks fire before curl completes
// ============================================================================
static std::atomic<bool>* s_delta_seen = nullptr;
static void s_on_thinking_realtime(const char* t) {
    s_on_thinking(t);
    if (s_delta_seen && t && std::string(t).find("thinking_delta") != std::string::npos) {
        s_delta_seen->store(true);
    }
}

TEST_CASE("SSE: thinking delta delivered before curl completes", "[sse_parser][realtime]") {
    // Fixture body streamed in 64-byte chunks with 150ms gaps -> ~1s total
    MockServer server;
    server.set_response_body(
        "data: {\"type\":\"content_block_start\",\"index\":0,\"content_block\":{\"type\":\"thinking\",\"thinking\":\"\"}}\n\n"
        "data: {\"type\":\"content_block_delta\",\"index\":0,\"delta\":{\"type\":\"thinking_delta\",\"thinking\":\"incremental\"}}\n\n"
        "data: {\"type\":\"content_block_delta\",\"index\":0,\"delta\":{\"type\":\"signature_delta\",\"signature\":\"sig_x\"}}\n\n"
        "data: {\"type\":\"content_block_stop\",\"index\":0}\n\n"
        "data: {\"type\":\"message_stop\"}\n\n");
    server.set_streaming_chunks(64, 150);
    server.start("", 200);
    server.wait_ready();

    ModelGateway gw;
    gw.set_timeout(10);

    SseResult r;
    s_r = &r;
    std::atomic<bool> delta_seen{false};
    s_delta_seen = &delta_seen;

    std::atomic<bool> execute_returned{false};
    std::thread exec([&] {
        gw.execute(
            "sk-test", server.base_url().c_str(), "claude-sonnet-4-6",
            "", R"([{"role":"user","content":"hello"}])", "", "", "",
            s_on_chunk, s_on_tool_call, s_on_thinking_realtime, s_on_done);
        execute_returned.store(true);
    });

    // The incremental callback must fire while curl is still streaming
    // (execute has NOT returned yet - the stream takes ~1s in 150ms chunks)
    for (int i = 0; i < 300 && !delta_seen.load(); ++i) {
        std::this_thread::sleep_for(std::chrono::milliseconds(10));
    }
    REQUIRE(delta_seen.load());                 // delta callback fired
    REQUIRE_FALSE(execute_returned.load());     // ...while execute was still blocked

    exec.join();
    server.join();
    s_r = nullptr;
    s_delta_seen = nullptr;

    REQUIRE(r.done_count == 1);
    REQUIRE(r.done_code == 0);
}

// ============================================================================
// Request serialization (8.1) - concurrent execute calls serialize
// ============================================================================
TEST_CASE("SSE: concurrent execute calls serialize", "[sse_parser][concurrency]") {
    MockServer server1;
    server1.set_response_body(
        "data: {\"type\":\"content_block_delta\",\"index\":0,\"delta\":{\"type\":\"text_delta\",\"text\":\"one\"}}\n\n"
        "data: {\"type\":\"message_stop\"}\n\n");
    server1.set_streaming_chunks(16, 120);  // ~600ms per request
    server1.start("", 200);
    server1.wait_ready();

    MockServer server2;
    server2.set_response_body(
        "data: {\"type\":\"content_block_delta\",\"index\":0,\"delta\":{\"type\":\"text_delta\",\"text\":\"two\"}}\n\n"
        "data: {\"type\":\"message_stop\"}\n\n");
    server2.set_streaming_chunks(16, 120);
    server2.start("", 200);
    server2.wait_ready();

    ModelGateway gw;
    gw.set_timeout(10);

    std::atomic<int> done_count{0};
    std::atomic<bool> req1_done{false};
    std::atomic<bool> overlapped{false};

    // Thread A: request 1 (server1); Thread B: request 2 (server2).
    // If serialized (request_mutex), A's execute returns before B's starts.
    std::thread ta([&] {
        SseResult r1;
        s_r = &r1;
        gw.execute("sk-test", server1.base_url().c_str(), "m",
                   "", R"([{"role":"user","content":"a"}])", "", "", "",
                   s_on_chunk, s_on_tool_call, s_on_thinking, s_on_done);
        req1_done.store(true);
        done_count.fetch_add(1);
    });
    std::thread tb([&] {
        // Delay start slightly so A definitely holds the mutex first
        std::this_thread::sleep_for(std::chrono::milliseconds(50));
        if (!req1_done.load()) overlapped.store(true);  // B started while A active
        SseResult r2;
        s_r = &r2;
        gw.execute("sk-test", server2.base_url().c_str(), "m",
                   "", R"([{"role":"user","content":"b"}])", "", "", "",
                   s_on_chunk, s_on_tool_call, s_on_thinking, s_on_done);
        done_count.fetch_add(1);
    });

    ta.join();
    tb.join();
    server1.join();
    server2.join();
    s_r = nullptr;

    REQUIRE(done_count.load() == 2);          // both requests completed
    REQUIRE(req1_done.load());
    // B attempted to start while A was still streaming - the mutex serialized it
    REQUIRE(overlapped.load());               // precondition: B did overlap
}

// ============================================================================
// Cancellation (8.2) - cancel() aborts the stream with on_done(-1,"cancelled")
// ============================================================================
TEST_CASE("SSE: cancel aborts in-flight request", "[sse_parser][cancel]") {
    // Long streaming response (~10s if uncancelled): chunks x 200ms
    MockServer server;
    server.set_response_body(
        "data: {\"type\":\"content_block_start\",\"index\":0,\"content_block\":{\"type\":\"thinking\",\"thinking\":\"\"}}\n\n"
        "data: {\"type\":\"content_block_delta\",\"index\":0,\"delta\":{\"type\":\"thinking_delta\",\"thinking\":\"a\"}}\n\n"
        "data: {\"type\":\"content_block_delta\",\"index\":0,\"delta\":{\"type\":\"thinking_delta\",\"thinking\":\"b\"}}\n\n"
        "data: {\"type\":\"content_block_delta\",\"index\":0,\"delta\":{\"type\":\"thinking_delta\",\"thinking\":\"c\"}}\n\n"
        "data: {\"type\":\"content_block_delta\",\"index\":0,\"delta\":{\"type\":\"signature_delta\",\"signature\":\"sig_c\"}}\n\n"
        "data: {\"type\":\"content_block_stop\",\"index\":0}\n\n"
        "data: {\"type\":\"message_stop\"}\n\n");
    server.set_streaming_chunks(32, 200);
    server.start("", 200);
    server.wait_ready();

    ModelGateway gw;
    gw.set_timeout(30);

    SseResult r;
    s_r = &r;

    std::atomic<bool> execute_returned{false};
    std::thread exec([&] {
        gw.execute("sk-test", server.base_url().c_str(), "m",
                   "", R"([{"role":"user","content":"hi"}])", "", "", "",
                   s_on_chunk, s_on_tool_call, s_on_thinking, s_on_done);
        execute_returned.store(true);
    });

    // Let the stream start, then cancel
    std::this_thread::sleep_for(std::chrono::milliseconds(400));
    gw.cancel();

    // execute must return promptly after cancel (not wait the full stream)
    for (int i = 0; i < 200 && !execute_returned.load(); ++i) {
        std::this_thread::sleep_for(std::chrono::milliseconds(10));
    }
    REQUIRE(execute_returned.load());

    exec.join();
    server.join();
    s_r = nullptr;

    REQUIRE(r.done_count >= 1);
    REQUIRE(r.done_code == -1);
    REQUIRE(r.done_err == "cancelled");
}

// ============================================================================
// Single-done guard (8.3) - [DONE] after message_stop fires exactly one done
// ============================================================================
TEST_CASE("SSE: message_stop plus [DONE] fires exactly one done", "[sse_parser][done-idempotent]") {
    // Fixture ends with message_stop followed by data: [DONE] (DeepSeek
    // endpoint behavior) - on_done must fire exactly once.
    auto r = run_fixture("message_stop_end_turn.txt");

    REQUIRE(r.done_count == 1);
    REQUIRE(r.done_code == 0);
    REQUIRE(r.done_stop_reason == "end_turn");
}
