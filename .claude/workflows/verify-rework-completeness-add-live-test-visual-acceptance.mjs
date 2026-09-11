export const meta = {
  name: 'verify-rework-completeness-add-live-test-visual-acceptance',
  description: 'Verify every cited finding has a distinct rework task; no orphans, no new contradictions',
  phases: [
    { title: 'Verify', detail: '2 adversarial agents check completeness and consistency' },
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

// Master finding list (round-1 critical review 19 + round-2 rework review 25)
const ROUND1 = [
  ['HIGH', 'fail-path gap: captureLiveShot last statement, fail states never shot'],
  ['HIGH', 'design D2 spike fork not user checkpoint'],
  ['HIGH', 'tasks.md no gate between spike and scaling'],
  ['HIGH', 'CLAUDE.md no-pause conflicts spike user-confirmation'],
  ['HIGH', 'non-fatal swallow validates nothing / stale PNG'],
  ['HIGH', 'capture after silent jumpTo restore → wrong region'],
  ['MEDIUM', 'no quantitative thresholds / content-match ill-defined'],
  ['MEDIUM', 'capability boundary overlaps visual-assertions/visual-regression'],
  ['MEDIUM', 'RepaintBoundary semantics misdescribed + HiDPI'],
  ['MEDIUM', 'spec over-states coverage (fail cases no image)'],
  ['MEDIUM', 'tasks 3.1 "连续 3 次空回复" wrong (pass-1 fail-2)'],
  ['MEDIUM', 'scaling applied without user confirmation'],
  ['MEDIUM', 'live_observability.dart out of scope / helper placement divergence'],
  ['MEDIUM', 'change fully checkmarked with unauthorized state'],
  ['MEDIUM', 'live toImage pixelRatio 1.0 no DPR/blank guard'],
  ['MEDIUM', '3.3 attribution circumstantial'],
  ['LOW', 'MCP-ban justification non-sequitur'],
  ['LOW', 'silent capture failure + PASS → green with missing evidence'],
  ['LOW', 'D3 wrapper-vs-call-site divergence'],
]
const ROUND2 = [
  ['HIGH', "tally '19 6H/10M/3L' ≠ documented 15"],
  ['HIGH', 'design D2 vs Migration Plan auto-continue contradiction'],
  ['HIGH', 'tasks 1.5 auto-continue gate'],
  ['HIGH', 'design D3 mandates try/finally; impl still last-statement'],
  ['HIGH', 'PASS-must-have-screenshot unenforceable + contradicts non-fatal'],
  ['HIGH', 'capture-placement finally vs pre-fail undecided + rethrow'],
  ['HIGH', 'acceptance fooled by stale/mid-scroll even after guards'],
  ['MEDIUM', '#9 attribution no dedicated task'],
  ['MEDIUM', 'D3 helper live_observability vs screenshot_utils unresolved'],
  ['MEDIUM', 'D4 base checklist still "内容与已知回复一致"'],
  ['MEDIUM', '5.2 stale guard symptom; missing painted-precondition'],
  ['MEDIUM', '5.3 restore risks drag-ballistic reintro'],
  ['MEDIUM', 'round-1 tally mismatch'],
  ['MEDIUM', 'fail-path finally loses pump; live_file_tools no pump'],
  ['MEDIUM', 'content-verification assertions invisible to acceptance'],
  ['LOW', '#6 spec over-promise no dedicated task'],
  ['LOW', '#14/#15 untagged severity'],
  ['LOW', '5.9 wraps undecided user decision in [ ] checklist'],
  ['LOW', 'proposal Impact "每用例结尾" contradicts fail-path'],
  ['LOW', '5.1 capture-in-finally can hang/mask failure'],
  ['LOW', '5.9 honest but not one-pass / retrospective'],
  ['LOW', '5.7 leaves "二选一" open'],
  ['LOW', '#9 attribution non-proof no dedicated task'],
  ['LOW', '5.12 fail-path verification nondeterministic'],
  ['LOW', 'thresholds still "如" placeholder'],
]

phase('Verify')

const dims = [
  {
    key: 'completeness',
    prompt:
      'You are an adversarial completeness reviewer. Working dir ' + CWD + '. ' +
      'Read ' + CHANGE + '/tasks.md sections 5, 6, 7 (all rework tasks 5.1-5.13, 6.1-6.8, 7.1-7.9). ' +
      'Below is the FULL master list of findings from two adversarial reviews. For EVERY finding, determine whether it has a DISTINCT rework task OR an explicit "记录/豁免/已修" note in tasks.md or design.md. ' +
      'Master findings (severity, title):\n' +
      ROUND1.concat(ROUND2).map((f) => '  [' + f[0] + '] ' + f[1]).join('\n') +
      '\nReport the UNION of: (a) findings with NO task and NO explicit-record note (true orphans), and (b) tasks that reference a finding but are mis-severitied or mis-scoped. If every finding is reflected (task or explicit record/豁免 note), verdict CLEAN.',
    phase: 'Verify',
  },
  {
    key: 'no-new-contradiction',
    prompt:
      'You are an adversarial consistency reviewer. Working dir ' + CWD + '. ' +
      'Read ' + CHANGE + '/tasks.md sections 5/6/7 and design.md (D1-D5, the "批判性自审发现与返工要求" section, Open Questions). ' +
      'The rework tasks were appended & edited multiple times. Verify no NEW contradiction was introduced: ' +
      '(1) 7.3 says tasks 1-4 all [x] plus 5.1-5.13/6.1-6.8/7.x unchecked — is the checkbox state self-consistent? ' +
      '(2) 7.5 says 5.9 must be gated (not self-completable), while 5.9 still reads as a plain [ ] task — is there a contradiction? ' +
      '(3) design D2 (user-confirmation gate) vs tasks 1.5 (which I edited to say "语义应理解为停下确认") vs the fact that the apply already compiled — does the record now honestly separate "what was done (spike→full apply, overstep, forgiven)" from "what the corrected gate SHOULD have been"? ' +
      '(4) Any task numbering/reference mismatch (e.g. 6.2 referenced but the finally-vs-pre-fail decision split across 6.2 and 7.4). ' +
      'Report each inconsistency with file:line. If consistent, verdict CLEAN.',
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
