export const meta = {
  name: 'honesty-review-handle-empty-assistant-reply-round2',
  description: 'Adversarial honesty review round 2 (verify round-1 fixes, A-G regression, record honesty)',
  phases: [
    { title: 'Verify', detail: '3 adversarial agents verify round-1 fixes and regressions' },
    { title: 'Synthesize', detail: 'Collect and rank confirmed findings' },
  ],
}

const FINDINGS_SCHEMA = {
  type: 'object',
  required: ['verdict', 'findings'],
  properties: {
    verdict: { type: 'string', enum: ['CLEAN', 'ISSUES_FOUND'] },
    findings: {
      type: 'array',
      items: {
        type: 'object',
        required: ['severity', 'title', 'detail', 'file', 'line'],
        properties: {
          severity: { type: 'string', enum: ['HIGH', 'MEDIUM', 'LOW'] },
          title: { type: 'string' },
          detail: { type: 'string' },
          file: { type: 'string' },
          line: { type: 'integer' },
        },
      },
    },
  },
}

const CWD = 'E:/Projects/AliasAgent'

phase('Verify')

const dims = [
  {
    key: 'round1-fixes',
    prompt:
      'You are an adversarial reviewer verifying that 4 documented fixes from round-1 review were actually applied. Working dir ' + CWD + '. ' +
      'The change is openspec/changes/handle-empty-assistant-reply/. ' +
      'Fix 1 (tasks 6.3): design.md must tag the pre-apply review finding F - the D4 section heading or body must carry "(审查 finding F)", and the Non-Goals line about not weakening assertions must carry "(审查 finding F)". ' +
      'Fix 2 (tasks 6.4): specs/live-ui-tests/spec.md Test timeout scenario WHEN must now also cover "streaming was never observed during the wait" (not only isStreaming==true), and design.md D4 must mirror it. ' +
      'Fix 3 (tasks 6.5): design.md Migration Plan step 1 must reference the jumpTo(maxScrollExtent) mechanism for the D3 restore, NOT reverse drags. ' +
      'Fix 4 (tasks 6.6): design.md Context section must contain a working-tree transparency note mentioning the uncommitted sibling change add-live-test-observability sharing real_api_test.dart and live_observability.dart. ' +
      'Read design.md and specs/live-ui-tests/spec.md to verify each fix is actually present and correctly worded. Report any missing/incorrect fix with file:line. If all four fixes are correctly applied, verdict CLEAN.',
    phase: 'Verify',
  },
  {
    key: 'ag-regression',
    prompt:
      'You are an adversarial regression reviewer. Working dir ' + CWD + '. ' +
      'The round-1 fixes were documentation-only edits to openspec/changes/handle-empty-assistant-reply/design.md and specs/live-ui-tests/spec.md. Verify these doc edits did NOT regress the code-level findings A-G from the pre-apply review, and that the CODE is unchanged from the round-1 review: ' +
      'A streaming-start guard (sawStreaming) in pumpUntilReplyOrTurnDone; ' +
      'B silent completion goes to fail with an attributable message naming model empty reply or internal exception (not skip); ' +
      'C 500ms error-path grace re-check; ' +
      'D 3.3 test-file cleanup in silent and hang branches; ' +
      'E defensive D3 restore (empty-finder check, controller null and hasClients check, try/catch) using jumpTo not reverse drags; ' +
      'F spec self-consistency (Test timeout widened AND Silent completion not contradicting Internal-bugs-SHALL-fail, assertions not weakened); ' +
      'G cross-suite side-effect documented in design. ' +
      'Read integration_test/real_api_test.dart, integration_test/live_observability.dart, and design.md. Confirm A-G all intact. Also confirm that the ONLY changes since round-1 are the four doc edits (Bash git diff if useful - but note live_observability.dart is untracked; compare content for the jumpTo restore). ' +
      'Report any regression with file:line. If all intact, verdict CLEAN.',
    phase: 'Verify',
  },
  {
    key: 'record-honesty',
    prompt:
      'You are an adversarial honesty reviewer. Working dir ' + CWD + '. ' +
      'Read openspec/changes/handle-empty-assistant-reply/tasks.md and verify the task statuses are honest and match reality. Specifically: ' +
      '(1) 6.3-6.6 are marked [x] only because the four doc fixes were actually made (cross-check design.md and specs/live-ui-tests/spec.md). ' +
      '(2) 6.1 is [x] with an honest record of round-1 (5 agents, 4 LOW findings). ' +
      '(3) 6.7 is still [ ] (round-2 review not yet done). ' +
      '(4) 5.1 and 5.2 records are honest: 5.1 documents the 3-run comparison (drag-restore failed, baseline passed, jumpTo passed) and 5.2 documents +3 -1 with 3.3 failing via the designed silent-completion honest attribution, not a fabricated pass. ' +
      '(5) No checked task hides a failure or weakens an acceptance criterion. ' +
      'Also confirm the last appended task (6.7) is a review task (honesty-review loop requirement). ' +
      'Report any dishonesty or mismatch with file:line. If all honest, verdict CLEAN.',
    phase: 'Verify',
  },
]

const results = await parallel(dims.map((d) => () =>
  agent(d.prompt, { label: 'verify:' + d.key, phase: 'Verify', schema: FINDINGS_SCHEMA })
))

phase('Synthesize')
const confirmed = []
for (const r of results) {
  if (!r) continue
  if (r.verdict === 'ISSUES_FOUND') {
    for (const f of r.findings) confirmed.push(f)
  }
}
log('Verified ' + results.filter(Boolean).length + '/3 dimensions; ' + confirmed.length + ' findings')
return {
  confirmed,
  perDimension: results.map((r) => r ? { verdict: r.verdict, count: r.findings.length } : { verdict: 'SKIPPED', count: 0 }),
}
