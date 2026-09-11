export const meta = {
  name: 'verify-restored-bugfix-tasks-add-live-test-visual-acceptance',
  description: 'Verify the restored genuine bug-fix rework tasks are correct, complete, and consistent',
  phases: [
    { title: 'Verify', detail: '2 adversarial agents check task correctness and consistency/completeness' },
    { title: 'Synthesize', detail: 'Rank confirmed gaps' },
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

phase('Verify')

const dims = [
  {
    key: 'task-correctness-scope',
    prompt:
      'You are an adversarial reviewer of rework-task correctness. Working dir ' + CWD + '. ' +
      'Read ' + CHANGE + '/tasks.md section 5 (the restored genuine bug-fix tasks 5.1-5.7) and compare against the ACTUAL implementation in integration_test/live_observability.dart, integration_test/real_api_test.dart, integration_test/live_file_tools_test.dart. ' +
      'Verify each task is a REAL, correctly-described bug: ' +
      '(a) 5.1 fail-path no-capture: is captureLiveShot really the LAST statement after all fail()/expect/markTestSkipped paths, so fail states never shot? (check real_api_test.dart capture lines vs preceding fail/expect lines) ' +
      '(b) 5.2 stale/blank: does captureLiveShot really only try/catch-log with no stale-delete or non-blank check (live_observability.dart)? ' +
      '(c) 5.3 jumpTo restore silent: is the restore in live_observability.dart _scanToolCards inside an empty catch with no offset==maxScrollExtent verification, and does _scanErrorCardsWithScroll not restore? ' +
      '(d) 5.4 painted precondition: is there really NO pump/needsPaint check before toImage in captureWidgetAsPng (screenshot_utils.dart)? ' +
      '(e) 5.5 semantic overclaim: does the spec/design/proposal still call it "acceptance/验收" while the image cannot verify file-content assertions? ' +
      'Also check: are these tasks correctly SCOPED as real fixes and NOT re-introducing rejected over-engineering (e.g. no "manifest/verdict channel", no "PASS must have screenshot" coupling that contradicts the non-fatal rule)? ' +
      'Report any task that is wrong, mis-scoped, or that contradicts the implementation/spec. ',
    phase: 'Verify',
  },
  {
    key: 'consistency-completeness',
    prompt:
      'You are an adversarial consistency/completeness reviewer. Working dir ' + CWD + '. ' +
      'Read ' + CHANGE + '/tasks.md in full, + design.md (the "批判性自审发现与返工要求" section, D1-D5, Open Questions) + specs/live-test-visual-acceptance/spec.md. ' +
      'After I deleted the 30-task churn and restored a lean real set (5.1-5.7): ' +
      '(1) Do the restored tasks contradict design.md or spec.md? (e.g. does design D3 still say "try/finally fail-path" consistent with 5.1? does D3 say helper in screenshot_utils vs implementation in live_observability — is 5.x contradictory or is that a documented open item?) ' +
      '(2) COMPLETENESS: the critical review found 19 findings (6H/10M/3L); round-2 found 25 (7H/8M/10L). From those, the GENUINE bug-fix findings were: fail-path no-capture, stale/blank guard, jumpTo silent restore, painted precondition, semantic overclaim (+ DPR/physical-pixel, thresholds). Are ALL of these genuine-fix findings now represented in the restored 5.1-5.5, or is any genuine fix still missing (under-restored)? ' +
      '(3) Any dangling reference in tasks.md to now-deleted sections (5.9, 6.x, 7.x)? ' +
      'Report each inconsistency or missing genuine fix with file:line.',
    phase: 'Verify',
  },
]

const results = await parallel(dims.map((d) => () =>
  agent(d.prompt, { label: 'verify:' + d.key, phase: 'Verify', schema: FINDINGS_SCHEMA })
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
log('Verified ' + results.filter(Boolean).length + '/2 dimensions; ' + all.length + ' findings (H:' + bySeverity.HIGH.length + ' M:' + bySeverity.MEDIUM.length + ' L:' + bySeverity.LOW.length + ')')
return { findings: all, perDimension: results.map((r) => r ? { verdict: r.verdict, count: r.findings.length } : { verdict: 'SKIPPED', count: 0 }) }
