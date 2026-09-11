export const meta = {
  name: 'review-fix-live-test-reply-detection-v6',
  description: 'Verify the 3 defect-fixes from v5 (getter=LAST isFinalReply; error-path grace period; bounded honest-fail scope) are present+correct in the reworked artifacts, AND that S1/S2/S3 did not regress. REFUTING skeptics, majority-kill, LOCAL-source-only.',
  phases: [
    { title: 'Refute', detail: '3 skeptics refute each of 4 claims (default refuted=true)' },
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
    id: 'F1',
    task: 'Rework fixed the getter FIRST/LAST ambiguity — now specifies LAST isFinalReply',
    claim: 'The reworked artifacts now pin the getter to return the LAST `isFinalReply==true && content.trim().isNotEmpty` message content, else null — design D2 step 3 (末位向前扫/最后一个), proposal What Changes step 3 (返回最后一个), tasks 1.2 (最后一个), spec "Application exposes the final assistant reply" (MOST RECENT / last-marked). This is correct for the exercised single-turn live tests (one turn ends with exactly one isFinalReply=true), and unpins the first-vs-last ambiguity that v5 flagged. It cannot drop a genuine reply (Message.content is a non-null String; only whitespace-empty is filtered, which correctly reads as empty). The only residual boundary — a multi-send single-session where a stale earlier final could mask a later empty/Error turn — is explicitly documented as not-exercised/acceptable in design D2 (边界) and Risks.',
  },
  {
    id: 'F2',
    task: 'Rework fixed the error-path ordering race — grace period now specified',
    claim: 'The reworked artifacts now require a bounded grace period before concluding null finalAssistantReply => silent-completion fail on the error path: design D4 (错误路径顺序竞态 bullet: wait a finite grace period eg 500ms before null -> silent-completion), design Migration step 4 (保留 streaming 停后的宽限期), proposal What Changes (判定空回复前须保留宽限期), spec "Silent completion" WHEN (after a bounded grace period eg 500 ms because _endStreaming sets isStreaming=false BEFORE await _storeError inserts the Error reply), tasks 3.1 (streaming 停后可先等一个有限宽限期). This prevents an external error (invalid key / network) — where _endStreaming(:850) runs before the _storeError(:856) insert — from being misclassified as a false silent-completion FAIL instead of the required SKIP. It matches the existing real_api_test.dart:74 grace-period behavior.',
  },
  {
    id: 'F3',
    task: 'Rework bounded the honest-fail scope — no longer overclaims that Error:-prefix internal errors fail',
    claim: 'The reworked artifacts no longer overclaim that the honest-fail hole is closed for Error-prefixed internal errors. They now bound it: design D4 (honest-fail 关闭范围: closes ONLY empty-final + intermediate-masking; "Error:"-prefix incl internal _storeError => skip is pre-existing, not claimed fixed), proposal 诚实边界 (honest-fail 关闭范围不夸大; Error: 前缀含内部 _storeError 仍走 skip, 不宣称修复), spec "Internal bug detected" NOTE (an internal error surfaced via _storeError becomes an "Error:"-prefixed reply classified by the skip scenario — internal-vs-external classification is OUT OF SCOPE). Crucially this is NOT a weakening: the empty-final and intermediate-masking honest-fail (the change headline goal) is still preserved and SHALL fail. Spec was made more accurate, not relaxed.',
  },
  {
    id: 'R1',
    task: 'Regression — original S1/S2/S3 (state-read via tester.state; minimal compile-correct app change; artifacts consistent) still hold after rework',
    claim: 'After the rework edits, the change still: (a) resolves via `tester.state<ChatScreenState>(find.byType(ChatScreen))` with NO widget scan / pump+scroll / GlobalKey for reply detection (the only GlobalKey is the RepaintBoundary captureKey); (b) makes minimal observability-only app changes — ChatMessageItem.isFinalReply (default false), rename _ChatScreenState -> public ChatScreenState (main.dart:148/151), read-only getter reaching Message.content, markers at final (:906-920 true) / intermediate (:936-948 false) / _storeError (:1448-1462 true); single ChatScreen at main.dart:124 so find.byType is unique; (c) keeps proposal/design/spec/tasks mutually consistent with no new contradiction introduced by the fixes — the delta spec still validly MODIFIEDs Basic conversation via UI / Tool call via UI conversation / Error classification and resilience against the base openspec/specs/live-ui-tests/spec.md; tasks complete, no user-in-the-loop, no STOP HERE, ending in a Workflow honesty-review task. No regression to the settled mechanism or scope.',
  },
]

const LENSES = [
  {
    key: 'fix-verification',
    instruction: 'For each claim, REFUTE if the claimed FIX is NOT actually present in the reworked artifacts, OR if it is WRONG/insufficient to close the v5-flagged defect. Read the reworked openspec/changes/fix-live-test-reply-detection/{proposal.md,design.md,tasks.md,specs/live-ui-tests/spec.md} plus the real code lib/main.dart:850/856/906-948/1448-1462 (confirm the error-path ordering when _endStreaming runs before await _storeError, and the async insert gap), lib/main.dart:124 (single ChatScreen), lib/models/chat_item.dart, lib/models/message.dart, integration_test/real_api_test.dart:61-81 (current pumpUntilReplyOrTurnDone grace period at :74). Confirm each fix is genuinely textually present and correct, and that fixing it introduced no contradiction elsewhere. Default refuted=true if uncertain.',
  },
  {
    key: 'honesty-not-weakening',
    instruction: 'For F3 specifically, REFUTE if the honest-fail bounding is actually a WEAKENING of the acceptance criteria (i.e. the change now hides the internal-error-masked-as-skip hole, or removes a previously-asserted honest-fail) rather than an ACCURATE bounding. Also REFUTE any claim that overstates or understates: does the empty-final + intermediate-masking honest-fail still SHALL fail (not silently skipped)? Is the Error:-prefix-skip (incl internal _storeError) now correctly documented as pre-existing/out-of-scope WITHOUT pretending to fix it? Do the app changes stay behavior-neutral (grep for anything beyond isFinalReply + public State + getter + markers)? Default refuted=true if uncertain.',
  },
  {
    key: 'consistency-regression',
    instruction: 'REFUTE on REGRESSION / CONSISTENCY: after the rework, are the 4 artifacts mutually consistent with NO dangling contradiction (no leftover first/any-isFinalReply wording, no leftover pump+scroll/GlobalKey for reply detection, no claim that internal _storeError errors fail)? Are spec/tasks/design D2-D4 now internally consistent (design D2 getter=last vs D4 silent-completion vs spec Silent-completion grace period all align)? Is the delta spec still a valid MODIFIED against the base spec with no weakened requirement? Do tasks 1.2/3.1/5.1 match the corrected design? Default refuted=true if uncertain.',
  },
]

function skepticPrompt(claim, lens) {
  return (
    'You are an adversarial reviewer in working dir ' + CWD + '. Your ONLY job is to REFUTE the following claim about the change ' + CHANGE + '. Default to refuted=true if uncertain. ' +
    lens.instruction + ' ' +
    'IMPORTANT CONSTRAINTS: You have NO network access and MUST NOT use MCP tools, WebSearch, WebFetch, or any HTTP fetch. Verify against LOCAL files only. The change introduces no external provider API parameter/field, so Docs/*.md are NOT the verification source — ground truth is the actual local app + test source. Read the reworked artifacts + real source line ranges and confirm. ' +
    'Read: ' + CHANGE + '/proposal.md, ' + CHANGE + '/design.md, ' + CHANGE + '/tasks.md, ' + CHANGE + '/specs/live-ui-tests/spec.md, ' +
    'lib/main.dart (working copy is NOT modified by this change — the artifacts propose the change; verify the code matches the claimed insert points/ordering), lib/models/chat_item.dart, lib/models/message.dart, integration_test/real_api_test.dart, integration_test/live_observability.dart, openspec/specs/live-ui-tests/spec.md (existing). ' +
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

log('Final v6: ' + verdicts.length + ' skeptic-votes across ' + CLAIMS.length + ' claims; survivors: ' + results.filter((r) => r.verdict.startsWith('SURVIVED')).length)
return { perClaim: results }
