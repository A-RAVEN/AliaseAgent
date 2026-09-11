export const meta = {
  name: 'review-testing-guide-v2',
  description: 'Re-verify docs/TESTING.md after fixing the v1 review defects — confirm each corrected fact now matches source (sidecar build path, log rotation, ctest/binary, real_sidecar vs bridge SSE, app_shell Scaffold exception, ASan tree), completeness gaps closed, and NO new contradiction/omission introduced. REFUTING skeptics, majority-kill, LOCAL-source-only.',
  phases: [
    { title: 'Refute', detail: '3 skeptics refute each of 3 claims (default refuted=true)' },
    { title: 'Vote', detail: 'Majority-kill: survives if <majority refute' },
  ],
}

const CWD = 'E:/Projects/AliasAgent'
const DOC = 'E:/Projects/AliasAgent/docs/TESTING.md'
const README = 'E:/Projects/AliasAgent/README.md'

const REFUTE_SCHEMA = {
  type: 'object',
  required: ['refuted', 'reasoning'],
  properties: {
    refuted: { type: 'boolean', description: 'true if you REFUTED the claim' },
    reasoning: { type: 'string' },
  },
}

const CLAIMS = [
  {
    id: 'R1',
    task: 'Write-conventions + command fixes are now correct (app_shell Scaffold exception; real_sidecar vs bridge SSE; sidecar build path; ctest replaced by binary+tag; ASan tree)',
    claim: 'docs/TESTING.md (and README.md) now state the CORRECT facts after the v1 fixes: (a) §2.2 no longer claims the widget tree is ALWAYS MaterialApp>Scaffold — it says "usually", and names the exception that app_shell_test.dart pumps `MaterialApp(home: AppShell(...))`; (b) §2.3 correctly separates real_sidecar_test (real file I/O via SidecarBridge.instance, NO SSE mock) from bridge_realtime_test (the only one using the `_SseServer` SSE mock); (c) §2.5 + README use `sidecar/build/windows` (not repo-root `build/windows`) for cmake -B / --build / ctest / the sidecar_tests.exe path, and replaced the invalid `ctest -R sse_parser` with the direct binary+tag call `./sidecar/build/windows/Debug/sidecar_tests.exe "[sse_parser]"`; (d) §4.3 points ASan at its own tree `sidecar/build/asan/`. Each of these now matches the actual source.',
  },
  {
    id: 'R2',
    task: 'Debug log-rotation fact is now correct (keeps 2 historical; .3.log is dead code)',
    claim: 'docs/TESTING.md §4.1 now states the correct log-rotation behavior: logger.cpp rotate_logs() removes `sidecar.log` + ".2.log" (or rather: remove .2.log, rename .1.log→.2.log, rename sidecar.log→.1.log), keeping at most 2 historical files (.1.log/.2.log); the ".3.log" references in the code are dead code, and the old "max 3 historical" wording (also in DEBUGGING.md) is correctly flagged as stale/wrong, deferring to logger.cpp as the source of truth. No other §4 fact (paths, levels, env read-once, auth-redacted, crash artifacts, FFI ring) was altered.',
  },
  {
    id: 'R3',
    task: 'Completeness gaps closed and NO new contradiction/omission introduced',
    claim: 'The reworked doc now covers the previously-omitted material items: run.bat (Windows one-click build+smoke+launch entry), the smoke check_deps prerequisite (flutter/dart/sqlite3/powershell), the [zhipuai][rate-guard] / [searxng] C++ tags, sidecar/test/test_utils/{api_key_loader.h,searxng_harness.h}, the live prerequisites (tools/rg.exe for glob/grep, thinking_effort config), integration_test screenshot_utils.dart, and the full test/integration file list. The fixes introduced NO new contradiction, imprecision, or omission: the doc is internally consistent (section 1 layers vs section 2 commands vs section 5 rules), consistent with CLAUDE.md/DEBUGGING.md source-of-truth (not its stale comments), and every corrected fact matches the actual source.',
  },
]

const LENSES = [
  {
    key: 'fix-correct',
    instruction: 'REFUTE if any FIX is NOT actually correct/complete against the source. Read docs/TESTING.md (+ README.md) and verify each corrected fact: (a) app_shell_test.dart pumps MaterialApp(home:AppShell(...)) not Scaffold body (read test/widget/app_shell_test.dart); (b) real_sidecar_test.dart has NO ServerSocket/SSE-mock (read test/integration/real_sidecar_test.dart) while bridge_realtime_test.dart does (read it); (c) sidecar CMake build dir is sidecar/build/windows (verify scripts/rebuild_sidecar.bat SID_BUILD, sidecar/build/windows/CTestTestfile.cmake exists, NO repo-root build/windows CTestTestfile); only ONE ctest test is registered so `ctest -R sse_parser` matches nothing — the doc must instead call the binary with a Catch2 tag; ASan builds into sidecar/build/asan (verify scripts/rebuild_sidecar.bat ASAN_BUILD_DIR); (d) §4.1 rotation matches logger.cpp rotate_logs() (remove .2.log, keep .1+.2, .3.log dead). Default refuted=true if uncertain.',
  },
  {
    key: 'completeness',
    instruction: 'REFUTE if the reworked doc still OMITS material test subsystems/commands/prereqs that exist in the repo. Independently scan test/, test/unit/, test/widget/, test/integration/, integration_test/, sidecar/test/, test/smoke/, run.bat, dart_test.yaml, and DEBUGGING.md, then check each is covered by docs/TESTING.md. Call out anything present-but-absent (e.g. run.bat, check_deps, [rate-guard]/[searxng] tags, test_utils headers, rg.exe/thinking_effort prereqs, screenshot_utils.h). Default refuted=true if uncertain.',
  },
  {
    key: 'consistency-regression',
    instruction: 'REFUTE on CONSISTENCY / REGRESSION: after the fixes, is docs/TESTING.md internally consistent and consistent with the source of truth (CLAUDE.md, DEBUGGING.md-as-source NOT as stale-comment, actual src)? Check section 1 layers vs section 2 commands vs section 5 rules still agree; no place now contradicts the sidecar build path or log rotation; the fixes did not introduce a NEW contradictory fact or drop something that was correct before. Default refuted=true if uncertain.',
  },
]

function skepticPrompt(claim, lens) {
  return (
    'You are an adversarial reviewer in working dir ' + CWD + '. Your ONLY job is to REFUTE the following claim about the REWORKED document ' + DOC + '. Default to refuted=true if uncertain. ' +
    lens.instruction + ' ' +
    'IMPORTANT CONSTRAINTS: You have NO network access and MUST NOT use MCP tools, WebSearch, WebFetch, or any HTTP fetch. Verify against LOCAL files only. Read ' + DOC + ' (and ' + README + ') plus the actual source files listed in the claim. ' +
    'CLAIM: ' + claim.claim
  )
}

phase('Refute')

const verdicts = await parallel(
  CLAIMS.flatMap((claim) =>
    LENSES.map((lens) => () =>
      agent(skepticPrompt(claim, lens), {
        label: 'refute:' + claim.id + ':' + lens.key,
        phase: 'Refute',
        schema: REFUTE_SCHEMA,
      }).then((v) => ({ claimId: claim.id, lens: lens.key, refuted: v ? v.refuted : true, reasoning: v ? v.reasoning : '' }))
    )
  )
)

phase('Vote')
const results = []
for (const claim of CLAIMS) {
  const votes = verdicts.filter((v) => v && v.claimId === claim.id)
  const refutes = votes.filter((v) => v.refuted)
  const survives = refutes.length < 2
  results.push({
    claimId: claim.id,
    task: claim.task,
    verdict: survives ? 'SURVIVED (rework correct/complete/consistent)' : 'KILLED (refuted — rework still has a real problem)',
    refuteCount: refutes.length,
    surviveCount: votes.length - refutes.length,
    skepticVotes: votes.map((v) => ({ lens: v.lens, refuted: v.refuted, reasoning: v.reasoning })),
  })
}

log('Final testing-guide v2: ' + verdicts.length + ' skeptic-votes across ' + CLAIMS.length + ' claims; survivors: ' + results.filter((r) => r.verdict.startsWith('SURVIVED')).length)
return { perClaim: results }
