export const meta = {
  name: 'adversarial-verify-bugfix-implementation',
  description: 'Adversarial verification of the 5.1/5.2 implementation (spec-compliant: N independent REFUTING skeptics, perspective-diverse, majority-kill)',
  phases: [
    { title: 'Refute', detail: '3 independent skeptics refute each of 4 fix-claims (default refuted=true if uncertain)' },
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
      description: 'true if you successfully REFUTED the fix-claim — the implemented fix is NOT correct/complete/consistent as claimed',
    },
    reasoning: { type: 'string' },
  },
}

const CLAIMS = [
  {
    id: 'F1',
    task: '5.1 fail-path capture (addTearDown + pump)',
    claim: 'The 5.1 fix is correct and complete: captureLiveShot now takes (WidgetTester tester, GlobalKey key, String name), does `await tester.pump()` before toImage, and each of the 8 live cases registers `addTearDown(() => captureLiveShot(tester, captureKey, \'<name>\'))` right after pumpWidget (removing the old tail `await captureLiveShot(captureKey,\'<name>\')`). The addTearDown runs on EVERY path (pass / fail / markTestSkipped / TimeoutException) before the tree-reset (binding.postTest) and before the group tearDown (DB-close), and the pump clears debugNeedsPaint so toImage does not assert. NO rendered-then-failing path still skips the capture.',
  },
  {
    id: 'F2',
    task: '5.2 stale/blank guard (delete-on-fail + threshold)',
    claim: 'The 5.2 fix is correct and complete: on ANY capture failure (toImage throw / empty bytes / blank frame) captureLiveShot deletes `test/live_visual/<name>.png` (delete-on-fail) and on success validates byte length >= _kMinShotBytes (4096), throwing (→ delete-on-fail) for degenerate/blank/black frames. NO circumstance leaves a prior run\'s PNG at the fixed path to be misread as the current run, and NO valid real scene is wrongly rejected.',
  },
  {
    id: 'F3',
    task: 'scope: no lib/C++, assertions not weakened, no over-engineering',
    claim: 'The implementation respects the change boundaries: it touches ONLY integration_test/live_observability.dart, integration_test/real_api_test.dart, integration_test/live_file_tools_test.dart (test-side). NO lib/, NO C++, NO new dependencies, NO spec/design/spec acceptance relaxation, and NO expect/fail/markTestSkipped assertion changed. The added `tester.pump()` and delete-on-fail/threshold are warranted by the change\'s own design D3 robustness (fail-path capture + stale guard) and do NOT re-introduce the refuted 5.4 (painted precondition) or 5.5 (semantic overclaim) over-engineering — they are mechanically necessary to make fail-path capture actually produce a non-blank image.',
  },
  {
    id: 'F4',
    task: 'tasks.md marking 5.1/5.2 [x] is honest (not fabricated)',
    claim: 'tasks.md marking 5.1 and 5.2 as [x] (with the honest note that live verification is pending, 5.6) is truthful: the CODE actually implements the described fix (verify the addTearDown scaffolding, the tester param, the pump, delete-on-fail, _kMinShotBytes=4096 all genuinely exist and are wired correctly), and it does NOT overclaim completion (the live-run verification is correctly left as 5.6), and does NOT hide that 5.3/5.4/5.5 were refuted.',
  },
]

const LENSES = [
  {
    key: 'correctness',
    instruction: 'REFUTE on CORRECTNESS: the implemented fix is not actually present as described, is mis-wired, has a path that still fails (a rendered-then-failed case that still skips capture, or a stale/blank PNG that survives), or the pump does not actually clear debugNeedsPaint. Read the actual code carefully. Default refuted=true if you are NOT certain the fix is correct and complete.',
  },
  {
    key: 'unintended-effect',
    instruction: 'REFUTE on UNINTENDED EFFECT / EDGE CASE: the fix breaks the passing success-path capture (the previously-7/7-valid images), breaks /hangs a test (pump() in teardown, retry re-registration of addTearDown — does addTearDown fire ONCE per test, not per retry), swallows a needed capture, or the byte threshold wrongly rejects a legitimate scene / accepts a blank one. Default refuted=true if you are NOT certain there is no unintended effect.',
  },
  {
    key: 'scope-contradiction',
    instruction: 'REFUTE on SCOPE / CONTRADICTION / OVER-ENGINEERING: the change violates its own non-goals (touches lib/ or C++ or adds a dependency), weakens/relaxes any expect/fail/markTestSkipped assertion or the spec acceptance criteria, contradicts the refuted 5.4/5.5 rulings, or is over-engineered (e.g. the pump/threshold is speculative hardening rather than required). Default refuted=true if you are NOT certain the fix is in-scope and not over-engineered.',
  },
]

function skepticPrompt(claim, lens) {
  return (
    'You are an adversarial skeptic in working dir ' + CWD + '. Your ONLY job is to REFUTE the following claim about an IMPLEMENTED FIX, not to confirm it. ' +
    'Default to refuted=true if you are uncertain. ' +
    lens.instruction + ' ' +
    'Read these to check: ' + CHANGE + '/tasks.md (tasks 5.1/5.2 marked [x], 5.3/5.4/5.5 refuted, honest note), ' +
    'integration_test/live_observability.dart (captureLiveShot + const _kMinShotBytes), ' +
    'integration_test/real_api_test.dart and integration_test/live_file_tools_test.dart (the 8 addTearDown capture sites), ' +
    'test/integration/helpers/screenshot_utils.dart (captureWidgetAsPng), ' +
    CHANGE + '/design.md (D3 robustness #1/#2, refuted #3/#5, RepaintBoundary 语义澄清), ' +
    CHANGE + '/specs/live-test-visual-acceptance/spec.md. ' +
    'You may also run `flutter analyze` on those 3 files if useful (no network). ' +
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
  const survives = refutes.length < 2 // majority of 3 refute => killed; survive if <=1 refute
  results.push({
    claimId: claim.id,
    task: claim.task,
    verdict: survives ? 'SURVIVED (fix confirmed correct/complete/in-scope)' : 'KILLED (refuted — fix has a real problem)',
    refuteCount: refutes.length,
    surviveCount: votes.length - refutes.length,
    skepticVotes: votes.map((v) => ({ lens: v.lens, refuted: v.refuted, reasoning: v.reasoning })),
  })
}

log('Refuted ' + verdicts.length + ' skeptic-votes across ' + CLAIMS.length + ' fix-claims; survivors: ' + results.filter((r) => r.verdict.startsWith('SURVIVED')).length)
return { perFixClaim: results }
