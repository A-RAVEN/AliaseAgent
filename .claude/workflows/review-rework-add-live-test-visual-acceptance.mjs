export const meta = {
  name: 'review-rework-add-live-test-visual-acceptance',
  description: 'Adversarial review of the rework tasks + artifact records added to add-live-test-visual-acceptance',
  phases: [
    { title: 'Review', detail: '5 adversarial agents verify findings-mapping, consistency, rework quality, facts, gaps' },
    { title: 'Synthesize', detail: 'Rank confirmed findings' },
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
const CHANGE = 'openspec/changes/add-live-test-visual-acceptance'

phase('Review')

const dims = [
  {
    key: 'findings-mapping-completeness',
    prompt:
      'You are an adversarial completeness reviewer. Working dir ' + CWD + '. ' +
      'The main-loop ran a 5-dim critical review that found 19 findings (6 HIGH / 10 MEDIUM / 3 LOW) on change ' + CHANGE + ', then recorded them and added rework tasks. ' +
      'Read ' + CHANGE + '/design.md (the "批判性自审发现与返工要求" section), design D2/D3/D4, proposal.md, specs/live-test-visual-acceptance/spec.md, and tasks.md section 5. ' +
      'Verify: (a) EACH critically-documented finding #1-#15 has a corresponding artifact note AND a rework task in 5.x; (b) the severity assignments are sane (H/M/L matches the described impact); (c) the tally "19 findings 6H/10M/3L" matches what the design review section and tasks.md claim; (d) findings #11/12/13 (spike gate + CLAUDE.md no-pause rule tension) are correctly flagged as needing USER/RULE-layer decision (Open Questions #4) rather than silently solvable by a task. ' +
      'Report any finding that is missing a task, mis-severitied, inconsistently tallied, or mis-framed. ',
    phase: 'Review',
  },
  {
    key: 'artifact-consistency-after-edits',
    prompt:
      'You are an adversarial consistency reviewer. Working dir ' + CWD + '. ' +
      'The artifacts of ' + CHANGE + ' were heavily edited after the critical review. Verify they are now INTERNALLY CONSISTENT and do not contradict each other or the implementation. ' +
      'Read design.md (D1-D5, the review section, Open Questions), proposal.md, specs/live-test-visual-acceptance/spec.md, and tasks.md. Then read the ACTUAL implemented test code: integration_test/real_api_test.dart, integration_test/live_file_tools_test.dart, integration_test/live_observability.dart. ' +
      'Check specifically: (1) Does design D2 now say the spike is a USER-CONFIRMATION gate, while spec.md "Spike produces a valid image" and tasks.md section 1 unchanged (1.5 still says "成功 → 继续 2.x" auto-continue)? Is there a CONTRADICTION between the corrected D2 and the still-[x] task 1.5 / spec line 50? (2) Does design D3 say capture should be in try/finally (fail-path) while the IMPLEMENTED code still calls captureLiveShot as the LAST statement after asserts (not fail-path) — i.e. does design now describe a state the code does NOT yet implement (planned rework)? (3) Any other contradiction between proposal/design/spec/tasks after the edits. ' +
      'Report each inconsistency with file:line. Be precise — this dimension is about whether the edits introduced contradictions.',
    phase: 'Review',
  },
  {
    key: 'rework-task-quality',
    prompt:
      'You are an adversarial reviewer of rework-task quality. Working dir ' + CWD + '. ' +
      'Read ' + CHANGE + '/tasks.md section 5 (5.1-5.13) and the corresponding parts of design.md (D3 robustness, D4 correction). ' +
      'Assess whether each rework task: (a) addresses the ROOT CAUSE, not a symptom (e.g. is 5.2 the real fix for stale-image risk, or does it need a "verify the boundary was painted before toImage" precondition too?); (b) is implementable/verifiable in one pass; (c) maps to a specific finding; (d) is honest (does 5.9 correctly defer the CLAUDE.md rule tension to a user/rule decision rather than pretending it is a simple fix?). ' +
      'Flag any rework task that is vague, symptom-treating, unmappable, or that would reintroduce the very problem it claims to fix. ',
    phase: 'Review',
  },
  {
    key: 'factual-accuracy-3-3-and-talley',
    prompt:
      'You are an adversarial fact-checker. Working dir ' + CWD + '. ' +
      'Verify two claims in ' + CHANGE + '/tasks.md and design.md. ' +
      '(1) The correction in task 3.1: "3.3 was spike run(16:37) pass once (+4 All tests passed) -> scale(16:43) fail -> 3.3-only rerun(16:47) fail, i.e. pass-1 fail-2, NOT 连续 3 次空回复". Cross-check against actual logs: Bash grep /tmp/spike_run.txt for "All tests passed" and "+4"; grep /tmp/run_realapi_scale.txt and /tmp/run_33.txt for the 3.3 failure. Confirm the pass-1-fail-2 pattern is CORRECT (not pass-2 or fail-3). ' +
      '(2) The tally "19 findings 6 HIGH / 10 MEDIUM / 3 LOW" in tasks.md 4.1 note and design.md review section. Check the design review section and tasks.md section 5 header agree on this tally. ' +
      'Report any factual error with the correct evidence. ',
    phase: 'Review',
  },
  {
    key: 'new-gaps-previous-reviews-missed',
    prompt:
      'You are a CRITICAL reviewer hunting GAPS the earlier reviews missed. Working dir ' + CWD + '. ' +
      'The critical review (this change) found 19 issues including fail-path no-capture, stale-image risk, silent jumpTo restore, subjective ill-defined acceptance, capability overlap, and the spike-gate/CLAUDE.md tension. ' +
      'Now attack the UPDATED artifacts for NEW or UNRESOLVED problems: ' +
      '(1) Did the edits resolve the issues, or merely document them? E.g., design D3 says capture should move to fail-path and add a stale guard — but is there still a design ambiguity about HOW (finally vs pre-fail) and whether a pre-fail capture could itself fail for the SAME reason the test failed (e.g. toImage throws on a broken pipeline)? ' +
      '(2) Is the "PASS must have valid screenshot" coupling (5.2/5.10) actually enforceable, or does it conflict with "screenshot failure must not fail the test" (a real tension)? How would both hold simultaneously? ' +
      '(3) Is there any remaining blind spot: e.g. does capture after _scanToolCards reliably show the FINAL reply, or could the acceptance still be fooled by a stale/mid-scroll image even after the guard? ' +
      'Report genuine NEW gaps or unresolved contradictions with file:line, not hypotheticals you cannot ground.',
    phase: 'Review',
  },
]

const results = await parallel(dims.map((d) => () =>
  agent(d.prompt, { label: 'review:' + d.key, phase: 'Review', schema: FINDINGS_SCHEMA })
))

phase('Synthesize')
const bySeverity = { HIGH: [], MEDIUM: [], LOW: [] }
for (const r of results) {
  if (!r || r.verdict !== 'ISSUES_FOUND') continue
  for (const f of r.findings) {
    if (bySeverity[f.severity]) bySeverity[f.severity].push(f)
  }
}
const all = [...bySeverity.HIGH, ...bySeverity.MEDIUM, ...bySeverity.LOW]
log('Reviewed ' + results.filter(Boolean).length + '/5 dimensions; ' + all.length + ' findings (H:' + bySeverity.HIGH.length + ' M:' + bySeverity.MEDIUM.length + ' L:' + bySeverity.LOW.length + ')')
return {
  findings: all,
  perDimension: results.map((r) => r ? { verdict: r.verdict, count: r.findings.length } : { verdict: 'SKIPPED', count: 0 }),
}
