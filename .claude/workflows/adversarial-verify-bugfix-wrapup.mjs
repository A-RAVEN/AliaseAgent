export const meta = {
  name: 'adversarial-verify-bugfix-wrapup',
  description: 'Final wrap-up adversarial verification of the 5.1/5.2 IMPLEMENTATION (final state + regression): N independent REFUTING skeptics, perspective-diverse, majority-kill.',
  phases: [
    { title: 'Refute', detail: '3 skeptics refute each of 4 wrap-up claims (final state + regression + consistency), default refuted=true' },
    { title: 'Vote', detail: 'Majority-kill: a claim survives only if <majority of skeptics refute it' },
  ],
}

const CWD = 'E:/Projects/AliasAgent'
const CHANGE = 'openspec/changes/add-live-test-visual-acceptance'

const REFUTE_SCHEMA = {
  type: 'object',
  required: ['refuted', 'reasoning'],
  properties: {
    refuted: { type: 'boolean', description: 'true if you REFUTED the final-fix claim' },
    reasoning: { type: 'string' },
  },
}

const CLAIMS = [
  {
    id: 'W1',
    task: '5.1 final: try/finally fail-path capture (regression-free)',
    claim: 'FINAL 5.1 is correct and regression-free: all 8 live cases wrap their body in `try { ... } finally { await captureLiveShot(tester, captureKey, \'<name>\'); }` (no addTearDown anywhere as a capture mechanism), and `captureLiveShot(tester,key,name)` does `await tester.pump()` then `captureWidgetAsPng`. The in-body finally runs before `_runTestBody`\'s `runApp(_postTestMessage)` tree-reset on pass (boundary still mounted → success captures preserved), and on fail/skip/timeout the reset is gated off (`_pendingExceptionDetails != null`) so the tree stays mounted → fail states now captured. No `return`/`fail`/`markTestSkipped`/`rethrow` inside any try breaks the finally; flutter analyze is clean.',
  },
  {
    id: 'W2',
    task: '5.2 final: delete-on-fail + byte floor 2048 + setUpAll stale-clear (NOT over-engineered, does NOT delete sparse fail frames)',
    claim: 'FINAL 5.2 is correct, spec-aligned, and not over-engineered: `captureLiveShot` catches any failure and deletes the target PNG (delete-on-fail); the non-blank/sanity check is a single byte floor `_kMinShotBytes=2048` (the spec\'s "字节数/尺寸阈值"), which is comfortably below real scenes (27-53KB) AND below a sparse-but-real fail frame, so it never rejects a legitimate capture and never deletes a sparse fail-state frame; `setUpAll(clearLiveVisualDir)` in BOTH suites clears `test/live_visual/*.png` before any test (including a later-skipped one), closing the skip-before-registration stale gap. `_isBlankFrame` is removed (jugged over-engineered + it deleted sparse fail frames); a genuinely unreadable frame is still reported honestly as "截图无效" by the acceptance loop (design D4), and captureWidgetAsPng does not produce a solid blank (failed toImage throws → delete-on-fail; a painted boundary renders the real multi-color app).',
  },
  {
    id: 'W3',
    task: 'regression check: round-2/round-3 fixes intact, no re-introduction',
    claim: 'REGRESSION-FREE with respect to the audit fixes: (a) NO `addTearDown`-based capture remains (round-2\'s F1 was the addTearDown pass-path breakage — grep must show zero functional addTearDown capture calls), (b) NO `_isBlankFrame` / pixel-variance / instantiateImageCodec remains (round-3\'s V2 over-engineering fix — grep must show none), (c) `setUpAll(clearLiveVisualDir)` is present in BOTH suites and `clearLiveVisualDir` still deletes `test/live_visual/*.png` (round-2 stale-gap fix intact), (d) all 8 try/finally capture sites are intact and brace-balanced, (e) `flutter analyze` clean on the 3 files.',
  },
  {
    id: 'W4',
    task: 'tasks.md consistency + honest final state; no hidden bug / no weakened assertion',
    claim: 'tasks.md §5 accurately reflects the ACTUAL final code: 5.1/5.2 [x] described as try/finally + delete-on-fail + byte floor 2048 + setUpAll, with the honest audit history (round-1 claims: 5.1/5.2 confirmed, 5.3/5.4/5.5 refuted; round-2: addTearDown pass-break + byte-threshold blank-accept caught; round-3: _isBlankFrame over-engineering caught and removed). It honestly leaves 5.6 (live run) and 5.7 (wrap-up) as `[ ]`. It does NOT overclaim live verification, and does NOT hide the refuted 5.3/5.4/5.5 or the rework. No expect/fail/markTestSkipped assertion is weakened, and no broken capture path is silently accepted.',
  },
]

const LENSES = [
  {
    key: 'correctness',
    instruction: 'REFUTE on CORRECTNESS: the final fix is mis-wired, a path still loses capture (pass or fail/skip), the byte floor wrongly rejects a real/legitimate frame (incl. a sparse fail frame) or wrongly accepts an unreadable one, or a `return`/`rethrow`/`fail` inside a try breaks the finally. Read the actual code, verify brace balance, and verify against flutter_test binding source that the in-body finally runs before the tree-reset on pass. Default refuted=true if not certain.',
  },
  {
    key: 'regression',
    instruction: 'REFUTE on REGRESSION / RE-INTRODUCTION: the round-2/round-3 fixes are NOT present / were reverted (a leftover addTearDown capture, a leftover _isBlankFrame/pixel-variance, a missing setUpAll(clearLiveVisualDir), a missing try/finally site), or a NEW inconsistency was introduced. Grep the actual files. Default refuted=true if not certain the fixes are intact and nothing regressed.',
  },
  {
    key: 'scope-contradiction',
    instruction: 'REFUTE on SCOPE / CONTRADICTION / OVER-ENGINEERING: the final fix violates non-goals (lib/, C++, new dependency — note dart:typed_data/dart:ui imports must be REMOVED now that _isBlankFrame is gone, or the change is over-engineered again), weakens an assertion or the spec acceptance, contradicts the refuted 5.4/5.5, or is over-engineered (a variance/decoder / extra machinery beyond the spec\'s byte threshold). Default refuted=true if not certain the final fix is in-scope and not over-engineered.',
  },
]

function skepticPrompt(claim, lens) {
  return (
    'You are an adversarial skeptic in working dir ' + CWD + '. Your ONLY job is to REFUTE the following FINAL-STATE claim, not to confirm it. Default to refuted=true if uncertain. ' +
    lens.instruction + ' ' +
    'Read these to check: ' + CHANGE + '/tasks.md (tasks 5.1/5.2 [x], audit history, 5.3/5.4/5.5 refuted), ' +
    'integration_test/live_observability.dart (captureLiveShot, _kMinShotBytes, clearLiveVisualDir — confirm NO _isBlankFrame / no dart:typed_data / no dart:ui import), ' +
    'integration_test/real_api_test.dart and integration_test/live_file_tools_test.dart (8 try/finally capture sites + setUpAll(clearLiveVisualDir)), ' +
    'test/integration/helpers/screenshot_utils.dart. You may run `flutter analyze` on those 3 files and `grep` for addTearDown / _isBlankFrame / instantiateImageCodec (no network). ' +
    'You may Read flutter_test/src/binding.dart (_runTestBody runApp(_postTestMessage)) to confirm ordering. ' +
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
    verdict: survives ? 'SURVIVED (final fix confirmed)' : 'KILLED (refuted — final fix still has a real problem)',
    refuteCount: refutes.length,
    surviveCount: votes.length - refutes.length,
    skepticVotes: votes.map((v) => ({ lens: v.lens, refuted: v.refuted, reasoning: v.reasoning })),
  })
}

log('Wrap-up: refuted ' + verdicts.length + ' skeptic-votes across ' + CLAIMS.length + ' final-state claims; survivors: ' + results.filter((r) => r.verdict.startsWith('SURVIVED')).length)
return { perWrapUpClaim: results }
