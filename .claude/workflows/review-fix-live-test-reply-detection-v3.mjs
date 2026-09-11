export const meta = {
  name: 'review-fix-live-test-reply-detection-v3',
  description: 'Round-4 wrap-up adversarial review: termination-item detection closes the honest-fail hole; spec/design/tasks consistent + zero lib. REFUTING skeptics, majority-kill.',
  phases: [
    { title: 'Refute', detail: '3 skeptics refute each of 3 claims (default refuted=true)' },
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
    id: 'T1',
    task: 'termination-item detection closes honest-fail hole (intermediate text)',
    claim: 'The revised detection ("the conversation\'s terminal item is a non-empty assistant MessageBubble") CORRECTLY closes the honest-fail hole: (a) if the model emits a non-empty final reply, the app appends it as the LAST chat item (main.dart:906 turnText.isNotEmpty → :910 insert → :920 _chatItems.add, after all tool cards; streaming item removed at :887) → terminal item = reply → detection hits. (b) If the FINAL reply is empty/missing or an internal exception ends the turn, the app does NOT append a reply (main.dart:906 guard) → the terminal item is the last tool card / thinking card (not a reply) → detection returns "no reply" → silent-completion fail (honest). (c) An INTERMEDIATE tool-turn text bubble (main.dart:936-948) is ALWAYS followed by further tool_use → a tool card, so it is NEVER the terminal item → it cannot mask an empty final reply. Hence honest-fail is robust for multi-turn tool flows, and no turn-boundary counting is needed.',
  },
  {
    id: 'T2',
    task: 'spec/design/tasks consistent + uniform + honest-fail preserved',
    claim: 'The revised change is internally consistent and complete: proposal/design/specs/tasks all frame reply detection as the robust "terminal item = non-empty assistant reply" scan (test-side, mirroring _scanToolCards); the delta spec MODIFIED all three reply-detection-bearing requirements (Basic conversation, Tool call via UI conversation, Error classification/Silent completion) uniformly with robust-detection language; no dangling render-vs-state contradiction (robust detection is compatible with the unchanged "MessageBubble SHALL appear" acceptance, since it reliably detects the rendered reply); honest-fail (empty reply / internal exception) still fires after robust detection; zero lib/main.dart change; no over-engineering.',
  },
  {
    id: 'T3',
    task: 'no leftover defect, no overclaim, executable',
    claim: 'The revised artifacts retain NO round-1/mid defects: no reference to a non-existent public ChatScreenState (State is private _ChatScreenState at main.dart:151); no non-compiling getter (m.role/m.content on ChatMessageItem which really has .message); no proposal-vs-tasks lib contradiction (all test-side, no lib/main.dart task); no leftover A/B/C as an unsettled decision (D2 settles on C/termination-item, A/B rejected with rationale); tasks are complete, dependency-ordered, executable by the loop, no user-in-the-loop task, no STOP HERE gate, ends with a Workflow honesty-review task; the design does not overclaim honest-fail beyond what termination-item detection delivers.',
  },
]

const LENSES = [
  {
    key: 'evidence-fidelity',
    instruction: 'REFUTE on EVIDENCE FIDELITY: does the termination-item mechanism match the ACTUAL app behavior? Read lib/main.dart (the no-tool-call success path ~:904-926: insert only if turnText.isNotEmpty, before _endStreaming; the streaming-item removal at :887; the intermediate-text insert at :936-948 gated by turnText.isNotEmpty), lib/ui/chat_area.dart (ListView.builder + ChatMessageItem→MessageBubble, isStreaming default false), chat_item.dart/message_bubble.dart (fields). Confirm that the final reply truly becomes (or, if empty, does NOT become) the last item, and that an intermediate text bubble is always followed by a tool card. Also check the 3.3_edit_file.png and sidecar.log Request #4 (terminates in a reply, end_turn) and that Requests #1-3 (tool rounds) carry NO text. Default refuted=true if uncertain.',
  },
  {
    key: 'scope-overclaim',
    instruction: 'REFUTE on SCOPE / OVERCLAIM / MISSED BUG: is the termination-item detection over-engineered OR does it MISS a real case (e.g. could a thinking card be the terminal item after a reply, breaking detection? could the app append a reply NOT as the last item? is there any path where a genuinely-empty final turn leaves a non-empty assistant text as the terminal item)? Is there any residual honest-fail hole? Is zero-lib truly maintained (grep tasks/design for any lib getter/GlobalKey/main.dart edit)? Does the change OVERCLAIM what termination-item detection actually guarantees? Default refuted=true if uncertain.',
  },
  {
    key: 'consistency-completeness',
    instruction: 'REFUTE on CONSISTENCY / COMPLETENESS: are proposal, design, specs delta, tasks mutually consistent and complete (no contradiction, no dangling to the existing live-ui-tests spec, all reply-detection requirements touched uniformly, no leftover A/B/C as an open unsettled decision that contradicts the settled C/termination-item)? Is the MODIFIED header/name exact vs openspec/specs/live-ui-tests/spec.md? Default refuted=true if uncertain.',
  },
]

function skepticPrompt(claim, lens) {
  return (
    'You are an adversarial reviewer in working dir ' + CWD + '. Your ONLY job is to REFUTE the following claim about the change ' + CHANGE + '. Default to refuted=true if uncertain. ' +
    lens.instruction + ' ' +
    'Read: ' + CHANGE + '/proposal.md, ' + CHANGE + '/design.md, ' + CHANGE + '/specs/live-ui-tests/spec.md, ' + CHANGE + '/tasks.md, ' +
    'integration_test/real_api_test.dart, integration_test/live_file_tools_test.dart, integration_test/live_observability.dart, ' +
    'lib/main.dart (~:887 streaming-item removal, ~:904-926 no-tool-call insert, ~:936-948 intermediate-text insert), lib/ui/chat_area.dart (ListView.builder → MessageBubble), lib/models/chat_item.dart, lib/models/message_bubble.dart, openspec/specs/live-ui-tests/spec.md (existing), ~/.aliasagent/logs/sidecar.log (00:15 Request #4 text + end_turn; Requests #1-3 no text), test/live_visual/3.3_edit_file.png. No network. ' +
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
    verdict: survives ? 'SURVIVED (change correct/consistent/in-scope)' : 'KILLED (refuted — change still has a real problem)',
    refuteCount: refutes.length,
    surviveCount: votes.length - refutes.length,
    skepticVotes: votes.map((v) => ({ lens: v.lens, refuted: v.refuted, reasoning: v.reasoning })),
  })
}

log('Wrap-up v3: refuted ' + verdicts.length + ' skeptic-votes across ' + CLAIMS.length + ' claims; survivors: ' + results.filter((r) => r.verdict.startsWith('SURVIVED')).length)
return { perClaim: results }
