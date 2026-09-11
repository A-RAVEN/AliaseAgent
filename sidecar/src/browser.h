#ifndef BROWSER_H
#define BROWSER_H

#include <string>

// ============================================================================
// browser — a persistent Playwright-headed browser tool
//
// The browser worker (scripts/browser_worker.py) is a LONG-LIVED subprocess:
// it is spawned once and kept alive across many FFI calls so an agent can drive
// multi-step browsing (navigate -> click -> type -> snapshot) within one task.
// Unlike the one-shot subprocess::run used by web_fetch, these functions manage
// a persistent process with per-command stdin/stdout JSON.
//
// The window is headed (user-visible) but held hidden by default; the tool never
// raises the window on its own, cancels downloads, never grants permissions. Per
// design 甲 (follow new tab): it does NOT close popups/new tabs — a click on a
// target=_blank result / window.open popup is FOLLOWED (the new page becomes the
// active page, so the AI reads the real landing page) and multi-tab is expected;
// the original tab stays open and the AI manages the session (re-navigate to go
// back; session-close is the fallback). When the browser dies the watchdog
// surfaces a detectable failure once (never hides it) and the AI reopens it
// explicitly on the next command.
//
// Availability is gated on Playwright + a usable Edge/Chromium (browser_available);
// when unavailable the tool returns a readable error rather than silently
// substituting a placeholder (graceful degradation).
// ============================================================================

namespace browser {

/// Probe whether the browser stack is present (Playwright + Edge/Chromium).
/// One-shot: spawns browser_worker.py with {"cmd":"available"}, which exits
/// after responding. Returns JSON: {"ok":true,"available":bool,...}
///                              or {"ok":false,"error":"..."}
std::string browser_available();

/// Map a browser tool call to its worker command and run it on the persistent
/// session. `request_json` carries only the tool-specific parameters:
///   navigate: {"url":"..."}
///   click:    {"selector":"..."}
///   type:     {"selector":"...","text":"..."}
///   snapshot: {}
/// Returns the worker's response JSON (model-visible snapshot, counters logged
/// to sidecar.log OUTSIDE the text).
std::string browser_navigate(const std::string& request_json);
std::string browser_click(const std::string& request_json);
std::string browser_type(const std::string& request_json);
std::string browser_snapshot(const std::string& request_json);

/// Test hook: tear down the persistent worker and reset session state so a test
/// can deterministically exercise the watchdog "dead once then explicit reopen"
/// path (a dead worker must surface dead:true once, not silently restart).
///   was_started=false -> fresh state (next op is a session startup).
///   was_started=true  -> session HAD started then died (next op is a dead-detection).
void reset_session(bool was_started = false);

} // namespace browser

#endif // BROWSER_H
