"""End-to-end check for task 12.33: does the worker DETECT a real window drift and
does its RE-PIN actually take effect?

Why this exists
---------------
The drift (Chromium/window-manager re-applying a default size) only shows up
occasionally in real runs -- it has been observed twice, both times right after a
`click`. Waiting for it to happen naturally would leave "does the re-pin work?"
unanswered forever. So this harness FORCES the drift: it spawns the real worker,
lets it place the window, then resizes the real OS window from the outside with
SetWindowPos, then asks the worker to navigate (a navigation-class op, which is
where the check runs).

It is an external measurement: the window rect is read from THIS process (DPI-aware),
never from the worker's own CDP read-back (see docs/rejected-approaches.md #5).

Usage:  python tools/verify_worker_rect_drift.py [--url URL]
Exit 0 only if every assertion holds; prints one PASS/FAIL line per step.
"""

from __future__ import annotations

import ctypes
import io
import json
import os
import subprocess
import sys
import time
from ctypes import wintypes

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
WORKER = os.path.join(ROOT, "scripts", "browser_worker.py")
APP_RECT = "12,12,1600,900"

sys.path.insert(0, os.path.join(ROOT, "scripts"))
import browser_worker as bw  # noqa: E402  (the PRODUCT decides the expected geometry)


def _expected_physical():
    """Expected physical size, DERIVED FROM THE PRODUCT (not a machine literal).

    A product review pointed out that hard-coding 1280x900 made this harness report
    FAIL on any smaller work area while the product was behaving correctly.
    """
    bw._make_dpi_aware()
    x, y, w, h, _mode = bw.compute_window_bounds((12, 12, 1600, 900), bw._get_work_area())
    lx, ly, lw, lh = bw._to_logical((x, y, w, h))
    s = bw._get_dpi_scale()
    return (int(round(lw * s)), int(round(lh * s)))


EXPECT_SIZE = _expected_physical()
# Chromium's default "normal" size is 1296x808 LOGICAL; that is what it re-applies on
# a new page. Expressed in physical pixels so the forced drift matches reality.
CHROMIUM_DEFAULT_LOGICAL = (1296, 808)
DRIFT_SIZE = tuple(int(round(v * bw._get_dpi_scale())) for v in CHROMIUM_DEFAULT_LOGICAL)

user32 = ctypes.windll.user32
user32.SetProcessDPIAware()

RESULTS = []


def summary_exit_code() -> int:
    return 0 if all(ok for _n, ok, _d in RESULTS) else 1


def check(name: str, ok: bool, detail: str) -> None:
    RESULTS.append((name, ok, detail))
    print("{:5} {:38} {}".format("PASS" if ok else "FAIL", name, detail), flush=True)


class RECT(ctypes.Structure):
    _fields_ = [("left", ctypes.c_long), ("top", ctypes.c_long),
                ("right", ctypes.c_long), ("bottom", ctypes.c_long)]


def _child_pids(root_pid: int):
    """Descendant PIDs of `root_pid` (the worker spawns the browser via a launcher)."""
    TH32CS_SNAPPROCESS = 0x00000002

    class PE32(ctypes.Structure):
        _fields_ = [("dwSize", wintypes.DWORD), ("cntUsage", wintypes.DWORD),
                    ("th32ProcessID", wintypes.DWORD),
                    ("th32DefaultHeapID", ctypes.POINTER(ctypes.c_ulong)),
                    ("th32ModuleID", wintypes.DWORD), ("cntThreads", wintypes.DWORD),
                    ("th32ParentProcessID", wintypes.DWORD),
                    ("pcPriClassBase", ctypes.c_long), ("dwFlags", wintypes.DWORD),
                    ("szExeFile", ctypes.c_char * 260)]
    k = ctypes.windll.kernel32
    snap = k.CreateToolhelp32Snapshot(TH32CS_SNAPPROCESS, 0)
    children = {}
    try:
        e = PE32()
        e.dwSize = ctypes.sizeof(PE32)
        ok = k.Process32First(snap, ctypes.byref(e))
        while ok:
            children.setdefault(int(e.th32ParentProcessID), []).append(
                int(e.th32ProcessID))
            ok = k.Process32Next(snap, ctypes.byref(e))
    finally:
        k.CloseHandle(snap)
    out, frontier = [], [root_pid]
    for _ in range(4):
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


def browser_window(root_pid: int):
    """HWND of the visible Chrome_WidgetWin_1 owned by a descendant of root_pid."""
    wanted = set(_child_pids(root_pid))
    found = []
    CB = ctypes.WINFUNCTYPE(ctypes.c_bool, wintypes.HWND, wintypes.LPARAM)

    def cb(hwnd, _l):
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
        if (r.right - r.left) > 200 and (r.bottom - r.top) > 200:
            found.append(hwnd)
        return True

    user32.EnumWindows(CB(cb), 0)
    return found[0] if found else None


def rect_of(hwnd):
    r = RECT()
    if not user32.GetWindowRect(hwnd, ctypes.byref(r)):
        return None
    return (r.left, r.top, r.right - r.left, r.bottom - r.top)


def main() -> int:
    url = "about:blank"
    if "--url" in sys.argv:
        url = sys.argv[sys.argv.index("--url") + 1]
    natural = "--natural" in sys.argv

    env = dict(os.environ)
    env["PYTHONIOENCODING"] = "utf-8"
    proc = subprocess.Popen(
        [sys.executable, WORKER, "--app-rect=" + APP_RECT],
        stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
        cwd=ROOT, env=env, text=True, encoding="utf-8", errors="replace",
        bufsize=1)

    def send(req):
        proc.stdin.write(json.dumps(req) + "\n")
        proc.stdin.flush()
        line = proc.stdout.readline()
        return json.loads(line) if line.strip() else None

    try:
        opened = send({"cmd": "open"})
        check("worker opened a session", bool(opened and opened.get("ok")),
              "response ok=%s" % (opened or {}).get("ok"))

        hwnd = None
        base = None
        for _ in range(20):
            hwnd = browser_window(proc.pid)
            if hwnd:
                base = rect_of(hwnd)
                if base and base[2] > 200:
                    break
            time.sleep(0.5)
        check("real window found (DPI-aware reader)", base is not None,
              "rect=%s" % (base,))
        if base is None:
            return 1
        check("launch placement is the expected size",
              (base[2], base[3]) == EXPECT_SIZE,
              "measured %dx%d, expected %dx%d" % (base[2], base[3], *EXPECT_SIZE))

        # FORCE the drift: resize the real window from the outside.
        SWP_NOZORDER, SWP_NOACTIVATE = 0x0004, 0x0010
        user32.SetWindowPos(hwnd, 0, base[0], base[1], DRIFT_SIZE[0], DRIFT_SIZE[1],
                            SWP_NOZORDER | SWP_NOACTIVATE)
        time.sleep(0.6)
        drifted = rect_of(hwnd)
        check("drift was actually forced",
              drifted is not None and (drifted[2], drifted[3]) == DRIFT_SIZE,
              "rect=%s" % (drifted,))

        if natural:
            # ROOT-CAUSE PROBE. Both real observations of the drift happened right
            # after a `click`, and design 甲 FOLLOWS a page the browser opens. Does
            # following a new tab make Edge re-apply its default window size?
            #
            # A product review showed the first version of this branch was a FALSE
            # GREEN: the forced drift above had already left the window off-size, so
            # any off-size sample "confirmed" the click -- even with the whole feature
            # neutralised. So here we do NOT force anything, we require the window to
            # be at the expected size first, and we require the WORKER'S OWN log to
            # attribute a drift to the click.
            import threading
            send({"cmd": "navigate", "url": "about:blank"})
            time.sleep(0.5)
            before = rect_of(hwnd)
            check("baseline is the expected size BEFORE the natural probe",
                  before is not None and (before[2], before[3]) == EXPECT_SIZE,
                  "rect=%s expected %dx%d" % (before, *EXPECT_SIZE))

            html = ('data:text/html,<a id="go" target="_blank" '
                    'href="data:text/html,landing">open</a>')
            send({"cmd": "navigate", "url": html})
            samples, stop = [], threading.Event()

            def sampler():
                while not stop.is_set():
                    r = rect_of(hwnd)
                    if r:
                        samples.append((r[2], r[3]))
                    time.sleep(0.05)

            t = threading.Thread(target=sampler, daemon=True)
            t.start()
            send({"cmd": "click", "selector": "#go"})
            time.sleep(0.4)
            stop.set()
            t.join(timeout=1)
            off = [s for s in samples if s != EXPECT_SIZE]

            proc.stdin.close()
            time.sleep(0.6)
            err = proc.stderr.read() or ""
            attributed = "rect drift after click" in err
            check("following a new tab resizes the real window (root-cause probe)",
                  bool(off),
                  "off-size samples=%s; distinct sizes seen=%s"
                  % (off[:6], sorted(set(samples))))
            check("the WORKER attributed that drift to the click",
                  attributed,
                  "worker logged 'rect drift after click'" if attributed
                  else "worker log has no click-attributed drift")
            odd = [s for s in off if s != DRIFT_SIZE]
            check("the off-size samples are the browser default (not a stray)",
                  not odd,
                  "off-size samples are all %s" % (DRIFT_SIZE,) if not odd
                  else "unexpected sizes: %s" % (odd[:4],))
            print("\n--- worker stderr (rect lines) ---")
            for ln in err.splitlines():
                if "rect" in ln:
                    print("  " + ln)
            return summary_exit_code()
            proc.stdin.close()
            time.sleep(0.5)
            err = proc.stderr.read() or ""
            print("\n--- worker stderr (rect lines) ---")
            for ln in err.splitlines():
                if "rect" in ln:
                    print("  " + ln)
            return 0

        # A navigation-class op is where the worker re-checks.
        resp = send({"cmd": "navigate", "url": url})
        check("navigate succeeded", bool(resp and resp.get("ok")),
              "ok=%s error=%s" % ((resp or {}).get("ok"), (resp or {}).get("error", "")))

        time.sleep(0.8)
        after = rect_of(hwnd)
        check("re-pin restored the requested size",
              after is not None and (after[2], after[3]) == EXPECT_SIZE,
              "measured %s, expected %dx%d" % (after, *EXPECT_SIZE))

        proc.stdin.close()
        time.sleep(0.7)
        err = proc.stderr.read() or ""
        check("worker logged the drift it detected",
              "rect drift after navigate" in err,
              "log line present" if "rect drift after navigate" in err
              else "MISSING 'rect drift after navigate' in worker log")
        check("worker MEASURED the re-pin result (not just claimed it)",
              "window rect after re-pin" in err,
              "log line present" if "window rect after re-pin" in err
              else "MISSING 'window rect after re-pin' in worker log")
        check("the measured re-pin result says it matched",
              "now matches" in err,
              "log says 'now matches'" if "now matches" in err
              else "log does not say 'now matches'")
        print("\n--- worker stderr (rect lines) ---")
        for ln in err.splitlines():
            if "rect" in ln:
                print("  " + ln)
        return 0 if all(ok for _n, ok, _d in RESULTS) else 1
    finally:
        try:
            proc.kill()
        except Exception:
            pass


if __name__ == "__main__":
    code = main()
    ok = sum(1 for _n, o, _d in RESULTS if o)
    print("\n%d/%d checks passed" % (ok, len(RESULTS)))
    sys.exit(code)
