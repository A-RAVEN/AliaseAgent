export const meta = {
  name: 'review-fix-live-test-reply-detection-v4',
  description: 'Final adversarial review of the state-read approach (test reads app-exposed finalAssistantReply via GlobalKey; isFinalReply marker; zero rendering dependency). REFUTING skeptics, majority-kill.',
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
    id: 'S1',
    task: 'state-read finalAssistantReply is correct, zero rendering dep, closes honest-fail hole',
    claim: 'The revised test reads the app-exposed final assistant reply (a `finalAssistantReply` getter that returns the `isFinalReply`-marked message content, or null) via a `GlobalKey<ChatScreenState>` — it does NOT scan the widget tree / pump+scroll. This is robust by construction (reads the state model, independent of ListView build/recycle/timing): (a) if the model produced a non-empty final reply, `finalAssistantReply` is non-null → detected (fixes the 3.3 false-fail); (b) if the final reply is empty or an internal exception ended the turn, `finalAssistantReply` is null → silent-completion honest-fail fires; (c) an INTERMEDIATE tool-round text bubble is marked `isFinalReply==false` and never exposed as final, so it cannot mask an empty final reply — the honest-fail hole is genuinely closed (unlike a widget scan or terminal-item heuristic, both shown to be fooled).',
  },
  {
    id: 'S2',
    task: 'app changes are minimal/observability-only + compile-correct; no behavior change',
    claim: 'The app-side changes are minimal and do NOT change conversation/storage/render behavior: `ChatMessageItem.isFinalReply`(bool, default false); set `true` only at the final-reply insert (no-tool-call branch, main.dart ~:910-920), `false` for intermediate tool-round text (~:946); rename private `_ChatScreenState` → public `ChatScreenState` and add a read-only `String? get finalAssistantReply`; `ChatScreen` accepts an optional `GlobalKey<ChatScreenState>` threaded via AppShell. `ChatScreenState` now genuinely exists (public), so `GlobalKey<ChatScreenState>` compiles (the round-1 contention is resolved). All changes are identifying/exposing — the app still stores+renders exactly as before.',
  },
  {
    id: 'S3',
    task: 'spec/design/tasks/proposal consistent + uniform (state-read), complete',
    claim: 'proposal/design/specs/tasks are mutually consistent and frame reply detection uniformly as "app exposes finalAssistantReply (isFinalReply); test reads it from state (no widget scan)": the delta spec MODIFIED all three reply-bearing requirements (Basic conversation, Tool call via UI, Error classification/Silent completion) with the state-read/expose-final-reply wording; no dangling render-vs-state contradiction; the "Reply detection reads state, not widget rendering" scenario covers the lazy-build/recycle case; honest-fail (empty reply / internal exception) still fires after reading state; tasks are complete, ordered, executable by the loop, no user-in-the-loop task, no STOP HERE gate, ends with a Workflow honesty-review task.',
  },
]

const LENSES = [
  {
    key: 'evidence-fidelity',
    instruction: 'REFUTE on EVIDENCE FIDELITY: does the state-read mechanism + isFinalReply match the ACTUAL app code? Read lib/main.dart (the no-tool-call final-reply insert ~:904-926, the intermediate-text insert ~:936-948, _ChatScreenState:148/151 privacy, ChatScreen config + AppShell construction), lib/models/chat_item.dart (ChatMessageItem has .message; confirm adding isFinalReply is plausible), lib/ui/chat_area.dart (ChatMessageItem→MessageBubble). Confirm that a `finalAssistantReply` getter over isFinalReply is implementable and that an intermediate tool-round text insert would be marked isFinalReply==false (so not exposed as final). Also confirm the trace/screenshot evidence for 3.3 (Request #4 text+end_turn; 3.3_edit_file.png renders the reply). Default refuted=true if uncertain.',
  },
  {
    key: 'scope-overclaim',
    instruction: 'REFUTE on SCOPE / OVERCLAIM / MISSED BUG: are the app changes truly behavior-neutral (grep tasks/design for any change beyond isFinalReply/getter/key — no change to how messages are stored/rendered/reply logic)? Is exposing `finalAssistantReply` via a public State + GlobalKey threaded through AppShell over-engineered vs a more targeted mechanism (~ValueNotifier / a lighter hook), or is it the genuine minimal way to read the final reply from state? Is there any residual honest-fail hole (e.g. isFinalReply set incorrectly on some path, or a genuinely-empty final turn that still leaves isFinalReply set)? Default refuted=true if uncertain.',
  },
  {
    key: 'consistency-completeness',
    instruction: 'REFUTE on CONSISTENCY / COMPLETENESS: are proposal, design, specs delta, tasks mutually consistent and complete (no contradiction, no dangling to the existing live-ui-tests spec, all reply-detection requirements touched uniformly, no leftover widget-scan/pump+scroll approach contradicting the settled state-read decision)? Is the MODIFIED header/name exact vs openspec/specs/live-ui-tests/spec.md? Default refuted=true if uncertain.',
  },
]

function skepticPrompt(claim, lens) {
  return (
    'You are an adversarial reviewer in working dir ' + CWD + '. Your ONLY job is to REFUTE the following claim about the change ' + CHANGE + '. Default to refuted=true if uncertain. ' +
    lens.instruction + ' ' +
    'Read: ' + CHANGE + '/proposal.md, ' + CHANGE + '/design.md, ' + CHANGE + '/specs/live-ui-tests/spec.md, ' + CHANGE + '/tasks.md, ' +
    'lib/main.dart (final-reply insert ~:904-926; intermediate insert ~:936-948; _ChatScreenState ~:148/151; ChatScreen config ~:124 + AppShell), lib/models/chat_item.dart, lib/ui/chat_area.dart, integration_test/real_api_test.dart, integration_test/live_file_tools_test.dart, integration_test/live_observability.dart, openspec/specs/live-ui-tests/spec.md (existing), ~/.aliasagent/logs/sidecar.log (00:15 Request #4 text + end_turn; #1-3 no text), test/live_visual/3.3_edit_file.png. No network. ' +
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

log('Final v4: refuted ' + verdicts.length + ' skeptic-votes across ' + CLAIMS.length + ' claims; survivors: ' + results.filter((r) => r.verdict.startsWith('SURVIVED')).length)
return { perClaim: results }
