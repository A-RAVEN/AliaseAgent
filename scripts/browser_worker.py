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

NOTE: no non-ASCII in any RUNTIME string (the JSON pipe must stay byte-safe). The
file's comments/docstrings do contain a few non-ASCII characters (~54 bytes: em
dashes, the design name in CJK); an earlier revision of this note claimed the file
was "ASCII-only", which was simply false -- corrected by the round-10 review. The
worker must produce a UTF-8 byte stream on
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
# in-place click pays only 1s wait instead of a longer stall.
#
# The wait is an UPPER bound counted from AFTER the click returns, and a page that
# registered DURING the click costs no wait at all (the page handler already
# recorded it — see _handle_click and _take_opened_page).
NEW_PAGE_WAIT_SEC = 1.0
# The longer bound for a click whose element declares a new-window target
# (target=_blank / a named target), decided BEFORE the click by _click_opens_new_page.
# Only those clicks pay it, so the higher cost lands on the operation that actually
# opens a page instead of on every click. A full-suite run showed the ordinary 1.0s
# bound being missed under load; the 1.5s case is the deterministic reproduction,
# and task 5.1 probes a 3s case to give this bound a measured lower edge.
NEW_TAB_WAIT_SEC = 5.0

# --- Window placement (tasks 12.13 / 12.15 / 12.17) --------------------------
# The headed browser must stay user-visible (spec: "user-visible browser") but it
# should not sit on top of the AliasAgent window. The C++ side passes its own
# window rect as --app-rect=L,T,W,H so the browser can be placed with that in
# mind. Placement is a launch-time flag only: the worker still never calls
# bring_to_front (spec: SHALL NOT per-step raise).
#
# Numbers: an earlier revision of this comment cited "237 frames, only 10.5%
# showed the app". The round-8 adversarial review showed that measurement has NO
# surviving artifacts (and its own sub-counts did not add up), so it is NOT
# restated here.
#
# PROVENANCE, corrected by the round-10 review (this is the part that was wrong):
# the figure once quoted here -- "max occlusion 2%, app's left >= 1254px", from
# capture-20260912-121348.log -- describes the build BEFORE the physical/logical
# pixel fix. That run's real window was 1580,20 1600x1125 physical: its right edge
# 3180 exceeded the 2560px screen by 620px. Its 2% is therefore the sliver of an
# OFF-SCREEN window, and the 1254px is the DPI-VIRTUALIZED reading of a DPI-unaware
# observer (real physical left 1580 -> 1568px visible -> /1.25 = 1254).
#
# The SHIPPED placement's own figure, same ruler (intersection area / app area):
# app 12,12 1600x900 vs browser 1264,16 1280x900 -> overlap 348x896 = 311,808px2
# = 21.65% of the app's area, app's left 1252px visible. That is ~11x the 2% once
# quoted here, and it is not a defect: task 12.15 deliberately traded "never cover
# the app" for "look like a browser" (the 600px-visible floor is the acceptance
# criterion, and it holds on work areas >= ~1908px wide).
PLACEMENT_GAP_PX = 8        # gap kept between the app window and the browser
PLACEMENT_EDGE_PAD = 16     # margin kept from the work-area edges
# Target size of the headed browser window: a normal-looking browser, not a strip.
# Task 12.13 shipped a 520x900 window (aspect 0.58) because it treated "never
# cover the app" as a hard goal -- but with a 1600px-wide app window on a single
# 2560px-wide work area only 940px are left beside it, under the 1280px target, so
# that goal can only ever produce a narrow strip. The user's verdict on that
# result was "still thin and long, ugly". Task 12.15 flips the priority: look like
# a browser first, overlap the app a little if that is what the geometry forces,
# and keep the app's left portion visible.
# (This comment used to say "2048-wide screen ... only 428px": that compared the
# app's PHYSICAL right edge against a DPI-VIRTUALIZED screen width. Task 12.17.)
PLACEMENT_NORMAL_W = 1280
PLACEMENT_NORMAL_H = 900
# Oracle floors (task 12.15): below these the window reads as a strip again.
PLACEMENT_MIN_W = 1000
PLACEMENT_MIN_H = 700

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


_DPI_INIT_DONE = False


def _make_dpi_aware() -> None:
    """Put this process in the SAME coordinate space as the app window (task 12.17).

    The app declares PerMonitorV2 (windows/runner/runner.exe.manifest), so the
    rect the C++ side sends via --app-rect is in PHYSICAL pixels. A DPI-unaware
    python, however, gets a VIRTUALIZED work area from SystemParametersInfoW. On
    this machine that mismatch is exactly the bug the round-8 review found: the
    app's physical right edge (1612) was being subtracted from the virtualized
    screen width (2048), yielding a bogus "only 428px left", which then got
    written into the tests as "real geometry". Becoming DPI-aware makes both
    readings physical and the comparison meaningful.
    """
    global _DPI_INIT_DONE
    if _DPI_INIT_DONE:
        return
    try:
        import ctypes
        # 2 = PROCESS_PER_MONITOR_DPI_AWARE (Windows 8.1+). NOTE (round-11 review):
        # a failed HRESULT does NOT raise in ctypes (a second call returns
        # -2147024891 silently), so the return code must be checked -- an earlier
        # version only caught exceptions and could therefore never fall back.
        hr = ctypes.windll.shcore.SetProcessDpiAwareness(2)
        if hr != 0:
            _log(f"SetProcessDpiAwareness(2) returned HRESULT {hr}; "
                 "falling back to SetProcessDPIAware()")
            if not ctypes.windll.user32.SetProcessDPIAware():
                _log("DPI awareness init FAILED (both APIs); readings may stay "
                     "virtualized and must not be labelled physical")
                return
        _DPI_INIT_DONE = True
    except Exception as e:
        try:
            import ctypes
            if ctypes.windll.user32.SetProcessDPIAware():
                _DPI_INIT_DONE = True
                return
        except Exception:
            pass
        _log(f"DPI awareness init failed (work area may stay virtualized): {e}")


_DPI_SCALE_CACHE = None


def _get_dpi_scale() -> float:
    """Physical-pixels-per-logical-pixel (1.25 on a 125% display).

    Three parties disagree about units, and getting this wrong put the window
    620px off a 2560px screen:
      - the AliasAgent window rect arrives in PHYSICAL pixels (the app declares
        PerMonitorV2),
      - the work area is read here in PHYSICAL pixels (we made the process
        DPI-aware),
      - but Chromium interprets the numbers we hand it (--window-position /
        --window-size and CDP Browser.setWindowBounds) as LOGICAL pixels and
        multiplies them by this scale. Measured 2026-09-12: requesting 1280x900
        produced a 1600x1125 physical window with its right edge 620px off-screen.
    So: compute everything in physical, then divide by this scale at the one
    boundary where values reach Chromium.
    """
    global _DPI_SCALE_CACHE
    if _DPI_SCALE_CACHE is not None:
        return _DPI_SCALE_CACHE
    # Round-11 review: GetDpiForSystem returns 96 (=> scale 1.0) while the process is
    # still DPI-UNAWARE, and this function CACHES whatever it sees. Called before any
    # work-area read, it would therefore freeze scale = 1.0 for the whole run and
    # silently re-create the 620px bug. Become aware first, always.
    _make_dpi_aware()
    scale = 1.0
    try:
        import ctypes
        dpi = ctypes.windll.user32.GetDpiForSystem()
        if dpi and dpi > 0:
            scale = dpi / 96.0
    except Exception as e:
        _log(f"DPI scale query failed (assuming 1.0, window may be misplaced): {e}")
    _DPI_SCALE_CACHE = scale
    _log(f"dpi scale = {scale} (physical = logical x scale)")
    return scale


def _to_logical(rect):
    """(l,t,w,h) in physical pixels -> the logical pixels Chromium expects."""
    if rect is None:
        return None
    s = _get_dpi_scale()
    return (int(round(rect[0] / s)), int(round(rect[1] / s)),
            int(round(rect[2] / s)), int(round(rect[3] / s)))


def _get_work_area_logical() -> "tuple | None":
    """Work area in the LOGICAL space Chromium and CDP report in."""
    return _to_logical(_get_work_area())


def _coord_space_label() -> str:
    """Name the coordinate space this process is actually measuring in.

    Round-12 review: the log lines below used to hard-code the word "physical"
    whether or not DPI awareness had actually taken effect. Do not claim a space we
    have not established.
    """
    return "physical" if _DPI_INIT_DONE else "VIRTUALIZED (DPI awareness NOT established)"


def child_process_pids(max_depth=4) -> "list":
    """PIDs of processes DESCENDING from this one (Windows only; [] elsewhere).

    Playwright spawns the browser, but with `channel="msedge"` the process it starts
    is a LAUNCHER: the real browser process (the one owning the window) is a
    grandchild. A direct-children-only scan therefore finds nothing -- observed in
    the first live run after task 12.27 landed ("OS rect not measurable"). So walk
    the whole descendant tree to `max_depth`.
    """
    if os.name != "nt":
        return []
    import ctypes
    from ctypes import wintypes
    TH32CS_SNAPPROCESS = 0x00000002

    class PROCESSENTRY32(ctypes.Structure):
        _fields_ = [
            ("dwSize", wintypes.DWORD), ("cntUsage", wintypes.DWORD),
            ("th32ProcessID", wintypes.DWORD),
            ("th32DefaultHeapID", ctypes.POINTER(ctypes.c_ulong)),
            ("th32ModuleID", wintypes.DWORD), ("cntThreads", wintypes.DWORD),
            ("th32ParentProcessID", wintypes.DWORD),
            ("pcPriClassBase", ctypes.c_long), ("dwFlags", wintypes.DWORD),
            ("szExeFile", ctypes.c_char * 260),
        ]

    k = ctypes.windll.kernel32
    snap = k.CreateToolhelp32Snapshot(TH32CS_SNAPPROCESS, 0)
    children = {}
    try:
        e = PROCESSENTRY32()
        e.dwSize = ctypes.sizeof(PROCESSENTRY32)
        ok = k.Process32First(snap, ctypes.byref(e))
        while ok:
            children.setdefault(int(e.th32ParentProcessID), []).append(
                int(e.th32ProcessID))
            ok = k.Process32Next(snap, ctypes.byref(e))
    except Exception as e:
        _log(f"process tree scan failed: {e}")
    finally:
        try:
            k.CloseHandle(snap)
        except Exception:
            pass

    out = []
    frontier = [os.getpid()]
    for _ in range(max(1, max_depth)):
        nxt = []
        for p in frontier:
            for c in children.get(p, []):
                if c not in out:
                    out.append(c)
                    nxt.append(c)
        if not nxt:
            break
        frontier = nxt
    return out


def real_window_rect(pids) -> "tuple | None":
    """REAL (l,t,w,h) in PHYSICAL px of a visible top-level browser window of `pids`.

    Why this exists (task 12.27, found during the round-10 review): the CDP
    read-back reports what Chromium BELIEVES the bounds are. In one observed run the
    read-back said 1025x721 logical (=> 1281x901 physical) while the real window was
    still Chromium's 1296x808 default = 1620x1010 physical, i.e. 324px off a 2560px
    screen. Only the OS rect is evidence. Returns None when nothing matches (never
    raises): a missing measurement must not break placement.
    """
    if os.name != "nt" or not pids:
        return None
    # Round-11 review: this claims PHYSICAL pixels, so it must not merely assume the
    # process is DPI-aware (today's call order guarantees it, but nothing here
    # enforced it -- and a virtualized reading compared against physical
    # expectations would report a silent false "matches").
    # Round-12 review then showed the guard was not enough on its own: if BOTH DPI
    # APIs fail, _DPI_INIT_DONE stays False and this function still returned a
    # (virtualized) rect that callers printed as "physical". Fail closed instead.
    if not _DPI_INIT_DONE:
        _make_dpi_aware()
    if not _DPI_INIT_DONE:
        _log("real_window_rect: refusing to measure -- this process is not DPI-aware, "
             "so any rect read now would be VIRTUALIZED, not physical")
        return None
    import ctypes
    from ctypes import wintypes
    user32 = ctypes.windll.user32

    class RECT(ctypes.Structure):
        _fields_ = [("left", ctypes.c_long), ("top", ctypes.c_long),
                    ("right", ctypes.c_long), ("bottom", ctypes.c_long)]

    wanted = set(int(p) for p in pids)
    found = []
    CB = ctypes.WINFUNCTYPE(ctypes.c_bool, wintypes.HWND, wintypes.LPARAM)

    def _cb(hwnd, _l):
        try:
            if not user32.IsWindowVisible(hwnd):
                return True
            pid = wintypes.DWORD()
            user32.GetWindowThreadProcessId(hwnd, ctypes.byref(pid))
            if int(pid.value) not in wanted:
                return True
            cls = ctypes.create_unicode_buffer(256)
            user32.GetClassNameW(hwnd, cls, 256)
            if cls.value != "Chrome_WidgetWin_1":
                return True
            r = RECT()
            if not user32.GetWindowRect(hwnd, ctypes.byref(r)):
                return True
            w, h = r.right - r.left, r.bottom - r.top
            if w > 200 and h > 200:
                found.append((r.left, r.top, w, h))
        except Exception:
            pass
        return True

    try:
        user32.EnumWindows(CB(_cb), 0)
    except Exception as e:
        _log(f"os window enumeration failed: {e}")
        return None
    return found[0] if found else None


# NOTE: there is no cap on how many times a drifted window may be re-pinned (see
# plan_rect_check). The counter below exists only to LABEL each repair in the log.


def classify_rect_check(expected_logical, scale, real_rect):
    """One-shot classification of a real-window check (pure, testable).

    Returns (status, why), status one of:
      "match"    - the OS rect agrees with what we pinned
      "mismatch" - it drifted
      "unknown"  - no measurement; MUST NOT be treated as drift
    """
    if not real_rect:
        return ("unknown", "no measurement")
    bad, why = os_rect_mismatch(expected_logical, scale, real_rect)
    return ("mismatch" if bad else "match", why)


def plan_rect_check(status):
    """What to do about a check result (pure, testable). Returns:
      "ok"     - nothing to do
      "repin"  - drifted -> re-pin
      "skip"   - unknown; a MISSING measurement must never be read as drift

    There is deliberately NO session cap on re-pins. An earlier version stopped after
    two and only warned; a product review showed that strands the real window at
    Chromium's default size (1620x1010 => 324px off-screen) for the rest of the
    persistent worker's life once a third drift happens. There is no loop to bound:
    one check runs per navigation-class op, so at most one re-pin can occur per op.
    What matters is whether the re-pin WORKED -- describe_repin_outcome measures that.
    """
    if status == "match":
        return "ok"
    if status == "unknown":
        return "skip"
    return "repin"


def describe_repin_outcome(expected_logical, scale, after_rect):
    """Log text for what a re-pin actually achieved (pure, testable).

    A re-pin that is never re-measured is just a claim: in the first live run that
    exercised task 12.33 the log ended at "re-pinning (1/2)" with no evidence about
    whether it worked. Never report a repair without measuring the result.
    """
    if not after_rect:
        return "not measurable after re-pin"
    bad, why = os_rect_mismatch(expected_logical, scale, after_rect)
    return ("STILL MISMATCHED: " + why) if bad else "now matches"


def os_rect_mismatch(expected_logical, scale, real_rect, tol=8):
    """Does the OS-measured rect disagree with what CDP claimed? (pure, testable)

    expected_logical is the CDP/logical-space rect we pinned; real_rect is the
    physical rect Windows reports. Returns (bool, str) -- the string is the reason,
    so the caller can log WHY it re-pins.
    """
    if not expected_logical or not real_rect:
        return (False, "no measurement")
    el, et, ew, eh = expected_logical
    rl, rt, rw, rh = real_rect
    exp_w = int(round(ew * scale))
    exp_h = int(round(eh * scale))
    if abs(rw - exp_w) > tol or abs(rh - exp_h) > tol:
        return (True, "size {}x{} vs expected {}x{} physical".format(
            rw, rh, exp_w, exp_h))
    if abs(rl - int(round(el * scale))) > tol or abs(rt - int(round(et * scale))) > tol:
        return (True, "position {},{} vs expected {},{} physical".format(
            rl, rt, int(round(el * scale)), int(round(et * scale))))
    return (False, "matches")


def _get_work_area() -> "tuple | None":
    """Primary monitor work area (taskbar excluded) via SystemParametersInfoW.

    DPI-aware first, so the result is in the same (physical) space as the app
    rect handed over by --app-rect -- see _make_dpi_aware.
    """
    _make_dpi_aware()
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
      "beside"       - a FULL-SIZE window fits clear of the app (no overlap)
      "normal"       - full-size window at the right edge; overlaps the app, but
                       leaves its left portion visible. One screen cannot hold a
                       1600px app and a browser window side by side, so this is
                       the case that must still look like a browser.
    The returned rect is always fully inside work_area (both axes are clamped).
    Aspect >= 1.0 is only guaranteed on a work area at least PLACEMENT_MIN_W
    (1000px) wide: on a narrower screen the width is capped by the screen, so a
    520x900 work area still yields a tall strip. The width/height floors below
    are what makes the "reads as a browser" oracle true for normal screens.
    """
    if not work_area:
        return (None, None, None, None, "no-work-area")

    wl, wt, ww, wh = work_area

    # A normal browser window, clamped to the work area. NOT "never a strip": on a
    # work area narrower than PLACEMENT_MIN_W the width is capped by the screen, so
    # e.g. a 520x900 work area still yields a 520px-wide (strip) window. See the
    # docstring, which the round-10 review made match this.
    w = min(min(PLACEMENT_NORMAL_W, ww), max(PLACEMENT_MIN_W, ww - PLACEMENT_EDGE_PAD * 2))
    h = min(min(PLACEMENT_NORMAL_H, wh), max(PLACEMENT_MIN_H, wh - PLACEMENT_EDGE_PAD * 2))
    w = max(1, min(w, ww))
    h = max(1, min(h, wh))

    def _inside(x, y):
        # Task 12.18(4): the docstring promises "always fully inside work_area", so
        # clamp BOTH axes here -- y previously got the padding added unclamped, which
        # pushed the bottom edge out of short work areas.
        return (max(wl, min(x, wl + ww - w)), max(wt, min(y, wt + wh - h)))

    if app_rect:
        al, _at, aw, _ah = app_rect
        rx = al + aw + PLACEMENT_GAP_PX          # first x clear of the app, to its right
        # Task 12.18(2): rx must also be inside the work area -- a window whose right
        # edge lies left of the origin would otherwise yield a negative x.
        if rx >= wl and rx + w <= wl + ww:
            bx, by = _inside(rx, wt + PLACEMENT_EDGE_PAD)
            return (bx, by, w, h, "beside")
        lx = al - PLACEMENT_GAP_PX               # last x clear of the app, to its left
        # Task 12.18(3): test the room against the SAME constant used as the anchor.
        # Using the gap here while anchoring on EDGE_PAD let the window overlap the
        # app by up to 8px while still reporting "beside" (which promises no overlap).
        if lx >= wl + PLACEMENT_EDGE_PAD + w:
            bx, by = _inside(wl + PLACEMENT_EDGE_PAD, wt + PLACEMENT_EDGE_PAD)
            return (bx, by, w, h, "beside")

    # No room for a full-size window beside the app: stay full-size and let it
    # overlap, anchored to the right edge so the app's LEFT portion stays visible
    # (that is what stops the app from reading as "all white" -- task 12.1).
    bx, by = _inside(wl + ww - w - PLACEMENT_EDGE_PAD, wt + PLACEMENT_EDGE_PAD)
    return (bx, by, w, h, "normal")


def _placement_launch_args() -> "list":
    """Chromium flags placing the headed browser window (tasks 12.13 / 12.15).

    compute_window_bounds works in PHYSICAL pixels; Chromium reads these flags as
    LOGICAL pixels -- so convert at this boundary (see _get_dpi_scale).
    """
    if os.name != "nt":
        return []
    x, y, w, h, mode = compute_window_bounds(_APP_RECT, _get_work_area())
    if mode == "no-work-area" or x is None:
        _log("window placement: skipped (work area unknown)")
        return []
    lx, ly, lw, lh = _to_logical((x, y, w, h))
    if mode == "normal":
        # This branch once tested "overlap" -- the mode name that 12.15 renamed to
        # "normal" -- so this honest disclosure had silently stopped printing while
        # the task record still cited it as evidence.
        _log("window placement: mode=normal -- no clear side fits a full-size "
             "window, so the browser OVERLAPS the app window (kept fully "
             "on-screen, app's left side left visible)")
    _log("window placement: mode={} physical={},{} {}x{} -> logical={},{} {}x{}"
         .format(mode, x, y, w, h, lx, ly, lw, lh))
    return [f"--window-position={lx},{ly}", f"--window-size={lw},{lh}"]


def reconcile_window_bounds(actual, work_area, apply):
    """Move Chromium's ACTUAL bounds back inside work_area, then VERIFY the result.

    Pure except for the injected `apply(left, top, width, height)` callback, which
    performs one CDP setWindowBounds round-trip and returns the bounds Chromium
    reports afterwards. Extracted from BrowserSession._apply_window_bounds so the
    failure branches are unit-testable WITHOUT a browser (task 12.24(7)): the bug
    class here is a repair that quietly does nothing while the log announces
    success, which is exactly what a read-back-only check cannot see.

    Returns (bounds, status, detail). status is one of:
      "no-op"       - nothing usable reported; nothing was checked
      "too-large"   - Chromium's rect is LARGER than the work area, so no repair
                      can put it fully on-screen; repairing would be a lie
      "ok"          - already inside; no CDP round-trip was made
      "repaired"    - was outside, moved back, and the move was verified
      "unrepaired"  - a repair was attempted but the final rect is STILL outside
    detail carries the numbers the caller logs for that status.
    """
    if not work_area or not actual:
        return actual, "no-op", None
    wl, wt, ww, wh = work_area
    aw, ah = actual.get("width"), actual.get("height")
    if not aw or not ah:
        return actual, "no-op", None
    ax = actual.get("left")
    ay = actual.get("top")
    ax = 0 if ax is None else ax
    ay = 0 if ay is None else ay
    if aw > ww or ah > wh:
        return actual, "too-large", (aw, ah, ww, wh)
    nx = max(wl, min(ax, wl + ww - aw))
    ny = max(wt, min(ay, wt + wh - ah))
    moved = (nx, ny) != (ax, ay)
    b = apply(nx, ny, aw, ah) if moved else actual
    fx, fy = b.get("left", ax), b.get("top", ay)
    fw, fh = b.get("width", aw), b.get("height", ah)
    if fx < wl or fy < wt or (fx + fw) > (wl + ww) or (fy + fh) > (wt + wh):
        return b, "unrepaired", (fx, fy, fw, fh, wl, wt, ww, wh)
    return b, ("repaired" if moved else "ok"), (fx, fy, fw, fh)


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
        # VACUITY, disclosed (round-10 review): _raise_count and _popup_closed have
        # NO writer anywhere in this file -- they are initialised here and read into
        # every record -- so both are structurally always 0. They are tripwires
        # only. The enforceable stay-hidden guard lives in
        # test/integration/browser_worker_test.dart and is TWO checks (round-11
        # review corrected this wording): 6 bring-to-front APIs are scanned across
        # every .cpp/.h in sidecar/src, and this script is scanned for a
        # bring-to-front call of its own. (Do not spell that call out literally in
        # this file: the scan is a substring check and a comment would trip it --
        # observed by the writer of this line while running the suite.)
        # _popup_closed is additionally dead under design 甲, which FOLLOWS
        # browser-opened pages instead of closing them (see _install_page_handler).
        self._raise_count = 0
        self._popup_closed = 0
        # Task 12.33: how many times we have already re-pinned after a DRIFT detected
        # later in the session (not the launch-time pin). Bounded on purpose.
        self._placement_repins = 0
        self._download_denied = 0
        self._permission_denied = 0
        # Design 甲 (follow new tab) counters: _browser_opened counts every page
        # the BROWSER opened (window.open / target=_blank); _adopted_tabs counts
        # how many of those the worker then FOLLOWED after a click.
        self._browser_opened = 0
        self._adopted_tabs = 0
        # Pages the browser opened WHILE a click was in flight, in the order the
        # page handler saw them. Collected only between `_collect_opened_pages =
        # True` (set for the duration of one click) and cleared at the start of
        # each click, so a page opened by a relaunch or by the user's own clicking
        # in the visible window is never mistaken for this click's popup.
        self._opened_pages = []
        self._collect_opened_pages = False
        # Per-call observability: set when a click was judged to open a new page but
        # no page registered within that click's bound. Reset before every command
        # (see the dispatch loop) so it never describes more than the current call.
        self._expected_new_tab_unfulfilled = False
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
            # Task 12.13: --window-position/--window-size are only HINTS. The
            # repeatedly-reproduced part of that measurement: this Edge build IGNORES
            # the requested SIZE (12.23's external harness: asked 1024x720 logical,
            # the freshly-created window was the 1296x808 default), which is why CDP
            # pins the bounds below. The specific pre-fix numbers once quoted here
            # (750x1232 -> 1296x808) came from a one-off script whose output did not
            # survive; the round-10 review flagged them, so they are not restated.
            # NOTE (task 12.27, round-10): even the CDP pin is not reliable on every
            # run -- see the WARNING path in _apply_window_bounds.
            # right edge of the screen. CDP is authoritative, so pin it here.
            self._apply_window_bounds()
            self._install_page_handler()
            return None
        except Exception as e:
            _log(f"launch failed: {e}")
            self._teardown()
            return f"browser launch failed: {e}"

    def _apply_window_bounds(self) -> None:
        """Pin the OS window bounds, then verify what Chromium ACTUALLY applied.

        Units: compute_window_bounds works in PHYSICAL pixels; Chromium and CDP
        speak LOGICAL pixels, so every value crossing that boundary is divided by
        the DPI scale (see _get_dpi_scale). Getting this wrong put the real window
        620px off a 2560px screen while the CDP read-back happily echoed the
        request -- so the read-back alone is NOT evidence. What counts is the OS
        window rect, which the observer measures independently.

        Never raises or brings to front.
        """
        if _APP_RECT is None:
            return
        work = _get_work_area_logical()
        x, y, w, h, _mode = compute_window_bounds(_APP_RECT, _get_work_area())
        if x is None:
            return
        lx, ly, lw, lh = _to_logical((x, y, w, h))
        try:
            session = self._context.new_cdp_session(self._page)
            wid = session.send("Browser.getWindowForTarget")["windowId"]

            def apply(bx, by, bw, bh):
                session.send("Browser.setWindowBounds", {
                    "windowId": wid,
                    "bounds": {"left": bx, "top": by, "width": bw, "height": bh,
                               "windowState": "normal"},
                })
                return session.send("Browser.getWindowForTarget").get("bounds", {})

            b = apply(lx, ly, lw, lh)
            _log("window placement: logical requested={},{} {}x{} actual={},{} {}x{}"
                 .format(lx, ly, lw, lh, b.get("left"), b.get("top"),
                         b.get("width"), b.get("height")))

            # Keep the REAL (logical) rect inside the logical work area -- Chromium
            # can return something other than what was asked. The repair+verify
            # logic lives in reconcile_window_bounds so its failure branches are
            # unit-testable (task 12.24(7)).
            b, status, detail = reconcile_window_bounds(b, work, apply)
            if status == "too-large":
                _log("window placement: WARNING - Chromium reports {}x{}, larger "
                     "than the {}x{} logical work area; it cannot be fully "
                     "on-screen".format(*detail))
            elif status == "unrepaired":
                _log("window placement: WARNING - final rect {},{} {}x{} is "
                     "still outside the logical work area {},{} {}x{}".format(
                         *detail))
            elif status in ("ok", "repaired"):
                _log("window placement: verified final logical rect {},{} {}x{} "
                     "inside the logical work area".format(*detail))
            elif status == "no-op":
                # Round-10 review: this path used to log NOTHING, so a CDP read-back
                # that came back unusable left no trace at all -- neither verified
                # nor warned. Say so explicitly.
                _log("window placement: WARNING - Chromium reported no usable bounds "
                     "after the CDP pin; the placement is NOT verified")

            # Task 12.27 (round-10): the CDP read-back is NOT evidence. Measure the
            # real OS window and re-pin once if it disagrees -- one observed run read
            # back 1025x721 logical while the window was still 1620x1010 physical.
            # The window may appear a moment after launch, so retry the measurement.
            try:
                scale = _get_dpi_scale()
                real = None
                for _attempt in range(5):
                    real = real_window_rect(child_process_pids())
                    if real:
                        break
                    time.sleep(0.4)
                if real:
                    _log("window placement: OS-measured {} rect {},{} {}x{}"
                         .format(_coord_space_label(), *real))
                    bad, why = os_rect_mismatch((lx, ly, lw, lh), scale, real)
                    if bad:
                        _log(f"window placement: WARNING - {why}; re-pinning once")
                        b = apply(lx, ly, lw, lh)
                        time.sleep(0.5)
                        real2 = None
                        for _attempt in range(5):
                            real2 = real_window_rect(child_process_pids())
                            if real2:
                                break
                            time.sleep(0.4)
                        if real2:
                            bad2, why2 = os_rect_mismatch((lx, ly, lw, lh), scale, real2)
                            _log("window placement: OS-measured {} rect after "
                                 "re-pin {},{} {}x{} ({})".format(
                                     _coord_space_label(),
                                     real2[0], real2[1], real2[2], real2[3],
                                     "STILL MISMATCHED: " + why2 if bad2 else "matches"))
                        else:
                            _log("window placement: WARNING - could not re-measure the "
                                 "OS rect after re-pinning")
                else:
                    _log("window placement: WARNING - OS rect not measurable (no "
                         "descendant browser window found after 5 tries); the "
                         "placement is verified ONLY by the CDP read-back")
            except Exception as e:
                _log(f"window placement: OS rect check failed: {e}")
            session.detach()
        except Exception as e:
            _log(f"window placement via CDP failed (launch flags only): {e}")

    def _recheck_window_bounds(self, where: str) -> None:
        """Re-measure the REAL OS window rect and re-pin if it drifted (task 12.33).

        The launch-time check is not enough. Two facts force this:
          - one observed run had the window at the wrong size for its whole life while
            the CDP read-back reported the requested size (task 12.27);
          - a window manager can re-apply a "normal" size LATER (first paint, session
            restore), which a one-shot check at launch can never see.
        Cost is one EnumWindows pass, so it runs after every navigation-class op.
        Never raises; never brings the window to front.
        """
        if _APP_RECT is None or self._page is None:
            return
        try:
            x, y, w, h, _mode = compute_window_bounds(_APP_RECT, _get_work_area())
            if x is None:
                return
            lx, ly, lw, lh = _to_logical((x, y, w, h))
            scale = _get_dpi_scale()
            status, why = classify_rect_check(
                (lx, ly, lw, lh), scale, real_window_rect(child_process_pids()))
            action = plan_rect_check(status)
            if action == "repin":
                self._placement_repins += 1
                _log("window rect drift after {}: {}; re-pinning (repair #{})".format(
                    where, why, self._placement_repins))
                session = self._context.new_cdp_session(self._page)
                wid = session.send("Browser.getWindowForTarget")["windowId"]
                session.send("Browser.setWindowBounds", {
                    "windowId": wid,
                    "bounds": {"left": lx, "top": ly, "width": lw, "height": lh,
                               "windowState": "normal"},
                })
                session.detach()
                # Verify the re-pin instead of asserting it (see the function doc).
                time.sleep(0.4)
                after = real_window_rect(child_process_pids())
                _log("window rect after re-pin ({}): {},{} {}x{} -> {}".format(
                    where, after[0] if after else '-', after[1] if after else '-',
                    after[2] if after else '-', after[3] if after else '-',
                    describe_repin_outcome((lx, ly, lw, lh), scale, after)))
            elif action == "skip":
                _log("window rect check after {}: not measurable ({})".format(where, why))
            # "ok" stays silent: a healthy session must not spam the log.
        except Exception as e:
            _log(f"window rect check after {where} failed: {e}")

    def _install_page_handler(self) -> None:
        def on_page(page) -> None:
            # Design 甲 (follow new tab): the worker does NOT close browser-opened
            # pages (a target=_blank result / window.open popup) — the AI reads the
            # real landing page a click produced. Two separate jobs live around this
            # handler:
            #   • RECORD (here): while a click is in flight, put the page on the
            #     session's _opened_pages list. That list is how _handle_click finds
            #     a page that registered DURING the click: its event is already
            #     flushed by the time page.click() returns, so a waiter attached
            #     afterwards would never see it (and would sit out the whole window).
            #   • FOLLOW (in _handle_click): take that page, make it the active page,
            #     wait for it to load and snapshot it; _adopted_tabs counts those.
            # The COUNT below (_browser_opened) is observability only, and counts
            # only pages with a real opener (window.open / target=_blank): a
            # programmatic context.new_page() — the initial page OR a recreated main
            # page — has a null opener (verified). The RECORD above must NOT reuse
            # that filter: a rel=noopener popup has a null opener too, and it is
            # still a browser-opened page the AI must be able to read.
            if self._page is not None and page is self._page:
                return
            if self._collect_opened_pages:
                self._opened_pages.append(page)
            try:
                if page.opener() is None:
                    return
                self._browser_opened += 1
                _log(f"browser-opened page counted (opened={self._browser_opened})")
            except Exception:
                pass

        self._context.on("page", on_page)

    def _take_opened_page(self):
        """First still-open page the browser opened during the current click."""
        while self._opened_pages:
            candidate = self._opened_pages.pop(0)
            try:
                if not candidate.is_closed():
                    return candidate
            except Exception:
                continue
        return None

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
        # Task 12.33: window managers can re-apply a size on the first real paint.
        self._recheck_window_bounds("navigate")
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

    def _click_opens_new_page(self, page, selector: str) -> bool:
        """Does the clicked element declare a new-window target? (design D1)

        BOUNDED AND NON-WAITING ON PURPOSE. This worker never sets Playwright's
        default timeout, so a waiting read (page.get_attribute) would inherit the
        30s default; pre-check 30s + click 30s = 60s, which is exactly the
        sidecar's BROWSER_RESPONSE_TIMEOUT_MS kill limit (a timeout there kills
        the worker), and the test-side 45s read budget would return "worker
        response timeout" first. page.evaluate takes no timeout and does NOT wait
        for the element (a missing selector yields null immediately).

        ANY failure — evaluate error, page gone, unexpected value — is treated as
        "does not open a new page", so the pre-check can never fail the click.
        `_self` / `_top` / `_parent` are in-place targets; `_blank`, `_new` and a
        named window target open (or reuse) another page and get the longer wait.
        """
        try:
            target = page.evaluate(
                "sel => { const el = document.querySelector(sel);"
                " return el ? (el.getAttribute('target') || '') : null; }",
                selector,
            )
        except Exception as e:
            _log(f"click pre-check failed ({e.__class__.__name__}: {e})"
                 " -> treating this click as in-place")
            return False
        if not isinstance(target, str) or not target.strip():
            return False
        return target.strip().lower() not in ("_self", "_top", "_parent")

    def _handle_click(self, req: dict) -> dict:
        page = self._launch_for_op()
        if isinstance(page, dict):
            return page
        selector = req.get("selector", "")
        if not selector:
            return {"ok": False, "error": "click: selector is required"}
        expects_new_page = self._click_opens_new_page(page, selector)
        wait_sec = NEW_TAB_WAIT_SEC if expects_new_page else NEW_PAGE_WAIT_SEC
        _log(f"click pre-check: selector={selector!r} opens_new_page={expects_new_page} "
             f"wait={wait_sec}s")
        # Design 甲 (follow new tab): a click on a target=_blank result / window.open
        # popup opens a NEW page, and we FOLLOW it (make it active, wait for load) so
        # the AI reads the REAL landing page; an in-place click keeps the current
        # page. This replaces the single-tab close (which dropped the landing page).
        #
        # TAKING THE PAGE IS THREE STEPS, and all three are needed:
        #   ① the session's page handler (see _install_page_handler) records every
        #      page the browser opens while a click is in flight. Checking that list
        #      FIRST is an ordering guard: Playwright attaches event listeners when
        #      you ask for them, so IF a page's event were dispatched before
        #      page.click() returned, a waiter attached afterwards would never see
        #      it and would sit out the whole window (and, for a judged new-tab
        #      click, be recorded as "expected but not observed"). Measured locally
        #      (task 2.2): the synchronous target=_blank page event arrives AFTER
        #      click() returns, so this guard is not the common path here — it is
        #      kept because it costs almost nothing and covers the other order.
        #   ② only when that list is empty do we wait, bounded, for a page event —
        #      that is the page which registers AFTER the click returned (the
        #      1.5s/3s cases).
        #   ③ after the wait expires the list is checked once more, so a page that
        #      did register inside the window is never reported as unfulfilled.
        # The wait is counted from AFTER the click returns: the old code wrapped the
        # click in context.expect_page(), whose window started before the click, so
        # a slow click ate the popup budget.
        self._opened_pages.clear()
        self._collect_opened_pages = True
        click_err = None
        new_page = None
        try:
            try:
                page.click(selector, timeout=OP_TIMEOUT_SEC * 1000)
            except PWTimeout as e:
                click_err = {"ok": False, "error": f"click: timed out waiting for {selector}: {e}"}
            except Exception as e:
                click_err = {"ok": False, "error": f"click: {e}"}
            if click_err is None:
                new_page = self._take_opened_page()
                if new_page is None:
                    try:
                        self._context.wait_for_event("page", timeout=wait_sec * 1000)
                    except PWTimeout:
                        # No page event inside the window: either the click navigated
                        # in-place, or the page is still on its way and registers too
                        # late. Not a click failure either way.
                        pass
                    new_page = self._take_opened_page()
        finally:
            self._collect_opened_pages = False
        if click_err is not None:
            return click_err
        if new_page is not None and not new_page.is_closed():
            self._page = new_page
            self._adopted_tabs += 1
            self._wait_for_page_ready(new_page)
            page = new_page
            _log(f"followed new tab (adopted={self._adopted_tabs})")
        elif expects_new_page:
            # The pre-click check judged this click as opening a page and none
            # registered within its bound. NOT a failure (the user may have blocked
            # the popup, or the page cancelled the default action) and never
            # model-visible — it is recorded on the observability channel only, so a
            # later reader can tell "this click waited and found nothing" apart from
            # "this click was never expected to open a page".
            self._expected_new_tab_unfulfilled = True
            _log("expected a new tab but none registered within "
                 f"{wait_sec}s (recorded, not a failure)")
        # A click may itself navigate the page; that is the AI's own action, so
        # the resulting URL + content hash become the new expected state.
        # Task 12.33: navigation-class op -> re-check the real window rect.
        self._recheck_window_bounds("click")
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
        # A product review proved this op can ALSO open a page (a form input whose
        # submit opens a new tab) and that the real window then drifts exactly like a
        # click -- with no rect line at all, because this call site was missing.
        self._recheck_window_bounds("type")
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
            "expected_new_tab_unfulfilled": session._expected_new_tab_unfulfilled,
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
            # The per-call record must describe THIS call only: reset the
            # "expected a new tab but did not observe one" flag before every
            # command, so a click that did not wait out its bound cannot leave the
            # flag true on the records of later calls in this long-lived process.
            session._expected_new_tab_unfulfilled = False
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
