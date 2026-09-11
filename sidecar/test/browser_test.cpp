#include <catch2/catch_all.hpp>
#include "browser.h"
#include <nlohmann/json.hpp>

using json = nlohmann::json;
using namespace browser;

// ============================================================================
// add-browser-tool (tasks 3.1-3.3, 5.2) — persistent Playwright browser worker.
//
// These tests exercise the sidecar's browser tool boundary:
//   - browser_available() probe returns well-formed JSON (never empty/throw).
//   - When the browser stack is ABSENT the ops degrade to a readable error
//     (never a silent success placeholder) — the graceful-degradation contract.
//   - When the stack IS present, one real persistent session drives a navigate
//     then snapshot — validating the C++ persistent-subprocess process
//     management (spawn + per-command stdin/stdout round-trip + state carry).
//     (The full multi-step behavior is covered by the live integration test.)
//
// The real-op case launches a HEADED Edge window — that is the actual tool.
// A json::parse failure throws and fails the case, so invalid JSON from any
// browser_* export is a caught regression.
// ============================================================================

TEST_CASE("browser: availability probe returns well-formed JSON", "[browser]") {
    auto result = browser::browser_available();
    CHECK_FALSE(result.empty());
    auto j = json::parse(result);  // throws -> fail if malformed
    REQUIRE(j["ok"].get<bool>() == true);
    REQUIRE(j.contains("available"));
    REQUIRE(j["available"].is_boolean());
    INFO("browser_available -> " << result);
}

TEST_CASE("browser: ops return model-visible JSON (never empty / throw)", "[browser]") {
    // Each op (even on a missing stack) must produce a parseable JSON object with
    // an `ok` field — never an empty string, never a crash.
    auto avail = json::parse(browser::browser_available());
    bool has_browser = avail["available"].get<bool>();

    if (!has_browser) {
        // Graceful degradation: without the stack, ops return a readable error,
        // NOT a success placeholder.
        auto nav = json::parse(browser::browser_navigate("{\"url\":\"data:text/html,hi\"}"));
        CHECK(nav["ok"].get<bool>() == false);
        CHECK(nav.contains("error"));
        auto snap = json::parse(browser::browser_snapshot("{}"));
        CHECK(snap["ok"].get<bool>() == false);
        CHECK(snap.contains("error"));
        WARN("browser stack absent - verified degradation contract");
    } else {
        WARN("browser present - headed-launch real behavior is exercised in the "
             "next case, not here");
    }
}

TEST_CASE("browser: persistent session carries state across commands", "[browser]") {
    auto avail = json::parse(browser::browser_available());
    if (!avail["available"].get<bool>()) {
        WARN("browser stack absent - skipping real-session case");
        SUCCEED();
        return;
    }
    browser::reset_session(false);  // fresh session startup

    // Navigate a synthetic data URL (no network), assert a non-trivial snapshot.
    const char* html =
        "<html><body><h1>Hello Browser</h1><p id='p'>Alpha</p></body></html>";
    std::string url = std::string("data:text/html,<html><body><h1>Hello Browser</h1>"
                                  "<p id='p'>Alpha</p></body></html>");
    auto nav_req = json{{"url", url}}.dump();
    auto nav = json::parse(browser::browser_navigate(nav_req));
    INFO("navigate -> " << nav.dump());
    REQUIRE(nav["ok"].get<bool>() == true);
    REQUIRE(nav.value("snapshot_len", 0) > 0);
    REQUIRE(nav["snapshot"].get<std::string>().find("Hello Browser") != std::string::npos);

    // A second command on the SAME session must succeed and see the same page
    // (state carries — this is what distinguishes persistent from one-shot).
    auto snap = json::parse(browser::browser_snapshot("{}"));
    INFO("snapshot -> " << snap.dump());
    REQUIRE(snap["ok"].get<bool>() == true);
    REQUIRE(snap.value("snapshot_len", 0) > 0);
    REQUIRE(snap["snapshot"].get<std::string>().find("Hello Browser") != std::string::npos);

    // Click a selector that exists; still ok, snapshot fresh.
    auto click = json::parse(browser::browser_click("{\"selector\":\"#p\"}"));
    INFO("click -> " << click.dump());
    REQUIRE(click["ok"].get<bool>() == true);
    (void)html;
}

TEST_CASE("browser: dead worker surfaces dead:true once, then explicit reopen", "[browser]") {
    auto avail = json::parse(browser::browser_available());
    if (!avail["available"].get<bool>()) {
        WARN("browser stack absent - skipping dead-path case");
        SUCCEED();
        return;
    }
    // Simulate a session that HAD started then its worker died between commands.
    browser::reset_session(true);

    // The next command must surface a detectable dead:true (never silently restart).
    auto dead = json::parse(browser::browser_snapshot("{}"));
    INFO("post-death snapshot -> " << dead.dump());
    REQUIRE(dead["ok"].get<bool>() == false);
    REQUIRE(dead["dead"].get<bool>() == true);
    REQUIRE(dead["needs_relaunch"].get<bool>() == true);

    // The AI's explicit reopen is the next command: a fresh session starts and works.
    auto reopened = json::parse(browser::browser_snapshot("{}"));
    INFO("reopen snapshot -> " << reopened.dump());
    REQUIRE(reopened["ok"].get<bool>() == true);
}
