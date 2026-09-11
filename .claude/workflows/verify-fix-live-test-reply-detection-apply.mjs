export const meta = {
  name: 'verify-fix-live-test-reply-detection-apply',
  description: 'Honesty review (task 5.1) of the APPLIED change: verify the real code matches design, honest-fail is preserved (not weakened), no over-scope, and the live tests genuinely passed. REFUTING skeptics, majority-kill, LOCAL-source-only.',
  phases: [
    { title: 'Refute', detail: '3 skeptics refute each of 4 claims (default refuted=true)' },
    { title: 'Vote', detail: 'Majority-kill: survives if <majority refute' },
  ],
}

const CWD = 'E:/Projects/AliasAgent'
const CHANGE = 'openspec/changes/fix-live-test-reply-detection'
const OUT_42 = 'C:/Users/76956/AppData/Local/Temp/claude/E--Projects-AliasAgent/16949a6b-d0a4-4556-9d11-4deab35717e3/tasks/bff7m253z.output'
const OUT_43 = 'C:/Users/76956/AppData/Local/Temp/claude/E--Projects-AliasAgent/16949a6b-d0a4-4556-9d11-4deab35717e3/tasks/bxk5bnvgz.output'

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
    id: 'A1',
    task: 'App implementation matches the design (isFinalReply + public State + getter) and compiles clean',
    claim: 'The applied app change matches design D2: (1) lib/models/chat_item.dart ChatMessageItem gained `final bool isFinalReply` with default false; (2) lib/main.dart renamed `_ChatScreenState` to public `ChatScreenState` (createState and class decl), and added a read-only `String? get finalAssistantReply` that scans `_chatItems.reversed` for the FIRST item matching `isFinalReply==true && message.content.trim().isNotEmpty` and returns its content, else null; (3) markers set `isFinalReply: true` at the no-tool final-reply insert (ChatMessageItem(assistantMsg)) and at _storeError (ChatMessageItem(errorMsg)), while the intermediate tool-round insert (ChatMessageItem(intermediateMsg)) keeps the default false. flutter analyze shows ZERO new issues in the five changed files (the only lib warning, main.dart:1307 unused `nsCount`, is pre-existing and untouched by this change).',
  },
  {
    id: 'A2',
    task: 'Test implementation matches design: readFinalAssistantReply + state-read pumpUntilReplyOrTurnDone + graceful classification',
    claim: 'The applied test change matches design D2/D4: integration_test/live_observability.dart gained `String? readFinalAssistantReply(WidgetTester)` which guards `find.byType(ChatScreen).evaluate()` (returns null when not yet mounted) then returns `tester.state<ChatScreenState>(find.byType(ChatScreen)).finalAssistantReply`; integration_test/real_api_test.dart rewrote `pumpUntilReplyOrTurnDone` to read state (`readFinalAssistantReply(tester) != null` => normal/Error reply) and to wait a 500ms grace period after streaming stops before concluding silent-completion (accounting for _endStreaming running before _storeError insert); both real_api_test.dart and live_file_tools_test.dart replaced the one-shot widget scan (`completedAssistant`/`latestAssistantText`) with `readFinalAssistantReply` and removed the now-unused helpers and the unused message_bubble.dart import. Error: prefix => markTestSkipped, non-empty non-Error => pass, null => silent-completion fail ([OBS] dump then fail) are preserved.',
  },
  {
    id: 'A3',
    task: 'Honest-fail preserved (NOT weakened), spec intact, no over-scope',
    claim: 'The change does NOT weaken honesty or the spec. Silent completion (streaming stops, finalAssistantReply null after grace, not Error: prefixed) SHALL fail with an attributable message plus an [OBS] dump — it is not skipped (since the empty-reply branch `if (readFinalAssistantReply(tester) == null)` fails, and the Error:-prefix branch only skips on a genuine Error reply). Error:-prefix replies (including internal errors surfaced via _storeError) still classify to skip — documented as pre-existing/out-of-scope in design D4 / proposal 诚实边界 / spec Internal-bug-detected NOTE, not claimed fixed. The getter scans from the END so it returns the most recent final reply, avoiding a stale earlier final masking the current empty/Error turn in the exercised single-turn tests. The spec delta preserves fail-not-skip and skip-on-Error semantics; no scenario was weakened or deleted. Scope stays minimal: only the two lib files + three integration_test files; no C++ sidecar change, no new dependency, no conversation/storage/rendering behavior change.',
  },
  {
    id: 'A4',
    task: 'Live tests genuinely passed (not fabricated) — 3.3 false-fail is fixed',
    claim: 'Both live suites genuinely passed with real evidence (no hidden/skipped test fabricating a pass): real_api_test.dart (4.2) exited 0 and printed "+4: All tests passed!"; 3.3 printed "[TEST] Assistant replied after edit_file" (the model reply detected via state read) and "[TEST] File edit verified"; 3.4 printed "REALTIME-DELTA ... PASS" and "Reply after thinking"; the screenshot 3.3_edit_file.png (58KB) clearly renders the full Assistant reply bubble plus Done edit_file/read_file cards. live_file_tools_test.dart (4.3) exited 0 and printed "+4: All tests passed!", with Test 3 ("countA DONE, countB preserved") and Test 4 ("glob_file returned src/a.dart + src/b.dart") plus per-file [OBS] dumps. The prior 3.3 false-fail (reply stored+rendered but one-shot widget finder missed it) is resolved by reading state.',
  },
]

const LENSES = [
  {
    key: 'implementation-fidelity',
    instruction: 'REFUTE on IMPLEMENTATION FIDELITY: does the ACTUAL applied code match the claim? Read lib/main.dart (public ChatScreenState at ~148/151, the finalAssistantReply getter, the isFinalReply:true at the no-tool final insert and at _storeError, and that the intermediate insert does NOT set it true), lib/models/chat_item.dart (isFinalReply default false), integration_test/live_observability.dart (readFinalAssistantReply via tester.state<ChatScreenState>(find.byType(ChatScreen))), integration_test/real_api_test.dart (pumpUntilReplyOrTurnDone reads state + 500ms grace; classification), integration_test/live_file_tools_test.dart (uses readFinalAssistantReply, helpers removed). Confirm no hidden defect in the getter logic (reversed iteration, is ChatMessageItem check, content.trim().isNotEmpty) and that message_bubble.dart import removal did not break compilation. Default refuted=true if uncertain.',
  },
  {
    key: 'honesty-not-weakening',
    instruction: 'REFUTE on HONESTY / NOT-WEAKENING: does the applied change mask any failure - specifically, could an empty final reply be silently treated as pass, or a genuine internal bug be skipped without honest acknowledgement? Trace the real_api_test.dart 3.1-3.4 flow: after pumpUntilReplyOrTurnDone, the code does `if (readFinalAssistantReply(tester) == null) { dumpToolCards; fail(...) }` then classifies Error: -> skip / else -> expect non-empty. Confirm an empty final (getter null) still FAILS (not skip), and that the Error:-skip path only triggers on a genuine "Error:"-prefixed reply. Confirm the getter-last semantics cannot make a stale earlier non-empty final mask the current empty turn in these single-turn tests. Confirm no scenario in the delta spec was weakened or deleted, and that the internal-via-_storeError skip is honestly documented as pre-existing/out-of-scope (not silently redeemed). Default refuted=true if uncertain.',
  },
  {
    key: 'evidence-honesty',
    instruction: 'REFUTE on EVIDENCE / TRUE-PASS: are the live test results as claimed? Read the output files ' + OUT_42 + ' and ' + OUT_43 + '. Confirm both show "All tests passed!" and exit 0, and that the claimed per-test evidence appears (3.3 [TEST] Assistant replied after edit_file + File edit verified; 3.4 Reply after thinking; Test 3 countA DONE/ countB preserved; Test 4 glob_file returned src/a.dart+src/b.dart). Confirm the count "+4" means 4 passed with no skipped tests being counted as pass. Also Read test/live_visual/3.3_edit_file.png to confirm the reply bubble is genuinely rendered. Default refuted=true if uncertain or if the evidence is absent.',
  },
]

function skepticPrompt(claim, lens) {
  return (
    'You are an adversarial reviewer in working dir ' + CWD + '. Your ONLY job is to REFUTE the following claim about the APPLIED change ' + CHANGE + '. Default to refuted=true if uncertain. ' +
    lens.instruction + ' ' +
    'IMPORTANT CONSTRAINTS: You have NO network access and MUST NOT use MCP tools, WebSearch, WebFetch, or any HTTP fetch. Verify against LOCAL files only. The change introduces no external provider API parameter/field, so Docs/*.md are NOT the verification source. ' +
    'Read the ACTUAL modified source: lib/main.dart, lib/models/chat_item.dart, integration_test/live_observability.dart, integration_test/real_api_test.dart, integration_test/live_file_tools_test.dart, and the change artifacts ' + CHANGE + '/{proposal.md,design.md,tasks.md,specs/live-ui-tests/spec.md}, and the live-test output files ' + OUT_42 + ' and ' + OUT_43 + ', and test/live_visual/3.3_edit_file.png. ' +
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

log('Final apply-verify: ' + verdicts.length + ' skeptic-votes across ' + CLAIMS.length + ' claims; survivors: ' + results.filter((r) => r.verdict.startsWith('SURVIVED')).length)
return { perClaim: results }
