# Observe the alias_agent (Flutter) app window AND the agent-driven browser window,
# and report OCCLUSION as a directly measured quantity.
#
# Why this rewrite (task 12.16, found by the round-8 adversarial review):
# the previous version judged "app fully visible" by counting near-white pixels
# (R,G,B all > 245). That is structurally blind to NON-WHITE occlusion: the review
# produced two frames where the browser demonstrably covered the app
# (f0557: Edge over the app's right side; f0620: the app fully covered by another
# window) yet both scored white<=1% and were counted as "fully visible". It also
# never recorded the browser's rect at all, so no live measurement of the new
# "app left >= 600px stays visible" criterion existed.
#
# Now: we enumerate the agent's own browser window (a Chrome_WidgetWin whose
# process descends from the app process), record both rects, and compute the
# intersection area directly. Near-white/colored ratios are kept as auxiliary
# signal only, never as the verdict.
#
# Also fixed: each run writes its OWN capture-<stamp>.log. The review found two
# observer instances concurrently appending to one capture.log, interleaving rows.
#
# NOTE: FindWindow(null, title) does NOT work from PowerShell ($null marshals as
# an empty string, so the class filter never matches). We enumerate windows and
# match on PID + window class instead.
#
# ASCII only, on purpose.
param(
    [int]$DurationSec = 700,
    [int]$IntervalMs  = 1000,
    [string]$OutDir   = "$env:TEMP\aliasagent-freeze",
    [string]$ProcName = 'alias_agent',
    [switch]$SelfTest
)

Add-Type -AssemblyName System.Drawing
Add-Type -AssemblyName System.Windows.Forms

Add-Type @"
using System;
using System.Collections.Generic;
using System.Runtime.InteropServices;
using System.Text;

public class WinScan {
    public delegate bool EnumProc(IntPtr h, IntPtr l);
    [DllImport("user32.dll")] public static extern bool EnumWindows(EnumProc cb, IntPtr l);
    [DllImport("user32.dll")] public static extern uint GetWindowThreadProcessId(IntPtr h, out uint pid);
    [DllImport("user32.dll", CharSet=CharSet.Unicode, EntryPoint="GetClassNameW")] public static extern int GetClassNameW(IntPtr h, StringBuilder s, int n);
    [DllImport("user32.dll", CharSet=CharSet.Unicode, EntryPoint="GetWindowTextW")] public static extern int GetWindowTextW(IntPtr h, StringBuilder s, int n);
    [DllImport("user32.dll")] public static extern bool IsWindowVisible(IntPtr h);
    [DllImport("user32.dll")] public static extern bool IsIconic(IntPtr h);
    [DllImport("user32.dll")] public static extern bool IsHungAppWindow(IntPtr h);
    [DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr h, out RECT r);
    // Task 12.24 / round-10: without this the process is DPI-VIRTUALIZED, so
    // GetWindowRect returns coordinates divided by the DPI scale (on this machine
    // 1.25). That silently put this instrument in a DIFFERENT coordinate space from
    // the product, which computes in PHYSICAL pixels -- a round-10 review showed the
    // "app_left_visible=1254px" this script reported was a virtualized reading of a
    // window whose real physical left edge was 1580 (1580-12 = 1568 physical,
    // 1568/1.25 = 1254). Percentages are scale-invariant, pixel lengths are not.
    [DllImport("user32.dll")] public static extern bool SetProcessDPIAware();
    [StructLayout(LayoutKind.Sequential)] public struct RECT { public int L,T,R,B; }

    public class Hit {
        public IntPtr Hwnd;
        public uint Pid;
        public string Title = "";
        public string ClassName = "";
        public bool Visible;
        public bool Iconic;
        public bool Hung;
        public int L, T, W, H;
    }

    // All top-level windows whose class starts with prefix.
    public static List<Hit> ByClassPrefix(string prefix) {
        var res = new List<Hit>();
        EnumWindows((h, l) => {
            var c = new StringBuilder(256); GetClassNameW(h, c, 256);
            if (!c.ToString().StartsWith(prefix)) return true;
            var t = new StringBuilder(256); GetWindowTextW(h, t, 256);
            RECT r; GetWindowRect(h, out r);
            uint pid; GetWindowThreadProcessId(h, out pid);
            res.Add(new Hit {
                Hwnd = h, Pid = pid, Title = t.ToString(), ClassName = c.ToString(),
                Visible = IsWindowVisible(h), Iconic = IsIconic(h), Hung = IsHungAppWindow(h),
                L = r.L, T = r.T, W = r.R - r.L, H = r.B - r.T
            });
            return true;
        }, IntPtr.Zero);
        return res;
    }

    // Every visible, non-minimized top-level window in EnumWindows order -- which
    // IS Z-order, topmost first. The caller can treat the list index as a Z-rank,
    // so "the browser sits BEHIND the app" becomes distinguishable from "the
    // browser covers the app", and ANY window (not just the agent's browser) can be
    // identified as the thing covering the app.
    public static List<Hit> AllVisible() {
        var res = new List<Hit>();
        EnumWindows((h, l) => {
            if (!IsWindowVisible(h) || IsIconic(h)) return true;
            RECT r; GetWindowRect(h, out r);
            if (r.R - r.L <= 0 || r.B - r.T <= 0) return true;
            var c = new StringBuilder(256); GetClassNameW(h, c, 256);
            var t = new StringBuilder(256); GetWindowTextW(h, t, 256);
            uint pid; GetWindowThreadProcessId(h, out pid);
            res.Add(new Hit {
                Hwnd = h, Pid = pid, Title = t.ToString(), ClassName = c.ToString(),
                Visible = true, Iconic = false, Hung = IsHungAppWindow(h),
                L = r.L, T = r.T, W = r.R - r.L, H = r.B - r.T
            });
            return true;
        }, IntPtr.Zero);
        return res;
    }
}
"@

# ---------------------------------------------------------------- pure helpers

# Intersection area of two (l,t,w,h) rects; 0 when disjoint.
function Get-OverlapArea($a, $b) {
    if (-not $a -or -not $b) { return 0 }
    $ax2 = $a[0] + $a[2]; $ay2 = $a[1] + $a[3]
    $bx2 = $b[0] + $b[2]; $by2 = $b[1] + $b[3]
    $ox = [Math]::Max(0, ([Math]::Min($ax2, $bx2) - [Math]::Max($a[0], $b[0])))
    $oy = [Math]::Max(0, ([Math]::Min($ay2, $by2) - [Math]::Max($a[1], $b[1])))
    return $ox * $oy
}

# Fraction of `target` covered by `over`. This is the verdict quantity (12.16):
# a DIRECT area measurement, unlike a near-white pixel count (which was blind to
# non-white occlusion). NOTE: the verdict metric scores ONE occluder -- the topmost
# visible window above the app that intersects it (see the main loop). That is a
# conservative bound, NOT "blind to nothing": a lower window that also covers the
# app is not added in, and a thin topmost sliver ends the scan.
function Get-OccludedPct($target, $over) {
    if (-not $target -or $target[2] -le 0 -or $target[3] -le 0) { return 0.0 }
    $area = [double]$target[2] * [double]$target[3]
    return [Math]::Round(100.0 * (Get-OverlapArea $target $over) / $area, 1)
}

# ---------------------------------------------------------------- self test

if ($SelfTest) {
    Write-Output "SELFTEST start"
    $app = @(0, 0, 1000, 800)          # area 800000
    $cases = @(
        @{ name = 'no-overlap';        over = @(1000, 0, 500, 800);  want = 0.0 },
        @{ name = 'quarter-from-left'; over = @(0, 0, 250, 800);     want = 25.0 },
        @{ name = 'half-from-right';   over = @(500, 0, 500, 800);   want = 50.0 },
        @{ name = 'full';              over = @(-50, -50, 1200, 900); want = 100.0 },
        @{ name = 'strip-600px';       over = @(600, 0, 400, 800);   want = 40.0 }
    )
    $fail = 0
    foreach ($c in $cases) {
        $got = Get-OccludedPct $app $c.over
        $ok = ([Math]::Abs($got - $c.want) -lt 0.05)
        if (-not $ok) { $fail++ }
        Write-Output ("  {0,-18} occluded={1,5}%  want={2,5}%  {3}" -f $c.name, $got, $c.want, $(if ($ok) { 'ok' } else { 'FAIL' }))
    }
    # The regression this task exists for: a NON-WHITE occluder over the app's
    # right side must report >0 occlusion. The old near-white metric returned 0.
    $reg = Get-OccludedPct $app @(500, 0, 500, 800)
    Write-Output ("  non-white-occluder occluded={0}% (old white-pixel metric would say 0%)" -f $reg)
    if ($reg -le 0) { $fail++ }
    Write-Output ("SELFTEST {0} (failures={1})" -f $(if ($fail -eq 0) { 'PASS' } else { 'FAIL' }), $fail)
    exit $(if ($fail -eq 0) { 0 } else { 1 })
}

# ---------------------------------------------------------------- ancestry

# True when $childPid descends from $rootPid (so we only ever treat the agent's
# OWN browser as the occluder, never the user's unrelated Edge windows).
function Test-DescendsFrom {
    param([int]$ChildPid, [int]$RootPid, $Snapshot)
    $cur = $ChildPid
    for ($i = 0; $i -lt 12 -and $cur -gt 0; $i++) {
        if ($cur -eq $RootPid) { return $true }
        $row = $Snapshot | Where-Object { $_.ProcessId -eq $cur } | Select-Object -First 1
        if (-not $row) { break }
        $cur = [int]$row.ParentProcessId
    }
    return $false
}

# ---------------------------------------------------------------- main loop

# Make THIS process DPI-aware BEFORE measuring anything, so every rect and every
# pixel length below is in PHYSICAL pixels -- the same space the product
# (scripts/browser_worker.py, sidecar/src/browser.cpp) computes in. A round-10
# review found the script was DPI-virtualized, which made the reported
# app_left_visible a different scale from the product's own numbers.
$dpiAware = [WinScan]::SetProcessDPIAware()
function Get-Space {
    if ($dpiAware) { return 'physical (SetProcessDPIAware ok)' }
    return 'VIRTUALIZED (SetProcessDPIAware failed -- lengths not comparable with the product)'
}

if (-not (Test-Path $OutDir)) { New-Item -ItemType Directory -Path $OutDir -Force | Out-Null }
$stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
# PID + a GUID fragment, not just seconds: the round-9 review reproduced two
# instances started in the same second appending to ONE file, interleaving rows.
$uniq = [guid]::NewGuid().ToString('N').Substring(0, 6)
$log = Join-Path $OutDir "capture-$stamp-p$PID-$uniq.log"
function Log($m) {
    $line = "{0}  {1}" -f (Get-Date -Format 'HH:mm:ss.fff'), $m
    Add-Content -Path $log -Value $line -Encoding UTF8
}

Log "START duration=${DurationSec}s interval=${IntervalMs}ms proc=$ProcName log=$log"
Log "COORD-SPACE=$(Get-Space)"
Log "VERDICT-METRIC=occluded_pct (topmost occluder above the app / app_area)"

$sw = [System.Diagnostics.Stopwatch]::StartNew()
$i = 0
$found = $false
$maxOccluded = 0.0
$agentBrowserPids = @{}   # PIDs proven to descend from the app process (ancestry cache)

while ($sw.Elapsed.TotalSeconds -lt $DurationSec) {
    $proc = Get-Process -Name $ProcName -ErrorAction SilentlyContinue | Select-Object -First 1
    if (-not $proc) {
        if ($found) { Log "s$i app gone"; $found = $false }
        Start-Sleep -Milliseconds $IntervalMs; $i++; continue
    }

    $appHits = [WinScan]::ByClassPrefix("FLUTTER_RUNNER_WIN32_WINDOW") |
               Where-Object { $_.Pid -eq $proc.Id } | Select-Object -First 1
    if (-not $appHits) { Start-Sleep -Milliseconds $IntervalMs; $i++; continue }
    if (-not $found) { Log "s$i app window FOUND pid=$($appHits.Pid) $($appHits.L),$($appHits.T) $($appHits.W)x$($appHits.H)"; $found = $true }

    $appRect = @($appHits.L, $appHits.T, $appHits.W, $appHits.H)

    # --- who actually covers the app? ---
    # Enumerate every visible top-level window in Z-order (EnumWindows order is
    # topmost-first). The occluder is the FIRST window above the app that
    # intersects it -- WHATEVER it is. This closes two blind spots the round-9
    # review confirmed:
    #   * the previous version only ever considered the AGENT'S browser, so an
    #     unrelated window covering the app read as "no occlusion" -- which is one
    #     of the two symptoms this observer was rewritten for;
    #   * it ignored Z-order, so a browser sitting BEHIND the app counted as
    #     occlusion even though the app was fully visible.
    $zList = [WinScan]::AllVisible()
    $appZ = -1
    for ($zi = 0; $zi -lt $zList.Count; $zi++) {
        if ($zList[$zi].Hwnd -eq $appHits.Hwnd) { $appZ = $zi; break }
    }

    $occluderRect = $null
    $occluderDesc = 'none'
    $occluderIsAgentBrowser = $false
    if ($appZ -ge 0) {
        foreach ($w in $zList) {
            if ($w.Hwnd -eq $appHits.Hwnd) { break }   # stop AT the app: only windows above it
            $wr = @($w.L, $w.T, $w.W, $w.H)
            if ((Get-OverlapArea $appRect $wr) -le 0) { continue }
            $occluderRect = $wr
            $occluderDesc = "{0}|pid={1}|{2}" -f $w.ClassName, $w.Pid, $w.Title
            if ($agentBrowserPids.ContainsKey([int]$w.Pid)) {
                $occluderIsAgentBrowser = $true
            }
            elseif ($w.ClassName -like 'Chrome_WidgetWin*') {
                # Only pay for the ~1s WMI ancestry lookup when the candidate could
                # plausibly be the agent's browser.
                $snap = Get-CimInstance Win32_Process -ErrorAction SilentlyContinue |
                        Select-Object ProcessId, ParentProcessId
                if ($snap -and (Test-DescendsFrom -ChildPid ([int]$w.Pid) -RootPid ([int]$proc.Id) -Snapshot $snap)) {
                    $agentBrowserPids[[int]$w.Pid] = $true
                    $occluderIsAgentBrowser = $true
                }
            }
            break
        }
    }

    $occluded = 0.0
    if ($occluderRect) { $occluded = Get-OccludedPct $appRect $occluderRect }
    if ($occluded -gt $maxOccluded) { $maxOccluded = $occluded }

    # How much of the app's LEFT side is still visible when something overlaps it.
    $appLeftVisible = $appRect[2]
    if ($occluderRect) {
        $ovl = Get-OverlapArea $appRect $occluderRect
        if ($ovl -gt 0) {
            $bx = [Math]::Max($appRect[0], $occluderRect[0])
            $appLeftVisible = $bx - $appRect[0]
        }
    }

    # --- auxiliary pixel signal (NOT the verdict) ---
    $wp = -1; $cp = -1
    if ($appHits.Visible -and -not $appHits.Iconic -and $appHits.W -gt 0 -and $appHits.H -gt 0) {
        try {
            $bmp = New-Object System.Drawing.Bitmap $appHits.W, $appHits.H
            $g = [System.Drawing.Graphics]::FromImage($bmp)
            $g.CopyFromScreen($appHits.L, $appHits.T, 0, 0, (New-Object System.Drawing.Size $appHits.W, $appHits.H))
            $g.Dispose()
            $white = 0; $colored = 0; $total = 0
            $stepX = [Math]::Max(1, [int]($appHits.W / 128)); $stepY = [Math]::Max(1, [int]($appHits.H / 90))
            for ($y = 0; $y -lt $appHits.H; $y += $stepY) {
                for ($x = 0; $x -lt $appHits.W; $x += $stepX) {
                    $c = $bmp.GetPixel($x, $y); $total++
                    if ($c.R -gt 245 -and $c.G -gt 245 -and $c.B -gt 245) { $white++ }
                    elseif ([Math]::Abs($c.R - $c.G) -gt 12 -or [Math]::Abs($c.G - $c.B) -gt 12) { $colored++ }
                }
            }
            $wp = if ($total) { [Math]::Round(100.0 * $white / $total, 1) } else { -1 }
            $cp = if ($total) { [Math]::Round(100.0 * $colored / $total, 1) } else { -1 }
            $bmp.Dispose()
        } catch { }
    }

    $oc = if ($occluderRect) {
        "occluder=$($occluderRect[0]),$($occluderRect[1]) $($occluderRect[2])x$($occluderRect[3])"
    } else { 'occluder=none' }
    $alert = ''
    if ($occluded -gt 0) { $alert = '  <<< OCCLUDED' }
    Log ("s{0:d4} app={1},{2} {3}x{4} hung={5} {6} occluded={7}% app_left_visible={8}px agent_browser={9} white={10}% colored={11}%{12}" -f `
        $i, $appRect[0], $appRect[1], $appRect[2], $appRect[3], $appHits.Hung, $oc, $occluded, $appLeftVisible, $occluderIsAgentBrowser, $wp, $cp, $alert)
    if ($occluded -gt 0) { Log ("    s{0:d4} occluder-identity: {1}" -f $i, $occluderDesc) }

    Start-Sleep -Milliseconds $IntervalMs
    $i++
}
Log "END samples=$i max_occluded=$maxOccluded% log=$log"
Write-Output "LOG=$log"
Write-Output "MAX_OCCLUDED=$maxOccluded"
