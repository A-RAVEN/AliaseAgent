export const meta = {
  name: 'critical-review-add-live-test-visual-acceptance',
  description: 'Adversarial critical review of change + execution (design flaws, factual accuracy, scope, blind spots)',
  phases: [
    { title: 'Critique', detail: '5 adversarial agents attack independent dimensions' },
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

phase('Critique')

const dims = [
  {
    key: 'design-correctness',
    prompt:
      'You are a CRITICAL design reviewer. Be genuinely skeptical; find real flaws, do not rubber-stamp. Working dir ' + CWD + '. ' +
      'The change ' + CHANGE + ' adds end-of-case screenshots to live tests via RepaintBoundary.toImage(), then a main-loop human reads them for visual acceptance (NOT automated). ' +
      'Read ' + CHANGE + '/proposal.md, design.md, specs/live-test-visual-acceptance/spec.md. Attack these design claims and find weaknesses: ' +
      '(1) FAIL-PATH GAP: the screenshot capture (captureLiveShot) is placed AFTER assertions / at the END of each test body. On any fail() path (silent completion, timeout, Error reply), fail() throws BEFORE reaching captureLiveShot — so failure/error visual states are NEVER captured. But the spec says "每个用例结尾" capture. Is this an over-promise? Should the design capture failure states too (they are often the most diagnostic)? ' +
      '(2) SUBJECTIVE NON-AUTOMATED acceptance: the acceptance is main-loop judgment reading PNGs, not a CI-enforceable gate. Is the proposal/design honest that this is NOT an automated pass/fail — and does it define concrete pass vs anomaly thresholds? ' +
      '(3) CAPABILITY BOUNDARY: there are already openspec/specs/visual-assertions (CopyFromScreen+MCP) and visual-regression (RepaintBoundary+FakeSidecar+hash). A THIRD visual spec live-test-visual-acceptance. Is this justified or spec sprawl / overlapping concerns? ' +
      '(4) RepaintBoundary.toImage() captures the FLUTTER SCENE, not the OS window pixels (no title bar/chrome) — different from CopyFromScreen "what the user sees". Is the semantics misdescribed anywhere? ' +
      'For each weakness you find, state it concretely with file:line. This is a critique — you are expected to find ISSUES if they exist.',
    phase: 'Critique',
  },
  {
    key: 'artifact-consistency',
    prompt:
      'You are an adversarial consistency reviewer. Working dir ' + CWD + '. ' +
      'Verify proposal.md / design.md / specs/live-test-visual-acceptance/spec.md / tasks.md of ' + CHANGE + ' are internally CONSISTENT with each other AND with the ACTUAL implemented code in integration_test/real_api_test.dart, integration_test/live_file_tools_test.dart, integration_test/live_observability.dart. ' +
      'Check: (a) does the spec "每个用例结尾/除用例都截图" match the implementation (captureLiveShot only at pass-path end, so failing tests produce no image — does the spec acknowledge this exception like it does the "screenshot failure non-fatal" exception)? (b) does design.md spike-gate (task 1.5 says spike pass then 2.x) match tasks.md structure? (c) any contradiction between proposal capabilitry name, spec file name (specs/live-test-visual-acceptance/spec.md), and the ADDED Requirement headers? (d) does any artifact claim "no production code" while the implementation is test-only (verify no lib/ file changed via git diff)? ' +
      'Report each inconsistency with file:line. If consistent, verdict CLEAN.',
    phase: 'Critique',
  },
  {
    key: 'execution-factual-accuracy',
    prompt:
      'You are an adversarial FACT-CHECK reviewer. Working dir ' + CWD + '. ' +
      'The main-loop claims in ' + CHANGE + '/tasks.md 3.1 and 3.2 that (a) "3.3 无截图：因模型连续 3 次空回复(静默完成→诚实 fail)" and "同套件 3 例同包装全通过". Verify this against ACTUAL run logs and files. ' +
      'Evidence you can read (Bash): the suite output logs /tmp/spike_run.txt (the spike run, 16:37), /tmp/run_realapi_scale.txt (scale run, 16:43), /tmp/run_33.txt (3.3-only retry). Grep each for "All tests passed" vs "Some tests failed" and the "write_file + edit_file" line. ' +
      'CRITICAL: establish exactly how many times 3.3 failed and whether it EVER passed. Check: spike_run.txt ends with "+4: All tests passed!" (does that mean 3.3 passed in the spike run?); run_realapi_scale.txt shows 3.3 as [E] failed; run_33.txt shows 3.3 failed. ' +
      'Also verify: (b) all 7 screenshots the claim lists actually exist as non-zero PNGs (Bash: ls -la test/live_visual/ and file on each); (c) there is NO test/live_visual/3.3_edit_file.png. ' +
      'The claim "连续 3 次空回复" is suspected INACCURATE (3.3 likely passed once in the spike run). If you find the count is wrong, report it as a MEDIUM/HIGH factual-accuracy finding with the actual pass/fail pattern (pass-then-fail-fail vs 3-fails) and cite the log lines.',
    phase: 'Critique',
  },
  {
    key: 'scope-and-process',
    prompt:
      'You are an adversarial process reviewer. Working dir ' + CWD + '. ' +
      'The user asked only to "do the spike" of ' + CHANGE + ' (single-case validation of RepaintBoundary.toImage on 3.1). The main-loop instead executed the ENTIRE apply (scaled to all 8 cases via tasks 2.x, ran both suites via 3.x, read 7 images, ran honesty review via 4.x). ' +
      'Read ' + CHANGE + '/tasks.md and design.md. ' +
      'Assess: (a) is the overstep partially INCENTIVIZED by the change design itself — i.e. does design D2 / task 1.5 say "spike PASS -> 铺满其余 7 例" in a way that reads as auto-proceed-without-a-checkpoint? Does tasks.md have any natural gate between the spike (1.x) and scaling (2.x) that would require user confirmation, or does the structure flow straight through? ' +
      '(b) Is there tension between CLAUDE.md "apply during no pause / no STOP-HERE gates" and "spike is a gating decision that should be confirmed"? ' +
      '(c) Given the scope overstep, is the change currently in ANY state that the user did not authorize (e.g. modified test files, generated images, task checkboxes all checked)? List what is now "done" that the user only asked to spike. ' +
      'Report findings with file:line. Be honest — this dimension is about whether the design/process has a structural gap that enabled the overstep.',
    phase: 'Critique',
  },
  {
    key: 'blind-spots-and-limits',
    prompt:
      'You are an adversarial reviewer probing BLIND SPOTS. Working dir ' + CWD + '. ' +
      'Read integration_test/live_observability.dart (captureLiveShot, _scanToolCards) and integration_test/live_file_tools_test.dart + real_api_test.dart (captureLiveShot call sites). Find hidden limitations: ' +
      '(1) NON-FATAL SWALLOW: captureLiveShot wraps in try/catch and just logs. So if RepaintBoundary.toImage() silently starts producing BLACK/blank frames (not throwing), the test will NOT catch it — only "[SHOT] screenshot failed" or a bad frame silently appearing. The acceptance relies entirely on the human reading each image. Is this acceptable, and is it documented? ' +
      '(2) SCROLL + CAPTURE TIMING: in live_file_tools_test, dumpToolCards/_scanToolCards scroll the chat ListView up (drags) then restore via jumpTo(maxScrollExtent). The captureLiveShot runs AFTER the last dump. Could the captured image show a mid-scroll viewport or the WRONG region (i.e. not reliably showing the FINAL assistant reply / latest content)? Check the capture moment vs scroll state. Does captureWidgetAsPng capture the whole RepaintBoundary including ListView at its current scroll offset? ' +
      '(3) RepaintBoundary(key:).toImage() on a REAL window at real size — is there any risk of capturing a blank frame because the frame pipeline differs from the headless screenshot_test (which sets tester.view.physicalSize=1280x720)? The live tests run in a real window; does the RepaintBoundary toImage reliably reflect painted content? ' +
      '(4) The 3.3 "model empty reply" attribution — is it robustly proven, or circumstantial? The capture only underlines it; it does not PROVE the model returned empty (no screenshot of the empty-turn state). ' +
      'Report each blind spot with file:line. This is critique — expect to find issues.',
    phase: 'Critique',
  },
]

const results = await parallel(dims.map((d) => () =>
  agent(d.prompt, { label: 'critique:' + d.key, phase: 'Critique', schema: FINDINGS_SCHEMA })
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
log('Critiqued ' + results.filter(Boolean).length + '/5 dimensions; ' + all.length + ' findings (H:' + bySeverity.HIGH.length + ' M:' + bySeverity.MEDIUM.length + ' L:' + bySeverity.LOW.length + ')')
return {
  findings: all,
  perDimension: results.map((r) => r ? { verdict: r.verdict, count: r.findings.length } : { verdict: 'SKIPPED', count: 0 }),
}
