export const meta = {
  name: 'honesty-review-handle-empty-assistant-reply',
  description: 'Adversarial honesty review of handle-empty-assistant-reply apply (round 1)',
  phases: [
    { title: 'Verify', detail: '5 adversarial agents verify independent dimensions' },
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
    key: 'prod-untouched',
    prompt:
      'You are an adversarial honesty reviewer. Working dir ' + CWD + '. ' +
      'Verify claim: the change handle-empty-assistant-reply modified ONLY ' +
      'integration_test/real_api_test.dart, integration_test/live_observability.dart, ' +
      'and openspec/changes/handle-empty-assistant-reply/ artifacts. ' +
      'NO production code (lib/) and NO C++ sidecar (sidecar/) were touched by this change. ' +
      'Use Bash git diff and Bash git status to check which files changed, and read the change artifacts. ' +
      'Confirm no lib/ or sidecar/ file appears in the change. ' +
      'ALSO verify test assertions were NOT weakened: read integration_test/real_api_test.dart and confirm ' +
      'the 4 tests still assert isNotNull/isNotEmpty on assistant text, and 3.3 still asserts file content ' +
      'contains LINE TWO MODIFIED. Report any HIGH/MEDIUM/LOW finding with file:line. ' +
      'If nothing found, verdict CLEAN.',
    phase: 'Verify',
  },
  {
    key: 'helper-correctness',
    prompt:
      'You are an adversarial correctness reviewer. Working dir ' + CWD + '. ' +
      'Read integration_test/real_api_test.dart in full. Verify the pumpUntilReplyOrTurnDone helper and ' +
      'its 4 call sites (3.1/3.2/3.3/3.4) implement the design D1 contract EXACTLY: ' +
      '(a) sawStreaming guard: it must only accept turn done after observing ChatArea.isStreaming==true ' +
      'at least once, so a pre-stream DB-preamble window (isStreaming false, no bubble) is NOT misread ' +
      'as silent completion; ' +
      '(b) after streaming stops, a 500ms grace pump re-checks the bubble before concluding silent completion ' +
      '(Error-path race where _endStreaming runs before _storeError); ' +
      '(c) 150s still-streaming throws TimeoutException; ' +
      '(d) call sites classify: bubble present goes to normal path reading latestAssistantText, ' +
      'silent completion fails with a message naming model empty reply or internal exception plus an [OBS] dump ' +
      'call BEFORE the fail, TimeoutException fails. ' +
      '(e) existing Error: reply skip logic (text startsWith Error: leads to markTestSkipped) is still present. ' +
      'Also verify 3.3 cleanup: BOTH the silent-completion branch AND the hang branch delete _aliasagent_live_test.txt ' +
      'BEFORE fail. Report any deviation with file:line. If exact, verdict CLEAN.',
    phase: 'Verify',
  },
  {
    key: 'd3-restore',
    prompt:
      'You are an adversarial reviewer. Working dir ' + CWD + '. ' +
      'Read integration_test/live_observability.dart. Verify the _scanToolCards restore mechanism: ' +
      'after the collection loop it restores the viewport to the bottom using ScrollController.jumpTo(maxScrollExtent) ' +
      'obtained via tester.widget<ListView>(chatList).controller - NOT reverse drags (the first drag-based restore ' +
      'broke the whole suite, task 3.4). Verify the restore is defensive: it checks chatList.evaluate().isEmpty ' +
      'before restoring, checks controller null and hasClients, and wraps in try/catch so it cannot throw and fail ' +
      'the test it observes. Verify the collection loop still uses drags (unchanged). Then read ' +
      'openspec/changes/handle-empty-assistant-reply/tasks.md and confirm the honest 3-round record is present ' +
      '(first drag restore failed Test 2/3/4, baseline pre-D3 passed 4/4, jumpTo fix passed 4/4) and consistent ' +
      'with design.md D3. Report any issue with file:line. If all correct, verdict CLEAN.',
    phase: 'Verify',
  },
  {
    key: 'spec-consistency',
    prompt:
      'You are an adversarial spec reviewer. Working dir ' + CWD + '. ' +
      'Read openspec/changes/handle-empty-assistant-reply/specs/live-ui-tests/spec.md, proposal.md, and design.md. ' +
      'Verify: (1) the delta spec format is compliant (## MODIFIED Requirements, ' +
      '### Requirement: Error classification and resilience, #### Scenario headings). ' +
      '(2) The Test timeout scenario requires isStreaming==true to fail with TimeoutException. ' +
      '(3) The Silent completion scenario (streaming stopped without a completed assistant bubble) SHALL fail ' +
      'with an attributable message and SHALL NOT be skipped - and this does NOT contradict the base requirement ' +
      'that Internal bugs SHALL fail. ' +
      '(4) The spec text is consistent with proposal.md What Changes and design.md D1/D4, no contradiction, ' +
      'no weakened acceptance criteria. ' +
      '(5) All pre-apply review findings A-G are reflected in the artifacts. ' +
      'Report any inconsistency with file:line. If consistent, verdict CLEAN.',
    phase: 'Verify',
  },
  {
    key: 'regression-findings-ag',
    prompt:
      'You are an adversarial regression reviewer. Working dir ' + CWD + '. ' +
      'The pre-apply review found 7 confirmed design defects labeled A-G that were to be implemented: ' +
      'A streaming-start guard (sawStreaming) in the polling helper; ' +
      'B silent completion goes to FAIL not skip; ' +
      'C 500ms error-path grace re-check; ' +
      'D 3.3 test-file cleanup in silent and hang branches; ' +
      'E defensive D3 restore (try/catch plus empty-finder guard); ' +
      'F spec self-consistency (Test timeout plus Silent completion not contradicting Internal-bugs-SHALL-fail, assertions not weakened); ' +
      'G cross-suite side-effect (live_file_tools Error: skip branch revival) documented in design. ' +
      'Read integration_test/real_api_test.dart, integration_test/live_observability.dart, and ' +
      'openspec/changes/handle-empty-assistant-reply/design.md. For EACH of A-G verify it is actually implemented ' +
      'in the CURRENT code (not just claimed) and that the apply-round-1 change (D3 restore switched from ' +
      'reverse-drags to jumpTo, task 3.4) did NOT break or regress any of them. ' +
      'Also read tasks.md and verify the validation records are HONEST: 5.1 three-run comparison and ' +
      '5.2 real result +3 -1 with 3.3 silent-completion fail - no fabricated passing, no hidden failures, ' +
      'no acceptance-criteria weakening. Report any finding with file:line. ' +
      'If all A-G intact and records honest, verdict CLEAN.',
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
log('Verified ' + results.filter(Boolean).length + '/5 dimensions; ' + confirmed.length + ' findings')
return {
  confirmed,
  perDimension: results.map((r) => r ? { verdict: r.verdict, count: r.findings.length } : { verdict: 'SKIPPED', count: 0 }),
}
