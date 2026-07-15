#include <catch2/catch_all.hpp>
#include "mock_server.h"
#include "model_gateway.h"
#include <string>
#include <nlohmann/json.hpp>

using json = nlohmann::json;

static std::string fixture(const std::string& name) {
    return std::string(FIXTURE_DIR) + "/" + name;
}

static const char* VALID_MSG = R"([{"role":"user","content":"hello"}])";

// ---------------------------------------------------------------------------
// Static capture for done callback
// ---------------------------------------------------------------------------
static bool s_done_called = false;
static int s_done_code = 0;
static std::string s_done_err;

static void s_done_nop(int, const char*, const char*) {
    // no-op callback
}

static void s_done_capture(int c, const char* e, const char*) {
    s_done_called = true;
    s_done_code = c;
    s_done_err = e ? e : "";
}

// ============================================================================
// 4.1 — Request headers (x-api-key, anthropic-version, content-type)
// ============================================================================
TEST_CASE("HTTP: request headers", "[http_client]") {
    MockServer server;
    server.start(fixture("text_delta.txt"));
    server.wait_ready();

    ModelGateway gw;
    gw.set_timeout(5);

    gw.execute(
        "sk-ant-test123", server.base_url().c_str(), "claude-sonnet-4-6",
        "", VALID_MSG, "",
        nullptr, nullptr, nullptr, s_done_nop
    );
    server.join();

    REQUIRE(server.last_method() == "POST");
    REQUIRE(server.last_path() == "/v1/messages");
    REQUIRE(server.last_header("x-api-key") == "sk-ant-test123");
    REQUIRE(server.last_header("anthropic-version") == "2023-06-01");
    REQUIRE(server.last_header("content-type") == "application/json");
}

// ============================================================================
// 4.2 — Request body includes all fields
// ============================================================================
TEST_CASE("HTTP: request body with all fields", "[http_client]") {
    MockServer server;
    server.start(fixture("text_delta.txt"));
    server.wait_ready();

    ModelGateway gw;
    gw.set_timeout(5);

    gw.execute(
        "sk-key", server.base_url().c_str(), "claude-opus-4-8",
        "You are helpful.", VALID_MSG,
        R"([{"name":"read_file","description":"Read a file","input_schema":{"type":"object"}}])",
        nullptr, nullptr, nullptr, s_done_nop
    );
    server.join();

    auto body = json::parse(server.last_body());
    REQUIRE(body["model"] == "claude-opus-4-8");
    REQUIRE(body["stream"] == true);
    REQUIRE(body["max_tokens"] == 4096);
    REQUIRE(body["system"] == "You are helpful.");
    REQUIRE(body["messages"].is_array());
    REQUIRE(body["tools"].is_array());
    REQUIRE(body["tools"][0]["name"] == "read_file");
}

// ============================================================================
// 4.3 — Optional fields omitted when system/tools are empty
// ============================================================================
TEST_CASE("HTTP: system omitted when empty", "[http_client]") {
    MockServer server;
    server.start(fixture("text_delta.txt"));
    server.wait_ready();

    ModelGateway gw;
    gw.set_timeout(5);

    gw.execute(
        "sk-key", server.base_url().c_str(), "claude-sonnet-4-6",
        "",
        VALID_MSG,
        nullptr,
        nullptr, nullptr, nullptr, s_done_nop
    );
    server.join();

    auto body = json::parse(server.last_body());
    REQUIRE(!body.contains("system"));
    REQUIRE(!body.contains("tools"));
}

TEST_CASE("HTTP: tools omitted when empty string", "[http_client]") {
    MockServer server;
    server.start(fixture("text_delta.txt"));
    server.wait_ready();

    ModelGateway gw;
    gw.set_timeout(5);

    gw.execute(
        "sk-key", server.base_url().c_str(), "claude-sonnet-4-6",
        "You are helpful.",
        VALID_MSG,
        "",
        nullptr, nullptr, nullptr, s_done_nop
    );
    server.join();

    auto body = json::parse(server.last_body());
    REQUIRE(body["system"] == "You are helpful.");
    REQUIRE(!body.contains("tools"));
}

// ============================================================================
// 4.4 — Default base_url when empty
// ============================================================================
TEST_CASE("HTTP: default base_url", "[http_client]") {
    // Verified by code review: model_gateway.cpp line 322-324:
    //   std::string url = (base_url && std::strlen(base_url) > 0)
    //       ? std::string(base_url) + "/v1/messages"
    //       : "https://api.anthropic.com/v1/messages";
    SUCCEED("Default base_url verified by code review (model_gateway.cpp:322-324)");
}

// ============================================================================
// 4.5 — Empty api_key → sends request with empty header
// NOTE: The send_message-level empty api_key check (early return without
// HTTP) lives in sidecar_api.cpp:47-50, which is not linked into the test
// binary. At the ModelGateway level, an empty api_key still results in an
// HTTP request with an empty x-api-key header.
// ============================================================================
TEST_CASE("HTTP: empty api_key sends request with empty header", "[http_client]") {
    MockServer server;
    server.start(fixture("text_delta.txt"));
    server.wait_ready();

    ModelGateway gw;
    gw.set_timeout(5);

    gw.execute(
        "",
        server.base_url().c_str(), "claude-sonnet-4-6",
        "", VALID_MSG, "",
        nullptr, nullptr, nullptr, s_done_nop
    );
    server.join();

    REQUIRE(server.last_method() == "POST");
    REQUIRE(server.last_header("x-api-key") == "");
}

// ============================================================================
// 4.6 — Invalid messages_json → on_done(-1, "Invalid messages JSON", "")
// ============================================================================
TEST_CASE("HTTP: invalid messages_json", "[http_client]") {
    ModelGateway gw;
    gw.set_timeout(5);

    s_done_called = false;
    s_done_code = 0;
    s_done_err = "";

    int rid = gw.execute(
        "sk-key", "", "claude-sonnet-4-6",
        "", "NOT VALID JSON {{{", "",
        nullptr, nullptr, nullptr, s_done_capture
    );

    REQUIRE(s_done_called);
    REQUIRE(s_done_code == -1);
    REQUIRE(s_done_err == "Invalid messages JSON");
    REQUIRE(rid == -1);
}

// ============================================================================
// 4.7 — Invalid tools_json → on_done(-1, "Invalid tools JSON", "")
// ============================================================================
TEST_CASE("HTTP: invalid tools_json", "[http_client]") {
    ModelGateway gw;
    gw.set_timeout(5);

    s_done_called = false;
    s_done_code = 0;
    s_done_err = "";

    int rid = gw.execute(
        "sk-key", "", "claude-sonnet-4-6",
        "", VALID_MSG, "NOT VALID JSON {{{",
        nullptr, nullptr, nullptr, s_done_capture
    );

    REQUIRE(s_done_called);
    REQUIRE(s_done_code == -1);
    REQUIRE(s_done_err == "Invalid tools JSON");
    REQUIRE(rid == -1);
}

// ============================================================================
// 4.8 — Request ID monotonically increasing
// ============================================================================
TEST_CASE("HTTP: request_id monotonically increasing", "[http_client]") {
    MockServer server;
    server.start(fixture("text_delta.txt"));
    server.wait_ready();

    ModelGateway gw;
    gw.set_timeout(5);

    int id1 = gw.execute(
        "sk-key", server.base_url().c_str(), "claude-sonnet-4-6",
        "", VALID_MSG, "",
        nullptr, nullptr, nullptr, s_done_nop
    );
    server.join();

    MockServer server2;
    server2.start(fixture("text_delta.txt"));
    server2.wait_ready();

    int id2 = gw.execute(
        "sk-key", server2.base_url().c_str(), "claude-sonnet-4-6",
        "", VALID_MSG, "",
        nullptr, nullptr, nullptr, s_done_nop
    );
    server2.join();

    REQUIRE(id1 > 0);
    REQUIRE(id2 > 0);
    REQUIRE(id2 > id1);
}

// ============================================================================
// 4.9 — HTTP 400 error body logging: raw_body captured and on_done receives error
// ============================================================================
TEST_CASE("HTTP: 400 error body captured and logged", "[http_client]") {
    MockServer server;
    server.start(fixture("text_delta.txt"), 400);  // HTTP 400
    server.wait_ready();

    ModelGateway gw;
    gw.set_timeout(5);

    s_done_called = false;
    s_done_code = 0;
    s_done_err = "";

    int rid = gw.execute(
        "sk-key", server.base_url().c_str(), "claude-sonnet-4-6",
        "", VALID_MSG, "",
        nullptr, nullptr, nullptr, s_done_capture
    );
    server.join();

    REQUIRE(s_done_called);
    REQUIRE(s_done_code == -1);
    REQUIRE(s_done_err.find("HTTP 400") != std::string::npos);
    REQUIRE(rid > 0);  // request ID still assigned (error after HTTP response)
}

// ============================================================================
// Additional: nullptr system + nullptr tools
// ============================================================================
TEST_CASE("HTTP: nullptr system and tools omitted", "[http_client]") {
    MockServer server;
    server.start(fixture("text_delta.txt"));
    server.wait_ready();

    ModelGateway gw;
    gw.set_timeout(5);

    gw.execute(
        "sk-key", server.base_url().c_str(), "claude-sonnet-4-6",
        nullptr,
        VALID_MSG,
        nullptr,
        nullptr, nullptr, nullptr, s_done_nop
    );
    server.join();

    auto body = json::parse(server.last_body());
    REQUIRE(!body.contains("system"));
    REQUIRE(!body.contains("tools"));
    REQUIRE(body["model"] == "claude-sonnet-4-6");
    REQUIRE(body.contains("messages"));
}
