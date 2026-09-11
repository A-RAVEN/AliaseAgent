export const meta = {
  name: 'review-fix-live-test-reply-detection-v5',
  description: 'Adversarial review of the CURRENT state-read approach (test reads app-exposed finalAssistantReply via tester.state<ChatScreenState>(find.byType(ChatScreen)), NOT GlobalKey). REFUTING skeptics, majority-kill. All verification against LOCAL source only — no network.',
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
    claim: 'The revised test reads the app-exposed final reply via `tester.state<ChatScreenState>(find.byType(ChatScreen)).finalAssistantReply` — it does NOT scan the widget tree / pump+scroll / use a GlobalKey. `finalAssistantReply` is a read-only getter over `_chatItems` returning the content of the `isFinalReply==true` message (or null). This is robust by construction: `_chatItems` is mutated inside `setState()` at the moment the app STORES the reply (main.dart:906-920 final-reply insert; :936-948 intermediate insert; _storeError :1448-1462), which is independent of ListView.builder build/recycle/timing. So: (a) model produced a non-empty final reply → getter non-null → detected (fixes the 3.3 false-fail where the bubble was momentarily unbuilt); (b) empty final reply / internal exception → getter null → silent-completion honest-fail fires; (c) an INTERMEDIATE tool-round text bubble is marked isFinalReply==false and is never exposed as final, so it cannot mask an empty final reply — the honest-fail hole is genuinely closed (unlike a widget scan or terminal-item heuristic).',
  },
  {
    id: 'S2',
    task: 'app changes minimal/observability-only + compile-correct; no behavior change',
    claim: 'App-side changes are minimal and do NOT change conversation/storage/render/streaming behavior: (1) `ChatMessageItem` gains `final bool isFinalReply` (default false) in lib/models/chat_item.dart; (2) in lib/main.dart the private `_ChatScreenState` is renamed to public `ChatScreenState` (line 151) and `ChatScreen.createState()` returns `ChatScreenState()` (line 148); (3) a read-only `String? get finalAssistantReply` iterates `_chatItems`, selecting the `ChatMessageItem` with `isFinalReply==true` whose `.message.content.trim().isNotEmpty`, returning it or null (note `ChatMessageItem.message` is a `Message` with a non-null `.content`); (4) markers: final-reply insert ~906-920 → true, intermediate insert ~936-948 → false, `_storeError` Error-reply insert ~1448-1462 → true. `tester.state<ChatScreenState>` compiles because `ChatScreenState` is public and `main.dart` is already imported by the test (real_api_test.dart:13). All changes identify/expose; storage/render/reply logic unchanged. There is exactly one `ChatScreen` in the tree (MyApp→AppShell build returns `ChatScreen(config: _config!)` at main.dart:124), so `find.byType(ChatScreen)` is unique.',
  },
  {
    id: 'S3',
    task: 'spec/design/tasks/proposal consistent + uniform (tester.state), complete',
    claim: 'proposal/design/specs/tasks are mutually consistent and frame reply detection uniformly as "app exposes finalAssistantReply (isFinalReply-marked); test reads it via tester.state<ChatScreenState>(find.byType(ChatScreen)), NO widget scan, NO pump+scroll, NO GlobalKey": the delta spec MODIFIED the three reply-bearing requirements (Basic conversation via UI, Tool call via UI conversation, Error classification and resilience) with the state-read/expose-final-reply wording; the new "Reply detection reads state, not widget rendering" scenario covers the lazy-build/recycle case; honest-fail (empty reply / internal exception) still fires after reading state; the existing ops base spec (openspec/specs/live-ui-tests/spec.md) is the "ADDED" source of those requirement names, so MODIFIED is valid; tasks are complete, ordered, executable by the loop alone (no user-in-the-loop task, no STOP HERE gate), and end with a Workflow honesty-review task.',
  },
]

const LENSES = [
  {
    key: 'evidence-fidelity',
    instruction: 'REFUTE on EVIDENCE FIDELITY — does the state-read mechanism + isFinalReply + tester.state match the ACTUAL app & test code? Read lib/main.dart:133-151 (ChatScreen public, createState returns _ChatScreenState — confirm rename to public ChatScreenState is the one needed change), :100-126 (MyApp/AppShell build returns ChatScreen(config:_config!) — confirm exactly one ChatScreen so find.byType is unique), :904-926 (final-reply insert, turnToolCalls.isEmpty branch), :933-948 (intermediate insert), :1448-1462 (_storeError Error reply — confirm content="Error: <msg>"), lib/models/chat_item.dart:8-11 (ChatMessageItem.message is a Message), lib/models/message.dart:5 (non-null content). Also read integration_test/real_api_test.dart:44-81 (current completedAssistant/latestAssistantText/pumpUntilReplyOrTurnDone widget-based — confirm swapping to state-read is feasible) and integration_test/live_observability.dart. Confirm the FINAL reply (after tool rounds, when turnToolCalls.isEmpty) also flows through :906-920 with isFinalReply true, and intermediate text (:936-948) is isFinalReply false. Confirm that a `Message.content.trim().isNotEmpty` filter cannot drop a real reply. Default refuted=true if uncertain.',
  },
  {
    key: 'scope-overclaim',
    instruction: 'REFUTE on SCOPE / OVERCLAIM / MISSED BUG / HONEST-FAIL HOLE — are the app changes truly behavior-neutral (grep tasks/design for anything beyond isFinalReply + public State + getter + 3 markers — nothing that changes how messages are stored/rendered/streamed)? Is exposing finalAssistantReply via a public State + `tester.state` genuinely the minimal way to read the final reply from state (not over-engineered vs a lighter hook like a ValueNotifier)? Is there any residual honest-fail hole: e.g. an isFinalReply marked true on a path that is NOT the true final reply, OR a genuinely-empty final turn that wrongly leaves isFinalReply true (masking a silent-completion), OR a tool-turn where streaming toggles AND the getter is read mid-round returning null → false silent-completion fail? Is the getter SPEC ambiguous (does it pick FIRST vs LAST isFinalReply — when a session has multiple turns, `_chatItems` holds several isFinalReply messages)? Default refuted=true if uncertain.',
  },
  {
    key: 'consistency-completeness',
    instruction: 'REFUTE on CONSISTENCY / COMPLETENESS — are proposal, design, specs delta, tasks mutually consistent and complete (no contradiction, no dangling to the existing live-ui-tests spec, all reply-detection requirements touched uniformly, NO leftover GlobalKey/pump+scroll/termination-item approach contradicting the settled tester.state decision)? Is the delta spec "## MODIFIED Requirements" header + the exact requirement names (Basic conversation via UI / Tool call via UI conversation / Error classification and resilience) a valid modification of the existing requirements in openspec/specs/live-ui-tests/spec.md? Do design D2 / proposal "What Changes" / tasks §1.2 all describe the SAME mechanism (tester.state via find.byType, not GlobalKey)? Are tasks complete, executable by the loop alone, no user-in-the-loop, no STOP HERE gate, ending in a Workflow honesty-review task? Default refuted=true if uncertain.',
  },
]

function skepticPrompt(claim, lens) {
  return (
    'You are an adversarial reviewer in working dir ' + CWD + '. Your ONLY job is to REFUTE the following claim about the change ' + CHANGE + '. Default to refuted=true if uncertain. ' +
    lens.instruction + ' ' +
    'IMPORTANT CONSTRAINTS: You have NO network access and MUST NOT use MCP tools, WebSearch, WebFetch, or any HTTP fetch. Verify everything against LOCAL files only (Read/Grep the repo). The change does NOT introduce or depend on any external provider API parameter/field, so Docs/*.md are NOT the verification source here — the ground truth is the actual local app + test source. If a claim references a file:line, Read it and confirm. ' +
    'Read: ' + CHANGE + '/proposal.md, ' + CHANGE + '/design.md, ' + CHANGE + '/specs/live-ui-tests/spec.md, ' + CHANGE + '/tasks.md, ' +
    'lib/main.dart, lib/models/chat_item.dart, lib/models/message.dart, integration_test/real_api_test.dart, integration_test/live_file_tools_test.dart, integration_test/live_observability.dart, openspec/specs/live-ui-tests/spec.md (existing). ' +
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

log('Final v5: ' + verdicts.length + ' skeptic-votes across ' + CLAIMS.length + ' claims; survivors: ' + results.filter((r) => r.verdict.startsWith('SURVIVED')).length)
return { perClaim: results }
