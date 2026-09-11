export const meta = {
  name: 'adversarial-verify-bugfix-implementation-v2',
  description: 'Round-3 adversarial verification of the CORRECTED 5.1/5.2 implementation (try/finally + pixel-variance blank + setUpAll stale-clear). N independent REFUTING skeptics, perspective-diverse, majority-kill.',
  phases: [
    { title: 'Refute', detail: '3 skeptics refute each of 4 corrected-fix claims (default refuted=true if uncertain)' },
    { title: 'Vote', detail: 'Majority-kill: a claim survives only if <majority of skeptics refute it' },
  ],
}

const CWD = 'E:/Projects/AliasAgent'
const CHANGE = 'openspec/changes/add-live-test-visual-acceptance'

const REFUTE_SCHEMA = {
  type: 'object',
  required: ['refuted', 'reasoning'],
  properties: {
    refuted: {
      type: 'boolean',
      description: 'true if you successfully REFUTED the corrected-fix claim — the implemented fix is NOT correct/complete/in-scope as claimed',
    },
    reasoning: { type: 'string' },
  },
}

const CLAIMS = [
  {
    id: 'V1',
    task: '5.1 fail-path capture (try/finally, NOT addTearDown)',
    claim: 'The CORRECTED 5.1 is correct: each of the 8 live cases now wraps its body in `try { ... } finally { await captureLiveShot(tester, captureKey, \'<name>\'); }` (no addTearDown), and `captureLiveShot(tester, key, name)` does `await tester.pump()` then `captureWidgetAsPng(key, path)`. Because the finally runs INSIDE the user body — before `_runTestBody`\'s tree-reset (`runApp(_postTestMessage)=unmount`, flutter_test/binding.dart:1689-1691) on the pass path, and while the tree stays mounted on fail/skip/timeout (where that reset is gated off) — this captures on pass WITHOUT regressing the previously-7/7-valid success images, AND captures the fail/skip/timeout states. No `return`-inside-try semantic or brace imbalance breaks any of the 8 tests.',
  },
  {
    id: 'V2',
    task: '5.2 stale/blank guard (pixel-variance + setUpAll clear + delete-on-fail)',
    claim: 'The CORRECTED 5.2 is correct: `captureLiveShot` try/catch does delete-on-fail; the non-blank guard is `_isBlankFrame(bytes)` = `ui.instantiateImageCodec` → raw-RGBA → count quantized (4-bit/channel) colors, blank if ≤5 distinct shades, real if >16 — rejecting a solid/near-solid blank frame EVEN IF it compresses above any byte floor (round-2 measured solid 1266x683 ≈ 2594-4104 bytes), while ACCEPTING a low-entropy-but-structured fail-state frame (sidebar+input+dots → real color variety) so it does not collide with 5.1\'s fail-capture; byte floor `_kMinShotBytes=1024` catches corrupt/zero writes; and each suite\'s `setUpAll(clearLiveVisualDir)` removes prior `test/live_visual/*.png` before any test, so the skip-before-registration gap (a case skipped before its capture is ever registered → delete-on-fail never ran) cannot leave a stale misread. NO path leaves a misread stale PNG; NO solid blank is accepted.'
  },
  {
    id: 'V3',
    task: 'scope: no lib/C++, assertions not weakened, not over-engineering',
    claim: 'The corrected implementation touches ONLY integration_test/live_observability.dart, integration_test/real_api_test.dart, integration_test/live_file_tools_test.dart (test-side, no lib/, no C++, no new dependency except `dart:ui`/`dart:typed_data` which are already in every Flutter app, no pubspec change; `.gitignore` adding test/live_visual/ is the already-done task 1.6). No expect/fail/markTestSkipped assertion is weakened. `tester.pump()`, the pixel-variance blank check, and setUpAll stale-clear are all mandated by design D3 #1/#2 and the spec scenarios, NOT speculative hardening — and none re-introduces the refuted 5.4 (hard needsPaint gate that suppresses fail states) or 5.5 (semantic overclaim).'
  },
  {
    id: 'V4',
    task: 'tasks.md [x] descriptions match the actual final code; honesty preserved',
    claim: 'tasks.md marking 5.1/5.2 as [x] with try/finally + pixel-variance + setUpAll descriptions is truthful: the actual working tree implements `try { } finally { await captureLiveShot(tester, captureKey, ...) }` in all 8 cases, `captureLiveShot(tester, key, name)` with `tester.pump()` + delete-on-fail + `_isBlankFrame` + `_kMinShotBytes=1024`, and `setUpAll(clearLiveVisualDir)` in both suites. It honestly leaves 5.6 (live run) and 5.7 (round-3 review) as `[ ]`, and honestly documents the round-2 addTearDown/byte-threshold failures and the rework. It does NOT overclaim live verification or hide the refuted 5.3/5.4/5.5.'
  },
]

const LENSES = [
  {
    key: 'correctness',
    instruction: 'REFUTE on CORRECTNESS: the corrected fix is not actually present as described, is mis-wired (try/finally brace/scope wrong, a `return` or `rethrow` inside the try breaks the finally or the test), a path still fails (a rendered-then-failed/skipped/passed case still skips or loses capture), or the pump does not clear `debugNeedsPaint`. Read the actual code carefully and verify brace balance + scope of every `return`/`fail`/`markTestSkipped`/`rethrow` inside each try. Default refuted=true if not certain the corrected fix is correct and complete.',
  },
  {
    key: 'empirical-guard-check',
    instruction: 'REFUTE on the EMPIRICAL GUARD BEHAVIOR: does the pixel-variance `_isBlankFrame` actually reject a real solid/near-solid blank and accept a structured sparse frame? Reason carefully about the quantized distinct-color counting: a solid frame yields ~1 distinct color (rejected), a plain light-surface frame yields ~1-3 (rejected), a UI scene (sidebar + text + cards) yields many (accepted). Does the new try/finally genuinely run the finally on the pass path (before the tree reset) — confirm against flutter_test binding source that `runApp(_postTestMessage)` unmount happens in `_runTestBody` AFTER the user body returns, so a finally inside the body is reached while the boundary is mounted? And does `setUpAll(clearLiveVisualDir)` truly clear stale files (run before any test, even a skip)? Default refuted=true if not certain.',
  },
  {
    key: 'scope-contradiction',
    instruction: 'REFUTE on SCOPE / CONTRADICTION / OVER-ENGINEERING: the change violates its non-goals (lib/, C++, new dependency), weakens/relaxes any expect/fail/markTestSkipped or the spec acceptance, contradicts the refuted 5.4/5.5 rulings, or is over-engineered (the variance check / setUpAll are speculative rather than required). Default refuted=true if not certain the corrected fix is in-scope and not over-engineered.',
  },
]

function skepticPrompt(claim, lens) {
  return (
    'You are an adversarial skeptic in working dir ' + CWD + '. Your ONLY job is to REFUTE the following claim about the CORRECTED IMPLEMENTATION, not to confirm it. ' +
    'Default to refuted=true if you are uncertain. ' +
    lens.instruction + ' ' +
    'Read these to check: ' + CHANGE + '/tasks.md (tasks 5.1/5.2 [x] with corrected descriptions, 5.3/5.4/5.5 refuted, honest note), ' +
    'integration_test/live_observability.dart (captureLiveShot, _isBlankFrame, _kMinShotBytes, clearLiveVisualDir), ' +
    'integration_test/real_api_test.dart and integration_test/live_file_tools_test.dart (the 8 try/finally capture sites + setUpAll(clearLiveVisualDir)), ' +
    'test/integration/helpers/screenshot_utils.dart (captureWidgetAsPng). You may run `flutter analyze` on those 3 files (no network). ' +
    'You may also Read the flutter_test source flutter_test/src/binding.dart (around _runTestBody runApp(_postTestMessage)) and flutter_test/src/widget_tester.dart (testWidgets addTearDown) to confirm ordering; do NOT use network. ' +
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
    verdict: survives ? 'SURVIVED (corrected fix confirmed)' : 'KILLED (refuted — corrected fix still has a real problem)',
    refuteCount: refutes.length,
    surviveCount: votes.length - refutes.length,
    skepticVotes: votes.map((v) => ({ lens: v.lens, refuted: v.refuted, reasoning: v.reasoning })),
  })
}

log('Refuted ' + verdicts.length + ' skeptic-votes across ' + CLAIMS.length + ' corrected-fix claims; survivors: ' + results.filter((r) => r.verdict.startsWith('SURVIVED')).length)
return { perFixClaim: results }
