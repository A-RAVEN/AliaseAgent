export const meta = {
  name: 'review-fix-live-test-reply-detection-v2',
  description: 'Round-2 adversarial review of the REVISED change (switched to test-side robust reply scan, zero lib; spec uniform; honest-fail preserved). N REFUTING skeptics, perspective-diverse, majority-kill.',
  phases: [
    { title: 'Refute', detail: '3 skeptics refute each of 4 revised claims (default refuted=true)' },
    { title: 'Vote', detail: 'Majority-kill: survives if <majority refute' },
  ],
}

const CWD = 'E:/Projects/AliasAgent'
const CHANGE = 'openspec/changes/fix-live-test-reply-detection'

const REFUTE_SCHEMA = {
  type: 'object',
  required: ['refuted', 'reasoning'],
  properties: {
    refuted: { type: 'boolean', description: 'true if you REFUTED the revised claim' },
    reasoning: { type: 'string' },
  },
}

const CLAIMS = [
  {
    id: 'V1',
    task: 'root-cause + revised fix direction (robust detection, not lib)',
    claim: 'REVISED root cause and fix are correct and minimal: the false-fail on 3.3 was the test\'s naive one-shot `completedAssistant` widget scan missing a reply that the app had already stored (main.dart:906 turnText.isNotEmpty → insert, before _endStreaming at :924) AND rendered (3.3_edit_file.png shows the full Assistant bubble). Fix = test-side ROBUST reply detection (pump to frame stability + scroll the chat list, mirroring the existing `_scanToolCards` in live_observability.dart:43-91), NOT a lib change. The app needs no change (it stores+renders correctly); only the test\'s detection must be robust to ListView lazy-build/recycle.',
  },
  {
    id: 'V2',
    task: 'revised design avoids the round-1 defects (no ChatScreenState, no non-compiling getter, no lib, no over-eng)',
    claim: 'REVISED design.md is sound and fixes the round-1 defects: it abandons the lib state-getter + GlobalKey approach (no reference to a non-existent public `ChatScreenState` — the State is private `_ChatScreenState` at main.dart:151; no `GlobalKey<ChatScreenState>` that can\'t compile; no `m.role`/`m.content` on ChatMessageItem which live on `.message`). It settles on D2-C (test-side robust scan), keeps zero lib/main.dart change (consistent with proposal "不涉及 lib/ 行为改动"), and keeps render for the visual-acceptance screenshot (D3) while detection robustly confirms the reply (D1/D4).',
  },
  {
    id: 'V3',
    task: 'revised spec is UNIFORM (no dangling render-vs-state contradiction) and honest-fail preserved',
    claim: 'REVISED specs/live-ui-tests/spec.md is internally consistent and complete: reply detection is framed as ROBUST render detection (pump+scroll before concluding absence), which is compatible with the unchanged "Tool call via UI conversation" requirement\'s "a completed assistant MessageBubble SHALL appear" (no state-vs-render contradiction — the round-1 dangling gap is resolved). The "Silent completion" scenario now requires the test to do robust detection FIRST, then fail only if still no reply (preserving the honest-fail on a genuine empty reply / internal exception, with the [OBS] evidence dump). No acceptance criterion is degraded.',
  },
  {
    id: 'V4',
    task: 'revised tasks are test-side only + complete/executable',
    claim: 'REVISED tasks.md is test-side ONLY (no lib/main.dart task), complete, dependency-ordered, executable by the loop, has NO user-in-the-loop task, NO STOP HERE gate, and ends with a Workflow honesty-review task. It covers: robust reply-scan helper in live_observability.dart (1.x), switching real_api_test 3.1-3.4 + live_file_tools t1-t4 to robust detection (2.x), silent-completion robust-first judgment (3.x), verification (analyze + live re-runs + screenshot)(4.x), and honesty review (5.x).',
  },
]

const LENSES = [
  {
    key: 'evidence-fidelity',
    instruction: 'REFUTE on EVIDENCE FIDELITY: does the revised change match the ACTUAL code/behavior? Read integration_test/real_api_test.dart, integration_test/live_file_tools_test.dart, integration_test/live_observability.dart (does `_scanToolCards` really exist and scroll+restore, so the robust-scan claim holds?), lib/main.dart (turnText/insert/_ChatScreenState privacy — confirm `_ChatScreenState` is private and there is NO public `ChatScreenState`; confirm ChatMessageItem has `.message` not `.role`/.content), ~/.aliasagent/logs/sidecar.log (Request #4 text deltas + stop_reason=end_turn), test/live_visual/3.3_edit_file.png (bubble rendered). Confirm the revised framing is accurate. Default refuted=true if uncertain.',
  },
  {
    key: 'scope-overclaim',
    instruction: 'REFUTE on SCOPE / OVERCLAIM / MISSED REAL BUG: does the revised change (a) really make ZERO lib/main.dart change (grep the tasks + design for any lib task/getter/GlobalKey — there must be none), (b) avoid over-engineering (robust scan is test-side + mirrors an existing helper, not a new lib hook), (c) not MISS a deeper bug (e.g. would a robust scan still paper over a case where the app stores but never renders? Is that realistically possible given the screenshot? Does the honest-fail still fire on a genuine empty reply/internal exception, incl. for multi-turn tool flows where intermediate assistant text might exist — main.dart:936-948)? Default refuted=true if uncertain.',
  },
  {
    key: 'consistency-completeness',
    instruction: 'REFUTE on CONSISTENCY / COMPLETENESS: are proposal, design, specs delta, tasks mutually consistent and complete (no contradiction, no dangling to the existing live-ui-tests spec, no missing scenario, no leftover A/B/C open-question that contradicts the settled decision, no reference to the removed lib approach)? Is the MODIFIED header/name exact vs openspec/specs/live-ui-tests/spec.md? Default refuted=true if uncertain.',
  },
]

function skepticPrompt(claim, lens) {
  return (
    'You are an adversarial reviewer in working dir ' + CWD + '. Your ONLY job is to REFUTE the following claim about the REVISED change ' + CHANGE + '. Default to refuted=true if uncertain. ' +
    lens.instruction + ' ' +
    'Read: ' + CHANGE + '/proposal.md, ' + CHANGE + '/design.md, ' + CHANGE + '/specs/live-ui-tests/spec.md, ' + CHANGE + '/tasks.md, ' +
    'integration_test/real_api_test.dart, integration_test/live_file_tools_test.dart, integration_test/live_observability.dart, lib/main.dart (Read: main.dart@~906 turnText/insert, @~936-948 intermediate-text insert, @~148/151 _ChatScreenState privacy), lib/models/chat_item.dart (ChatMessageItem has .message), openspec/specs/live-ui-tests/spec.md (existing), ~/.aliasagent/logs/sidecar.log (grep 00:15 Request #4 text deltas + stop_reason), test/live_visual/3.3_edit_file.png. No network. ' +
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
    verdict: survives ? 'SURVIVED (revised change correct/consistent/in-scope)' : 'KILLED (refuted — revised change still has a real problem)',
    refuteCount: refutes.length,
    surviveCount: votes.length - refutes.length,
    skepticVotes: votes.map((v) => ({ lens: v.lens, refuted: v.refuted, reasoning: v.reasoning })),
  })
}

log('Review v2: refuted ' + verdicts.length + ' skeptic-votes across ' + CLAIMS.length + ' claims; survivors: ' + results.filter((r) => r.verdict.startsWith('SURVIVED')).length)
return { perClaim: results }
