"""browser_worker.py - Playwright headed browser worker for AliasAgent.

Persistent stdin/stdout JSON-line worker, mirroring scripts/fetch_worker.py's
subprocess protocol but LONG-LIVED: it reads many commands over time and keeps
one headed browser session alive across them (multi-step agent driving).

Protocol
--------
stdin (one JSON command per line):
  {"cmd":"open"}                                   # start session (create browser+page)
  {"cmd":"relaunch"}                               # AI-explicit reopen: kill + recreate
  {"cmd":"navigate","url":"..."}                   # navigate, return snapshot
  {"cmd":"click","selector":"..."}                 # click, return snapshot
  {"cmd":"type","selector":"...","text":"..."}     # fill a field, return snapshot
  {"cmd":"snapshot"}                               # re-read CURRENT page, return snapshot
  {"cmd":"available"}                              # probe Playwright+Edge; respond then EXIT

stdout (one JSON object per command - model-visible ONLY, no counters):
  {"ok":true,"url":"...","title":"...","snapshot":"...","snapshot_len":N,"truncated":bool}
  {"ok":false,"error":"...","dead":bool,"needs_relaunch":bool}

stderr (a machine-readable observability record PER call, routed to sidecar.log
by the C++ sidecar for test attribution - deliberately NOT in the model-visible
snapshot text):
  browser-record: {json}

The browser is headed (headless=False) so the user can see it. It is driven
programmatically (never via screen-level mouse simulation). The window is held
hidden as a default: the worker never calls bring_to_front. Design 甲 (follow
new tab): a click on a target=_blank result / window.open popup is FOLLOWED, not
closed — the newly-opened page becomes the active page (the AI reads the real
landing page), the original tab stays open, and the AI manages multi-tab via the
session. Permission requests are denied up front (grant_permissions([])).

NOTE: this file is ASCII-only. The worker must produce a UTF-8 byte stream on
stdout/stderr regardless of the Windows console/locale, so it reconfigure()s its
streams to UTF-8 at startup (a mojibake em-dash in a decoded locale would corrupt
the JSON pipe otherwise).
"""

import sys
import os
import json
import time
import hashlib
import traceback

try:
    from playwright.sync_api import sync_playwright, TimeoutError as PWTimeout
except Exception:  # pragma: no cover - import failure is probed via `available`
    sync_playwright = None
    PWTimeout = Exception


def _log(msg: str) -> None:
    """Diagnostic logging to stderr - captured by C++ sidecar into sidecar.log."""
    print(f"WORKER: {msg}", file=sys.stderr, flush=True)


# Length cap for the model-visible text snapshot (context-cost control).
MAX_SNAPSHOT_CHARS = 12000
# Per-command timeout for browser operations (seconds).
OP_TIMEOUT_SEC = 30.0
# Bounded per-channel launch timeout for the availability probe (seconds). The
# probe cold-launches a headless Edge; bounding it keeps the probe fast-fail and
# stops one slow channel from consuming the C++ probe's whole per-attempt budget
# (12.2). Generous vs the ~1.5s idle probe, so a real slow cold-start is not a
# false "no channel"; the C++ side retries the whole probe if it still times out.
PROBE_LAUNCH_TIMEOUT_SEC = 25.0
# Channel-probe retries inside a single `available` call: a load-induced slow
# cold-launch (the 12.2 target) is ridden out by re-trying before we ever report
# "no usable Edge/Chromium", so a transient spike does not become available:false.
PROBE_ATTEMPTS = 2
# Design 甲 (follow new tab): how long to wait, after a click, for a target=_blank
# tab / window.open popup to register before deciding the click navigated in-place.
# Measured on the local HTTP helper + the real worker: a tab-opening click's Page
# event registers in ~0.16-0.36s (the event precedes the target's content load —
# that load is handled separately by _wait_for_page_ready). We wait 1.0s — a ~2-6x
# margin over the worst measured case — so a real popup is never missed, while an
# in-place click pays only 1s wait instead of a longer stall. (expect_page blocks
# for exactly this whole window when NO popup opens; a well-known tradeoff.)
NEW_PAGE_WAIT_SEC = 1.0

# --- Window placement (task 12.13) -------------------------------------------
# The headed browser must stay user-visible (spec: "user-visible browser") but it
# must NOT sit on top of the AliasAgent window. Measured 2026-09-11 over 237
# frames of a live run: with the browser over the app only 10.5% of frames showed
# the app at all, and while the browser sat on about:blank the app's rect was
# pure white and text-free -- exactly the "the window went white / froze" symptom
# users reported. The C++ side passes its own window rect as --app-rect=L,T,W,H
# so the browser can be placed clear of it. Placement is a launch-time flag only:
# the worker still never calls bring_to_front (spec: SHALL NOT per-step raise).
PLACEMENT_GAP_PX = 8        # gap kept between the app window and the browser
PLACEMENT_MIN_W = 480       # a side narrower than this is not considered usable
PLACEMENT_MIN_H = 360

_APP_RECT = None            # (left, top, width, height) or None


def _parse_app_rect(argv) -> "tuple | None":
    """Parse --app-rect=L,T,W,H from argv. None when absent or malformed."""
    for arg in argv:
        if not arg.startswith("--app-rect="):
            continue
        parts = arg.split("=", 1)[1].split(",")
        if len(parts) != 4:
            continue
        try:
            left, top, width, height = (int(p) for p in parts)
        except ValueError:
            continue
        if width > 0 and height > 0:
            return (left, top, width, height)
    return None


def _get_work_area() -> "tuple | None":
    """Primary monitor work area (taskbar excluded) via SystemParametersInfoW."""
    try:
        import ctypes
        from ctypes import wintypes
        SPI_GETWORKAREA = 0x0030
        rect = wintypes.RECT()
        if ctypes.windll.user32.SystemParametersInfoW(
                SPI_GETWORKAREA, 0, ctypes.byref(rect), 0):
            w = rect.right - rect.left
            h = rect.bottom - rect.top
            if w > 0 and h > 0:
                return (rect.left, rect.top, w, h)
    except Exception as e:
        _log(f"work area query failed (no placement applied): {e}")
    return None


def compute_window_bounds(app_rect, work_area):
    """Where to put the headed browser so it does not cover the app window.

    Pure function (no I/O), so it is directly unit-testable. Returns
    (x, y, w, h, mode) with mode one of:
      "no-work-area" - screen unknown; caller keeps Playwright's default
      "full"         - no app rect known; right half of the work area
      "right"        - clear of the app, immediately to its right
      "left"         - clear of the app, immediately to its left
      "overlap"      - no clear side fits; least-overlap fallback (logged)
    """
    if not work_area:
        return (None, None, None, None, "no-work-area")

    wl, wt, ww, wh = work_area

    if not app_rect:
        w = min(ww, max(PLACEMENT_MIN_W, ww // 2))
        return (wl + ww - w, wt, w, wh, "full")

    al, _at, aw, _ah = app_rect

    rx = al + aw + PLACEMENT_GAP_PX          # first x clear of the app, to its right
    if rx + PLACEMENT_MIN_W <= wl + ww:
        return (rx, wt, wl + ww - rx, wh, "right")

    lx = al - PLACEMENT_GAP_PX               # last x clear of the app, to its left
    if lx - PLACEMENT_MIN_W >= wl:
        return (wl, wt, lx - wl, wh, "left")

    # Neither side has room for a usable window: take the roomier side and
    # RECORD the overlap rather than silently reverting to full coverage.
    right_room = max(0, (wl + ww) - rx)
    left_room = max(0, lx - wl)
    if right_room >= left_room:
        w = min(ww, max(PLACEMENT_MIN_W, right_room))
        x = wl + ww - w
    else:
        w = min(ww, max(PLACEMENT_MIN_W, left_room))
        x = wl
    return (x, wt, w, wh, "overlap")


def _placement_launch_args() -> "list":
    """Chromium flags placing the headed window clear of the app (task 12.13)."""
    if os.name != "nt":
        return []
    x, y, w, h, mode = compute_window_bounds(_APP_RECT, _get_work_area())
    if mode == "no-work-area" or x is None:
        _log("window placement: skipped (work area unknown)")
        return []
    if mode == "overlap":
        _log("window placement: OVERLAP FALLBACK - no clear side fits, "
             "the browser may cover the app window")
    else:
        _log(f"window placement: mode={mode} bounds={x},{y} {w}x{h}")
    return [f"--window-position={x},{y}", f"--window-size={w},{h}"]


class BrowserSession:
    """One headed Playwright browser session, reused across commands."""

    def __init__(self) -> None:
        self._pw = None
        self._browser = None
        self._context = None
        self._page = None
        self._channel = None
        self._ever_started = False
        # Tool-emitted counters (kept OUT of the model-visible snapshot text).
        self._raise_count = 0
        self._popup_closed = 0
        self._download_denied = 0
        self._permission_denied = 0
        # Design 甲 (follow new tab) counters: _browser_opened counts every page
        # the BROWSER opened (window.open / target=_blank); _adopted_tabs counts
        # how many of those the worker then FOLLOWED after a click.
        self._browser_opened = 0
        self._adopted_tabs = 0
        # Best-effort permission states read per step (observability only).
        self._last_permissions = {}
        # After returning a "dead" error once, the next command is allowed to
        # reopen (AI-explicit reopen). Without this a dead session would never
        # admit it, and without arming it a dead session would be silently
        # recreated (hiding the failure).
        self._reopen_armed = False
        # Divergence detection: expected URL + content hash after the last AI action.
        self._expected_url = None
        self._expected_content_hash = None

    # -- browser lifecycle ---------------------------------------------------

    @staticmethod
    def _probe_channel(pw) -> "str | None":
        """Return the first usable channel, or None. Headless probe so the
        availability probe never flashes a window on the user's screen."""
        for ch in ("msedge", "chrome"):
            try:
                b = pw.chromium.launch(channel=ch, headless=True,
                                       timeout=PROBE_LAUNCH_TIMEOUT_SEC * 1000)
                b.close()
                return ch
            except Exception:
                continue
        return None

    def _start_playwright(self) -> bool:
        if self._pw is not None:
            return True
        if sync_playwright is None:
            return False
        try:
            self._pw = sync_playwright().start()
            return True
        except Exception as e:
            _log(f"failed to start playwright: {e}")
            self._pw = None
            return False

    def _launch_browser(self) -> "str | None":
        """Create a fresh browser+context+page. Returns error string or None."""
        self._ever_started = True
        if self._browser is not None:
            try:
                self._browser.close()
            except Exception:
                pass
            self._browser = None
        self._context = None
        self._page = None
        self._reopen_armed = False
        self._expected_url = None
        self._expected_content_hash = None

        if not self._start_playwright():
            return "playwright unavailable"

        if self._channel is None:
            self._channel = self._probe_channel(self._pw)
        if self._channel is None:
            return "no usable Edge/Chromium found (tried msedge, chrome)"

        try:
            # Task 12.13: place the headed window clear of the app window so the
            # browser does not read as "the app went white".
            self._browser = self._pw.chromium.launch(
                channel=self._channel, headless=False, timeout=OP_TIMEOUT_SEC * 1000,
                args=_placement_launch_args())
            # accept_downloads=True so we can observe and cancel (deny) them via
            # the download handler — a cancelled download never persists a file
            # (spike 1.4 confirmed dl.cancel() leaves no file on disk). This makes
            # download denial observable in the per-call record.
            self._context = self._browser.new_context(accept_downloads=True)
            self._context.on("download", self._on_download)
            # Design 甲 (follow new tab): grant NO permissions up front so a page
            # that triggers a permission prompt (e.g. Bing's
            # edge://permission-request-dialog/) is auto-denied rather than
            # blocking the adopted tab's navigation (spike 2026-09-08 confirmed
            # grant_permissions([]) removes that dialog). Empty grant list = nothing
            # granted = requests auto-denied.
            try:
                self._context.grant_permissions([])
            except Exception as e:
                _log(f"grant_permissions([]) failed (best-effort): {e}")
            # A fresh browser session starts single-tab: the MAIN page is created
            # programmatically and the page handler is installed AFTER it, so the
            # main page's own creation never reaches the handler. Any page the
            # BROWSER opens from now on (window.open / target=_blank) is handled
            # by _install_page_handler.
            self._page = self._context.new_page()
            # Task 12.13: --window-position/--window-size are only HINTS. Measured
            # 2026-09-11: Chromium honored the position but IGNORED the requested
            # size (asked 750x1232, got 1296x808), which pushed the window off the
            # right edge of the screen. CDP is authoritative, so pin it here.
            self._apply_window_bounds()
            self._install_page_handler()
            return None
        except Exception as e:
            _log(f"launch failed: {e}")
            self._teardown()
            return f"browser launch failed: {e}"

    def _apply_window_bounds(self) -> None:
        """Pin the OS window bounds exactly, clear of the app window (task 12.13).

        Keeps the browser user-visible while guaranteeing it neither covers the
        app nor runs off the work area. Never raises or brings-to-front.
        """
        if _APP_RECT is None:
            return
        x, y, w, h, _mode = compute_window_bounds(_APP_RECT, _get_work_area())
        if x is None:
            return
        try:
            session = self._context.new_cdp_session(self._page)
            win = session.send("Browser.getWindowForTarget")
            session.send("Browser.setWindowBounds", {
                "windowId": win["windowId"],
                "bounds": {"left": x, "top": y, "width": w, "height": h,
                           "windowState": "normal"},
            })
            back = session.send("Browser.getWindowForTarget").get("bounds", {})
            _log("window placement applied: requested={},{} {}x{} actual={},{} {}x{}".format(
                x, y, w, h, back.get("left"), back.get("top"),
                back.get("width"), back.get("height")))
            session.detach()
        except Exception as e:
            _log(f"window placement via CDP failed (launch flags only): {e}")

    def _install_page_handler(self) -> None:
        def on_page(page) -> None:
            # Design 甲 (follow new tab): the worker does NOT close browser-opened
            # pages (a target=_blank result / window.open popup) — the AI reads the
            # real landing page a click produced. We only COUNT them here as an
            # observable (browser_opened). The FOLLOW itself is done in the click
            # handler by diffing the context's page set before/after the click
            # (robust against rel=noopener pages whose opener() is None). NEVER
            # count the main page; only pages with a real opener (window.open /
            # target=_blank) are browser popups — a programmatic context.new_page()
            # (initial OR a recreated main page) has a null opener (verified:
            # programmatic new_page() opener is None, popup opener is non-None).
            if self._page is not None and page is self._page:
                return
            try:
                if page.opener() is None:
                    return
                self._browser_opened += 1
                _log(f"browser-opened page counted (opened={self._browser_opened})")
            except Exception:
                pass

        self._context.on("page", on_page)

    # Stay-hidden guarantee: this worker NEVER calls bring_to_front (there is no
    # raise path at all), so _raise_count is legitimately 0. The regression guard
    # lives in the worker test, which scans this source file and fails if any
    # `bring_to_front(` call appears — catching the natural way a future raise
    # would be added. A counter alone is vacuous here (no raise ever happens), so
    # it is the source-level guard that makes the guarantee enforceable.

    def _on_download(self, download) -> None:
        """Cancel (deny) any download so no file persists (observable denial)."""
        try:
            download.cancel()
            self._download_denied += 1
            _log(f"download denied: {download.suggested_filename}")
        except Exception:
            pass

    def _teardown(self) -> None:
        try:
            if self._browser is not None:
                self._browser.close()
        except Exception:
            pass
        self._browser = None
        self._context = None
        self._page = None

    def shutdown(self) -> None:
        self._teardown()
        if self._pw is not None:
            try:
                self._pw.stop()
            except Exception:
                pass
            self._pw = None

    def _ensure_ready(self) -> tuple:
        """Ensure a live browser + page. Returns (page, error). On the first
        command the session starts (open semantics); after a started session
        dies, the failure is surfaced ONCE (dead=True) and the next command
        reopens it explicitly (AI-explicit reopen)."""
        browser_alive = (
            self._browser is not None
            and self._browser.is_connected()
        )
        if browser_alive:
            pass
        elif not self._ever_started:
            # First command on a fresh worker: this IS the session startup (open).
            err = self._launch_browser()
            if err is not None:
                return None, err
        else:
            # Was started before; watchdog: surface the failure ONCE (never hide a
            # dead session), and let the AI's next command reopen it explicitly.
            if not self._reopen_armed:
                self._reopen_armed = True
                return None, "browser session not connected - issue the command again to reopen"
            self._reopen_armed = False
            err = self._launch_browser()
            if err is not None:
                return None, err
        # Ensure a page exists after a (re)launch or a user-closed tab.
        if self._page is None or self._page.is_closed():
            try:
                self._page = self._context.new_page()
            except Exception as e:
                return None, f"failed to open a page: {e}"
        return self._page, None

    # -- permission state (observability) --------------------------------------

    def _read_permissions(self, page) -> dict:
        """Read the current origin's permission states (best effort, secure
        context only). Stashed on the session so _emit_record can include it
        WITHOUT leaking it into the model-visible snapshot text."""
        try:
            js = ("async () => { const out = {}; "
                  "try { out.notifications = (await navigator.permissions.query("
                  "{name:'notifications'})).state; } catch(e) {} "
                  "try { out.geolocation = (await navigator.permissions.query("
                  "{name:'geolocation'})).state; } catch(e) {} "
                  "return out; }")
            res = page.evaluate(js)
            return res if isinstance(res, dict) else {}
        except Exception:
            return {}

    # -- snapshot ------------------------------------------------------------

    def _snapshot(self, page) -> dict:
        """Return the model-visible snapshot dict (text only, no counters)."""
        try:
            text = page.inner_text("body", timeout=OP_TIMEOUT_SEC * 1000)
        except Exception:
            # Some pages report no body innerText; fall back to textContent.
            try:
                text = page.evaluate("document.body ? document.body.innerText : ''")
            except Exception:
                text = ""
        truncated = False
        if text is None:
            text = ""
        if len(text) > MAX_SNAPSHOT_CHARS:
            text = text[:MAX_SNAPSHOT_CHARS]
            truncated = True
        # Read permission states here (side effect on session) so the record can
        # observe the auto-denial WITHOUT the states leaking into model content.
        self._last_permissions = self._read_permissions(page)
        denied = sum(1 for v in self._last_permissions.values() if v == "denied")
        self._permission_denied = denied
        return {
            "ok": True,
            "url": page.url,
            "title": page.title(),
            "snapshot": text,
            "snapshot_len": len(text),
            "truncated": truncated,
        }

    @staticmethod
    def _content_hash(text: str) -> str:
        """Stable hash of the page's readable text, for content-divergence."""
        return hashlib.sha256((text or "").encode("utf-8")).hexdigest()

    def _divergence_note(self, page, current_text: str) -> dict:
        """Detect user-takeover divergence: current URL OR content hash differs
        from the state the AI last acted on (a user navigate OR an in-place edit /
        JS mutation on the same URL)."""
        if self._expected_url is None:
            return {}
        current = page.url
        current_hash = self._content_hash(current_text)
        if current == self._expected_url and current_hash == self._expected_content_hash:
            return {}
        note = (f"Page ({current}) differs from the state the AI last acted on "
                f"(URL {self._expected_url}) - the user may have navigated away "
                f"or edited the page. Re-read before acting.")
        return {"divergent": True, "note": note}

    def _mark_expected(self, page, text: str) -> None:
        """Record the URL + content hash the AI just produced, so a LATER user
        action is the divergence (never the AI's own navigate/click/type)."""
        self._expected_url = page.url
        self._expected_content_hash = self._content_hash(text)

    # -- command handlers ----------------------------------------------------

    def _handle_open(self, req: dict) -> dict:
        if self._browser is not None and self._browser.is_connected():
            return {"ok": True, "url": self._page.url if self._page else "", "snapshot": "", "already_open": True}
        err = self._launch_browser()
        if err is not None:
            return {"ok": False, "error": err}
        return {"ok": True, "url": self._page.url if self._page else "", "snapshot": ""}

    def _launch_for_op(self):
        """Ensure the session is live for an op. Returns a Page, or a dict error."""
        page, err = self._ensure_ready()
        if err is not None and page is None:
            return {"ok": False, "error": err, "dead": True, "needs_relaunch": True}
        if page is None:
            return {"ok": False, "error": "browser page not ready"}
        return page

    def _handle_navigate(self, req: dict) -> dict:
        page = self._launch_for_op()
        if isinstance(page, dict):
            return page
        url = req.get("url", "")
        if not url:
            return {"ok": False, "error": "navigate: url is required"}
        try:
            page.goto(url, timeout=OP_TIMEOUT_SEC * 1000, wait_until="load")
        except PWTimeout:
            return {"ok": False, "error": f"navigate: timed out loading {url}"}
        except Exception as e:
            return {"ok": False, "error": f"navigate: {e}"}
        resp = self._snapshot(page)
        self._mark_expected(page, resp["snapshot"])
        resp.update(self._divergence_note(page, resp["snapshot"]))
        return resp

    def _wait_for_page_ready(self, page) -> None:
        """Wait for a followed page to reach a readable state (best-effort)."""
        try:
            page.wait_for_load_state("domcontentloaded", timeout=OP_TIMEOUT_SEC * 1000)
        except Exception:
            pass

    def _handle_click(self, req: dict) -> dict:
        page = self._launch_for_op()
        if isinstance(page, dict):
            return page
        selector = req.get("selector", "")
        if not selector:
            return {"ok": False, "error": "click: selector is required"}
        # Design 甲 (follow new tab): a click on a target=_blank result / window.open
        # popup opens a NEW page. context.expect_page() reliably awaits that popup
        # (polling context.pages does NOT see it mid-loop — the popup event only
        # flushes on a Playwright API pump). We bound the wait to NEW_PAGE_WAIT_SEC:
        # if a page opens we FOLLOW it (make it active, wait for load) so the AI
        # reads the REAL landing page; if none opens in the window the click
        # navigated in-place and we keep the current page. This replaces the
        # single-tab close (which was dropping the landing page).
        #
        # expect_page's context-manager RAISES PWTimeout on block exit when no page
        # opened (the common in-place click), and pinfo.value is set once a popup
        # fires. So we (a) run the click inside, capturing its OWN error into
        # click_err (never swallowed silently), and (b) treat the exit-timeout as a
        # normal "no popup → in-place navigation", NOT a click failure. A click error
        # is still surfaced (we check click_err after the block).
        click_err = None
        new_page = None
        try:
            with self._context.expect_page(timeout=NEW_PAGE_WAIT_SEC * 1000) as pinfo:
                try:
                    page.click(selector, timeout=OP_TIMEOUT_SEC * 1000)
                except PWTimeout as e:
                    click_err = {"ok": False, "error": f"click: timed out waiting for {selector}: {e}"}
                except Exception as e:
                    click_err = {"ok": False, "error": f"click: {e}"}
                if click_err is None and pinfo.value is not None:
                    new_page = pinfo.value
        except PWTimeout:
            # expect_page found no page on exit: the click navigated in-place OR the
            # selector was missing. If the click itself succeeded (click_err is None),
            # this is the in-place case — proceed without a follow. If the click
            # errored, click_err below wins.
            pass
        if click_err is not None:
            return click_err
        if new_page is not None and not new_page.is_closed():
            self._page = new_page
            self._adopted_tabs += 1
            self._wait_for_page_ready(new_page)
            page = new_page
            _log(f"followed new tab (adopted={self._adopted_tabs})")
        # A click may itself navigate the page; that is the AI's own action, so
        # the resulting URL + content hash become the new expected state.
        resp = self._snapshot(page)
        self._mark_expected(page, resp["snapshot"])
        resp.update(self._divergence_note(page, resp["snapshot"]))
        return resp

    def _handle_type(self, req: dict) -> dict:
        page = self._launch_for_op()
        if isinstance(page, dict):
            return page
        selector = req.get("selector", "")
        text = req.get("text", "")
        if not selector:
            return {"ok": False, "error": "type: selector is required"}
        try:
            page.fill(selector, text, timeout=OP_TIMEOUT_SEC * 1000)
        except PWTimeout:
            return {"ok": False, "error": f"type: timed out waiting for {selector}"}
        except Exception as e:
            return {"ok": False, "error": f"type: {e}"}
        # A type may submit a form and navigate; that is the AI's own action.
        resp = self._snapshot(page)
        self._mark_expected(page, resp["snapshot"])
        resp.update(self._divergence_note(page, resp["snapshot"]))
        return resp

    def _handle_snapshot(self, req: dict) -> dict:
        page = self._launch_for_op()
        if isinstance(page, dict):
            return page
        resp = self._snapshot(page)
        # A standalone snapshot does NOT update the expected state — it compares
        # the current page against the last AI-driven action, so a user navigate /
        # edit since then is surfaced as divergence.
        resp.update(self._divergence_note(page, resp["snapshot"]))
        return resp

    def _handle_relaunch(self, req: dict) -> dict:
        err = self._launch_browser()
        if err is not None:
            return {"ok": False, "error": err}
        return {"ok": True, "url": self._page.url if self._page else "", "snapshot": "", "relaunched": True}


def _emit_record(cmd: str, input_obj: dict, result: dict, session: BrowserSession) -> None:
    """Write the machine-readable observability record to stderr (NOT model-visible)."""
    try:
        record = {
            "tool": cmd,
            "input": input_obj,
            "ok": result.get("ok", False),
            "status": "ok" if result.get("ok", False) else "error",
            "snapshot_len": result.get("snapshot_len", 0),
            "url": result.get("url", ""),
            "title": result.get("title", ""),
            "raise_count": session._raise_count,
            "popup_closed": session._popup_closed,
            "browser_opened": session._browser_opened,
            "adopted_tabs": session._adopted_tabs,
            "download_denied": session._download_denied,
            "permission_denied": session._permission_denied,
            "permissions": session._last_permissions,
            "tabs": len(session._context.pages) if session._context else 0,
            "divergent": result.get("divergent", False),
            "error": result.get("error", ""),
        }
        print(f"browser-record: {json.dumps(record, ensure_ascii=False)}",
              file=sys.stderr, flush=True)
    except Exception:
        pass


def _probe_available() -> dict:
    """One-shot: is Playwright + a usable Edge/Chromium present? Then EXIT."""
    if sync_playwright is None:
        return {"ok": True, "available": False, "error": "playwright not installed"}
    try:
        with sync_playwright() as pw:
            # Retry the channel probe so a transient load-induced slow cold-launch
            # (the 12.2 condition) is ridden out instead of being reported as
            # "no usable Edge/Chromium". A genuine absence still returns fast and
            # stays false across retries.
            ch = None
            for _ in range(PROBE_ATTEMPTS):
                ch = BrowserSession._probe_channel(pw)
                if ch is not None:
                    break
            if ch is None:
                return {"ok": True, "available": False, "error": "no usable Edge/Chromium"}
            return {"ok": True, "available": True, "channel": ch}
    except Exception as e:
        return {"ok": True, "available": False, "error": f"probe failed: {e}"}


def main() -> None:
    # Force UTF-8 byte streams so the JSON pipe is correct regardless of the
    # Windows console/locale encoding (a locale-mangled byte corrupts the pipe).
    for stream in (sys.stdout, sys.stderr):
        try:
            stream.reconfigure(encoding="utf-8")
        except Exception:
            pass

    global _APP_RECT
    _APP_RECT = _parse_app_rect(sys.argv[1:])
    if _APP_RECT is not None:
        _log(f"app rect from argv: {_APP_RECT}")

    session = BrowserSession()
    while True:
        line = sys.stdin.readline()
        if not line:  # EOF - parent closed our stdin; exit.
            break
        line = line.strip()
        if not line:
            continue
        try:
            req = json.loads(line)
        except json.JSONDecodeError as e:
            print(json.dumps({"ok": False, "error": f"invalid JSON: {e}"}), flush=True)
            continue

        cmd = req.get("cmd", "")

        # `available` is a one-shot probe: respond, then exit so the parent's
        # one-shot subprocess run sees a clean termination.
        if cmd == "available":
            print(json.dumps(_probe_available(), ensure_ascii=False), flush=True)
            session.shutdown()
            return

        try:
            if cmd == "open":
                result = session._handle_open(req)
            elif cmd == "relaunch":
                result = session._handle_relaunch(req)
            elif cmd == "navigate":
                result = session._handle_navigate(req)
            elif cmd == "click":
                result = session._handle_click(req)
            elif cmd == "type":
                result = session._handle_type(req)
            elif cmd == "snapshot":
                result = session._handle_snapshot(req)
            else:
                result = {"ok": False, "error": f"unknown command: {cmd}"}
        except Exception as e:
            traceback.print_exc(file=sys.stderr)
            result = {"ok": False, "error": f"worker error: {e}"}

        _emit_record(cmd, req, result, session)
        print(json.dumps(result, ensure_ascii=False), flush=True)

    session.shutdown()


if __name__ == "__main__":
    main()
