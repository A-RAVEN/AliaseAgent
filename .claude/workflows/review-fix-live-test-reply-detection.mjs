export const meta = {
  name: 'review-fix-live-test-reply-detection',
  description: 'Adversarial review of the fix-live-test-reply-detection change (root-cause attribution, spec/design/tasks fidelity, scope). N REFUTING skeptics, perspective-diverse, majority-kill.',
  phases: [
    { title: 'Refute', detail: '3 skeptics refute each of 4 claims (default refuted=true if uncertain)' },
    { title: 'Vote', detail: 'Majority-kill: survives if <majority refute' },
  ],
}

const CWD = 'E:/Projects/AliasAgent'
const CHANGE = 'openspec/changes/fix-live-test-reply-detection'

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
    task: 'root-cause attribution (test widget finder = false-fail cause)',
    claim: 'The root cause is CORRECT: `real_api_test` 3.3 falsely failed because `completedAssistant`/`latestAssistantText` are widget-tree finders (`find.byWidgetPredicate((w)=>w is MessageBubble && role=="assistant" && !isStreaming)`), so correctness is coupled to MessageBubble RENDERING (ListView.builder lazy-build/recycle/pump timing), NOT to whether the model replied. Verified evidence: model returned a full correct answer (sidecar.log trace `stop_reason=end_turn`, `model_gateway.cpp:205-211` text_delta→on_chunk→Dart turnText), app STORED it (`main.dart:906 turnText.isNotEmpty→insert`), and app RENDERED the Assistant bubble (screenshot `test/live_visual/3.3_edit_file.png` shows the full reply). The test failed only because the bubble was not yet built into the tree at the check moment. It is NOT a model empty-reply and NOT an app-not-storing bug.',
  },
  {
    id: 'R2',
    task: 'spec delta fidelity (state-based, honest-fail preserved)',
    claim: 'The `live-ui-tests` delta spec MODIFIED correctly captures the behavior change WITHOUT weakening the honest-fail requirement: reply detection is now judged from conversation state (assistant message content), a new "Reply detection is decoupled from bubble rendering" scenario covers the false-fail case, and the "Silent completion" scenario now requires NO non-empty assistant message IN STATE to fail (so internal bugs / true empty replies still honestly fail), with an explicit AND clause that a reply existing in state but not-yet-built must NOT be treated as silent completion. No acceptance criterion is degraded.',
  },
  {
    id: 'R3',
    task: 'design soundness + scope (state=truth; minimal observability hook, no behavior change)',
    claim: 'The design is sound and in-scope: D1 (correctness = conversation state, not render), D2-A (read-only state getter + GlobalKey<ChatScreenState>, observability-only; B/C documented as alternatives), D3 (render stays for the screenshot/visual-acceptance, decoupled from correctness), D4 (silent-completion checks state, not widget). It does NOT require changing the app\'s conversation/storage/render behavior (the app already stores+renders correctly per evidence); any lib exposure is read-only observability. It does not reintroduce over-engineering (e.g. no content-matching/assertion-from-image overclaim; render is kept for visual-observability only, per the refuted 5.5/5.3 rulings that rendered ≠ correctness).',
  },
  {
    id: 'R4',
    task: 'tasks complete/execcutable/consistent',
    claim: 'tasks.md is complete, dependency-ordered, executable by the loop (no user-in-the-loop task, no STOP HERE gate, last item is an honesty-review Workflow task), and consistent with design (D2-A) + spec (state-based). It covers: state accessor + key threading, test-side state-read replacement of the widget finder, silent-completion update, verification (analyze + live re-runs), and honest-review.',
  },
]

const LENSES = [
  {
    key: 'evidence-fidelity',
    instruction: 'REFUTE on EVIDENCE FIDELITY: the root-cause attribution or the spec/design don\'t match the ACTUAL code/behavior. Read lib/main.dart (completedAssistant usage is in the TEST files, not lib — verify the widget finder is in integration_test/*; check main.dart for turnText/insert/_endStreaming), the integration_test files, sidecar/src/model_gateway.cpp (text_delta→on_chunk), and the logged trace in ~/.aliasagent/logs/sidecar.log (SEARCH for the 00:15 Request #4 text deltas + stop_reason=end_turn + FFI on_done; and the [SHOT] captured 3.3_edit_file.png). Confirm whether the widget-finder-as-cause attribution is actually supported, or whether the real bug is elsewhere (e.g. the app really does NOT store/render, making it a lib bug the change mislabels). Default refuted=true if uncertain.',
  },
  {
    key: 'scope-overclaim',
    instruction: 'REFUTE on SCOPE / OVERCLAIM / MISSED REAL BUG: does the change overstate the test-side fix, or MISS a genuine deeper bug (e.g. is there ALSO an app-level bug where a reply is stored but NOT reliably rendered in the real UI, which the "decouple from rendering" framing would wrongly paper over by reading state instead of fixing the render? Is a lib state-getter (D2-A) actually needed/justified, or is it over-engineering when a test-side robust scan would suffice? Is any honest-fail behavior weakened?). Default refuted=true if uncertain.',
  },
  {
    key: 'consistency-completeness',
    instruction: 'REFUTE on CONSISTENCY / COMPLETENESS: are proposal, design, specs delta, and tasks mutually consistent and complete (no contradiction between them, no missing scenario/requirement, no dangle to the existing live-ui-tests spec)? Is the spec MODIFIED header/name EXACT (whitespace-insensitive) matching openspec/specs/live-ui-tests/spec.md? Is anything in the delta that would break the archive/sync? Default refuted=true if uncertain.',
  },
]

function skepticPrompt(claim, lens) {
  return (
    'You are an adversarial reviewer in working dir ' + CWD + '. Your ONLY job is to REFUTE the following claim about the change ' + CHANGE + ', not to confirm it. Default to refuted=true if uncertain. ' +
    lens.instruction + ' ' +
    'Read these to check: ' + CHANGE + '/proposal.md, ' + CHANGE + '/design.md, ' + CHANGE + '/specs/live-ui-tests/spec.md, ' + CHANGE + '/tasks.md, ' +
    'integration_test/real_api_test.dart, integration_test/live_file_tools_test.dart, integration_test/live_observability.dart, ' +
    'lib/main.dart (read-only), sidecar/src/model_gateway.cpp (read-only), openspec/specs/live-ui-tests/spec.md (existing), ' +
    'and the sidecar log at ~/.aliasagent/logs/sidecar.log (grep for the 00:15 Request #4 text deltas + stop_reason + [SHOT] 3.3_edit_file.png). You may also Read test/live_visual/3.3_edit_file.png to confirm the bubble was rendered. No network. ' +
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
    verdict: survives ? 'SURVIVED (change correct/consistent/in-scope)' : 'KILLED (refuted — change has a real problem)',
    refuteCount: refutes.length,
    surviveCount: votes.length - refutes.length,
    skepticVotes: votes.map((v) => ({ lens: v.lens, refuted: v.refuted, reasoning: v.reasoning })),
  })
}

log('Review: refuted ' + verdicts.length + ' skeptic-votes across ' + CLAIMS.length + ' claims; survivors: ' + results.filter((r) => r.verdict.startsWith('SURVIVED')).length)
return { perClaim: results }
