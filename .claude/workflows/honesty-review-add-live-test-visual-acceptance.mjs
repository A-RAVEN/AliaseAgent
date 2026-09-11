export const meta = {
  name: 'honesty-review-add-live-test-visual-acceptance',
  description: 'Adversarial honesty review of add-live-test-visual-acceptance apply',
  phases: [
    { title: 'Verify', detail: '4 adversarial agents verify independent dimensions' },
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
    key: 'no-prod-change',
    prompt:
      'You are an adversarial reviewer. Working dir ' + CWD + '. ' +
      'Verify the claim: change add-live-test-visual-acceptance made NO production code (lib/) and NO C++ sidecar (sidecar/) changes; it only edited test files (integration_test/real_api_test.dart, integration_test/live_file_tools_test.dart, integration_test/live_observability.dart), .gitignore, and openspec/changes/add-live-test-visual-acceptance/ artifacts. ' +
      'Use Bash git diff and git status to list changed files. Confirm: (a) no lib/ or sidecar/ file appears; (b) captureWidgetAsPng (from test/integration/helpers/screenshot_utils.dart) and the shared helper live_observability.dart are reused, and live_observability.dart imports from ../test/integration/helpers/screenshot_utils.dart; (c) each test wraps MyApp via RepaintBoundary(key: GlobalKey) at the CALL and only the call site. ' +
      'Report any HIGH/MEDIUM/LOW finding with file:line. If clean, verdict CLEAN.',
    phase: 'Verify',
  },
  {
    key: 'spike-first-and-gating',
    prompt:
      'You are an adversarial reviewer. Working dir ' + CWD + '. ' +
      'Verify the spike-first discipline was actually followed: (a) the spike was done on a SINGLE case first (3.1 in real_api_test) before scaling; (b) the output test/live_visual/3.1_basic.png is git-ignored via .gitignore (check .gitignore has "test/live_visual/"); (c) captureLiveShot (in live_observability.dart) is non-fatal — wraps in try/catch and logs, does NOT throw/fail the test; (d) the change did not touch lib/ or C++ (cross-check with first dimension). ' +
      'Read integration_test/live_observability.dart (captureLiveShot), integration_test/real_api_test.dart (3.1), and .gitignore. ' +
      'Also verify that the validation records in openspec/changes/add-live-test-visual-acceptance/tasks.md 3.1/3.2 are HONEST: they report 7/7 screenshots readable with 3.3 failing on the known model-empty-reply (silent completion), NOT a fabricated full pass. ' +
      'Report any finding with file:line. If clean, verdict CLEAN.',
    phase: 'Verify',
  },
  {
    key: 'capture-correctness',
    prompt:
      'You are an adversarial correctness reviewer. Working dir ' + CWD + '. ' +
      'Read integration_test/live_observability.dart and test/integration/helpers/screenshot_utils.dart. ' +
      'Verify captureLiveShot(GlobalKey key, String name) is correct: (a) it calls captureWidgetAsPng(key, "test/live_visual/<name>.png"); (b) it is non-fatal (try/catch, logs, returns without throwing); (c) captureWidgetAsPng requires the widget to be wrapped in RepaintBoundary(key: key) and does boundary.toImage(pixelRatio: 1.0) then writes PNG to disk, creating parent dirs. ' +
      'Read integration_test/real_api_test.dart (3.1/3.2/3.3/3.4) and integration_test/live_file_tools_test.dart (Test 1-4): verify EVERY test that declares `final captureKey = GlobalKey()` actually wraps MyApp in RepaintBoundary(key: captureKey, ...) AND calls captureLiveShot(captureKey, <name>) at its end. ' +
      'Report any inconsistency (a captureKey declared but not used, a RepaintBoundary mismatch, a missing captureLiveShot) with file:line. If all consistent, verdict CLEAN.',
    phase: 'Verify',
  },
  {
    key: 'vision-acceptance-authentic',
    prompt:
      'You are an adversarial honesty reviewer. Working dir ' + CWD + '. ' +
      'The main loop claims it READ 7 screenshots in test/live_visual/ (3.1_basic, 3.2_web_fetch, 3.4_thinking, livefile_t1, livefile_t2, livefile_t3, livefile_t4) with NATIVE vision and each PASSED the acceptance checklist (answer bubble / tool card done + result preview / thinking card / layout sanity). ' +
      'First verify the 7 files actually exist and are non-trivial PNGs (Bash: ls -la test/live_visual/ and file on each; check sizes are non-zero and reasonably large). Verify a file for 3.3_edit_file.png is ABSENT (3.3 failed, expected no shot). ' +
      'Then verify task 3.2 acceptance records in openspec/changes/add-live-test-visual-acceptance/tasks.md are authentic and not fabricated: the described contents (e.g. 3.2 the Example Domain title, livefile_t3 countA DONE / countB TODO, livefile_t4 glob_file src/a.dart) are plausible descriptions a real image would show. ' +
      'Report any dishonesty: fabricated acceptance, hidden failure, or claiming to read images that do not exist. If honest, verdict CLEAN.',
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
log('Verified ' + results.filter(Boolean).length + '/4 dimensions; ' + confirmed.length + ' findings')
return {
  confirmed,
  perDimension: results.map((r) => r ? { verdict: r.verdict, count: r.findings.length } : { verdict: 'SKIPPED', count: 0 }),
}
