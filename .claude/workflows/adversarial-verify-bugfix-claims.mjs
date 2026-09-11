export const meta = {
  name: 'adversarial-verify-bugfix-claims',
  description: 'Adversarial verification of the 5 restored bug-fix claims (spec-compliant: N independent REFUTING skeptics, perspective-diverse, majority-kill)',
  phases: [
    { title: 'Refute', detail: '3 independent skeptics refute each of 5 claims (default refuted=true if uncertain)' },
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
      description: 'true if you successfully refuted the claim — it is NOT a real, accurately-described, warranted bug-fix',
    },
    reasoning: { type: 'string' },
  },
}

const CLAIMS = [
  {
    id: '5.1',
    task: 'fail-path no-capture',
    claim: 'captureLiveShot is the LAST statement of each live test case (real_api_test 3.1-3.4, live_file_tools Test 1-4), placed AFTER every fail()/expect/markTestSkipped/TimeoutException path, so fail states (model empty reply, Error bubble, timeout, deadlock) are NEVER screenshotted; it must move to try/finally or become self-contained to also capture fail paths.',
  },
  {
    id: '5.2',
    task: 'stale/blank no-guard',
    claim: 'captureLiveShot only try/catch-logs on failure and overwrites test/live_visual/<name>.png, so a stale previous-run PNG can be mistaken for the current run, and there is no non-blank/non-empty (byte/size) guard; it needs delete-on-fail plus non-blank validation plus a DPR/physical-pixel note.',
  },
  {
    id: '5.3',
    task: 'jumpTo silent restore',
    claim: 'in live_observability.dart _scanToolCards, the viewport restore uses ScrollController.jumpTo inside an EMPTY catch (silent failure) with NO offset==maxScrollExtent verification, so a silently-failed restore leaves the chat list scrolled-up showing the WRONG region (final reply off-viewport); and _scanErrorCardsWithScroll never restores the viewport at all.',
  },
  {
    id: '5.4',
    task: 'no painted precondition',
    claim: 'captureWidgetAsPng calls boundary.toImage() with NO painted-precondition check (no pump / debugNeedsPaint==false / hasSize), so a valid-looking but content-stale frame (missing the newest bubble/card) can be captured and treated as valid — especially on fail paths where no render-stabilizing pump ran.',
  },
  {
    id: '5.5',
    task: 'acceptance semantic overclaim',
    claim: 'the change is framed as acceptance/验收 (spec "Native-vision visual acceptance by main loop", proposal, design), but an image cannot verify file-content assertions — a model can reply correctly yet edit the file wrong, so the screenshot looks fine while the test FAILS; framing overclaims and should be relabeled render observability (verifies render, not assertion).',
  },
]

const LENSES = [
  {
    key: 'correctness',
    instruction: 'REFUTE on CORRECTNESS: the described defect is not actually present, or is materially mis-described (wrong file/line/behavior). Read the code carefully. Default refuted=true if you are NOT certain the bug is real and accurately described.',
  },
  {
    key: 'already-handled',
    instruction: 'REFUTE on ALREADY-HANDLED / OVER-CLAIM: the bug is already mitigated by existing code, is already fixed in the artifacts, or the claimed impact is overstated. Default refuted=true if you are NOT certain it is an unfixed, real, still-relevant problem.',
  },
  {
    key: 'scope-contradiction',
    instruction: 'REFUTE on SCOPE / CONTRADICTION / OVER-ENGINEERING: fixing it would contradict the spec, reintroduce a previously-rejected design (e.g. PASS-must-have-screenshot coupling, manifest/verdict channel), or address a non-issue. Default refuted=true if you are NOT certain the fix is warranted.',
  },
]

function skepticPrompt(claim, lens) {
  return (
    'You are an adversarial skeptic in working dir ' + CWD + '. Your ONLY job is to REFUTE the following claimed bug-fix, not to confirm it. ' +
    'Default to refuted=true if you are uncertain. ' +
    lens.instruction + ' ' +
    'Read these to check: ' + CHANGE + '/tasks.md (task ' + claim.id + ' "' + claim.task + '"), ' +
    'integration_test/live_observability.dart, integration_test/real_api_test.dart, integration_test/live_file_tools_test.dart, ' +
    'test/integration/helpers/screenshot_utils.dart, ' + CHANGE + '/design.md (review section), ' + CHANGE + '/specs/live-test-visual-acceptance/spec.md. ' +
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
    verdict: survives ? 'SURVIVED (confirmed real bug to fix)' : 'KILLED (refuted — not a warranted real bug)',
    refuteCount: refutes.length,
    surviveCount: votes.length - refutes.length,
    skepticVotes: votes.map((v) => ({ lens: v.lens, refuted: v.refuted, reasoning: v.reasoning })),
  })
}

log('Refuted ' + verdicts.length + ' skeptic-votes across ' + CLAIMS.length + ' claims; survivors: ' + results.filter((r) => r.verdict.startsWith('SURVIVED')).length)
return { perClaim: results }
