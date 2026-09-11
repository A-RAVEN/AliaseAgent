export const meta = {
  name: 'review-testing-guide',
  description: 'Adversarial review of docs/TESTING.md — verify each section is ACCURATE (vs real source), COMPLETE (no omitted test area/command/rule), and CONSISTENT (no contradiction with CLAUDE.md/DEBUGGING.md/authoritative rules). REFUTING skeptics, majority-kill, LOCAL-source-only.',
  phases: [
    { title: 'Refute', detail: '3 skeptics refute each of 6 claims (default refuted=true)' },
    { title: 'Vote', detail: 'Majority-kill: survives if <majority refute' },
  ],
}

const CWD = 'E:/Projects/AliasAgent'
const DOC = 'E:/Projects/AliasAgent/docs/TESTING.md'

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
    id: 'LAYERS',
    task: 'Layer table + decision rule correctly place each test type and directory',
    claim: 'docs/TESTING.md section 1 correctly maps each test layer to its directory and purpose: test/unit (Dart unit), test/widget (+ helpers), test/integration (+ helpers, headless FakeSidecar + real-DLL bridge), integration_test (window live real-model @Tags live), sidecar/test (C++ Catch2), test/smoke (bash + screenshot_test.dart visual regression). The "what/where" assignments and the directory names are correct as shown, and no test type is assigned to the wrong directory.',
  },
  {
    id: 'WRITE',
    task: 'How-to-write conventions are accurate to the actual source',
    claim: 'docs/TESTING.md section 2 conventions match the real code: widget tests never pump MyApp and always use MaterialApp(home:Scaffold(body:...)); sidecar is mocked via FakeSidecar from test/integration/helpers/fake_sidecar.dart implementing ISidecar; no real DB/SharedPreferences in test/unit+test/widget (persistence faked by Fake*Repository, test data via test_utils factories); viewport override tester.view.physicalSize=Size(1280,720)+devicePixelRatio=1.0; teardown resets registry.clear()+resolver=null; pumpAndSettle is never used (manual pump durations); integration FakeSidecar uses queueChunk/queueToolCall/queueThinking/queueDone FIFO + gateNextSend/releaseGate; real-DLL bridge tests use a local SSE mock server (ServerSocket.bind loopbackIPv4) and must close both writer+client socket; live suites use @Tags([live]) + library, RepaintBoundary(captureKey, child: const MyApp()), try/finally for captureLiveShot (NOT addTearDown), 150s inner waits + 300s testWidgets timeout; sidecar tests are Catch2 v3 that link production sources (NOT sidecar.dll), use mock_server.h/temp_dir.h/fixtures, and self-skip (SUCCEED+WARN) when an env dependency (rg, API key, SearXNG) is absent.',
  },
  {
    id: 'STANDARDS',
    task: 'Implementation standards are accurate + complete vs CLAUDE.md/DEBUGGING.md/live_observability.dart',
    claim: 'docs/TESTING.md section 3 standards are accurate and complete: (a) observability — model-driven tests MUST print actual tool calls (name/input/status/result) + file state BEFORE assertions; failures must have attributable on-site evidence; [OBS] dumps are pure debugPrint that never assert/change behavior; dump before every fail/markTestSkipped; (b) error handling — markTestSkipped reserved for external/unavailability (config missing, !apiAvailable, no providers, "Error:"-prefix reply), fail reserved for internal bugs (ToolCallCard error status, silent-completion, 150s hang); (c) screenshot — captureLiveShot to test/live_visual with byte floor 2048, clearLiveVisualDir in setUpAll, delete-on-fail, try/finally not addTearDown; (d) no-acceptance-standard modification, no batch-checking, no hiding failures, honest reporting; (e) no manual/user-in-the-loop verification (convert to a self-test the loop runs).',
  },
  {
    id: 'DEBUG',
    task: 'Debug-reading section is accurate to DEBUGGING.md/crash_handler/logger',
    claim: 'docs/TESTING.md section 4 debug facts are accurate: sidecar.log path (Windows %USERPROFILE%\\.aliasagent\\logs\\sidecar.log, POSIX ~/.aliasagent/logs/sidecar.log); levels TRACE=0/INFO=1(default)/WARN=2/ERROR=3 with no DEBUG level and ERROR printed as the string "ERROR"; ALIASAGENT_LOG_LEVEL read once at init, unrecognized values fall back to INFO, auth headers never logged, HTTP>=400 logs status + first 2048 bytes; log rotation >10MB to .1.log/.2.log/.3.log (max 3 historical); crash artifacts under ~/.aliasagent/crashes/ (sidecar_crash_*.dmp MiniDumpNormal ~1-5MB no heap no api key, crash.log reentrant crash_log + FFI ring buffer dump of last 256 C->Dart callbacks metadata-only, crash_backtrace_*.log on Linux/macOS); ASan applies ONLY to sidecar_tests (vcpkg triplet x64-windows-asan-static, scripts\\rebuild_sidecar.bat Debug --asan).',
  },
  {
    id: 'COMMANDS',
    task: 'Every run command listed in the doc would work as written',
    claim: 'Each command in docs/TESTING.md is correct: `flutter test test/unit/`, `flutter test test/widget/` (and single-file), `flutter test test/integration/`; the live command `flutter test --tags live --run-skipped integration_test/live_file_tools_test.dart -d windows`; sidecar `cmake -B build/windows -S sidecar`, `cmake --build build/windows --target sidecar_tests`, `ctest --test-dir build/windows -C Debug` (multi-config requires -C Debug) and `-R sse_parser` filter, `./build/windows/Debug/sidecar_tests.exe --list-tests`; smoke `bash test/smoke/run_all.sh`; README table commands; flutter analyze.',
  },
  {
    id: 'COMPLETENESS',
    task: 'Doc omits no material test area / category / command / rule present in the repo',
    claim: 'docs/TESTING.md is sufficiently complete: it does not omit any material subsystem a maintainer would need — e.g. the checkpoint verify scripts (test/checkpoint_*_verify.dart run via `dart run`, smoke step 03), run.bat (the only unit smoke run.bat executes), the smoke visual-regression step (05 -> integration_test/screenshot_test.dart, baseline auto-created), the [live]/[rate-guard]/[searxng] C++ tags, the note that modern live tests are window-based (-d windows) not headless (early headless live was deleted), the repository fakes (FakeSessionRepository/FakeMessageRepository), and the sqfliteFfiInit requirement for thinking_integration_test. Any material test area, category, command, or authoritative rule present in the repo IS covered by the doc.',
  },
]

const LENSES = [
  {
    key: 'accuracy',
    instruction: 'REFUTE on ACCURACY: is any specific fact/statement in the relevant sections of docs/TESTING.md WRONG against the actual source? Read docs/TESTING.md and the relevant source (test/unit, test/widget, test/integration, integration_test, sidecar/test, test/smoke, dart_test.yaml, pubspec.yaml, DEBUGGING.md, CLAUDE.md, integration_test/live_observability.dart, sidecar/src/{crash_handler,logger,model_gateway}.cpp). Verify exact file paths, directory names, tag names, function names (FakeSidecar queue/stub/gate API, captureLiveShot, clearLiveVisualDir, pumpUntilReplyOrTurnDone), thresholds (2048, 256, 10MB, 150s, 300s), and level names. Default refuted=true if uncertain or if any stated fact is imprecise/wrong.',
  },
  {
    key: 'completeness',
    instruction: 'REFUTE on COMPLETENESS: does docs/TESTING.md OMIT any material test subsystem, directory, test file, run command, config/step, or authoritative rule that actually exists in this repo and that a maintainer would need? Independently scan test/, test/unit/, test/widget/, test/integration/, integration_test/, sidecar/test/, test/smoke/, dart_test.yaml, pubspec.yaml, and DEBUGGING.md, then check whether the doc covers each. Call out anything present-but-absent from the doc (e.g. a whole test file, a smoke step, a debug facility, a gate config, a caveat). Default refuted=true if uncertain.',
  },
  {
    key: 'consistency',
    instruction: 'REFUTE on CONSISTENCY: does docs/TESTING.md contradict CLAUDE.md, DEBUGGING.md, or the authoritative project rules, or is it internally inconsistent? Cross-check each section against CLAUDE.md (observability L21-24, no-acceptance-mod L20, tasks honesty loop, no-user-in-loop) and DEBUGGING.md (levels, crash, ASan, live-test command). Also check internal consistency (section 1 layers vs section 2 commands vs section 5 rules agree; no self-contradiction, e.g. one place says a test is skipped and another says it fails). Default refuted=true if uncertain.',
  },
]

function skepticPrompt(claim, lens) {
  return (
    'You are an adversarial reviewer in working dir ' + CWD + '. Your ONLY job is to REFUTE the following claim about the document ' + DOC + '. Default to refuted=true if uncertain. ' +
    lens.instruction + ' ' +
    'IMPORTANT CONSTRAINTS: You have NO network access and MUST NOT use MCP tools, WebSearch, WebFetch, or any HTTP fetch. Verify against LOCAL files only by reading the actual source. The document under review is ' + DOC + ' — read it fully. ' +
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
    verdict: survives ? 'SURVIVED (doc correct/complete/consistent)' : 'KILLED (refuted — doc has a real error/omission)',
    refuteCount: refutes.length,
    surviveCount: votes.length - refutes.length,
    skepticVotes: votes.map((v) => ({ lens: v.lens, refuted: v.refuted, reasoning: v.reasoning })),
  })
}

log('Final testing-guide review: ' + verdicts.length + ' skeptic-votes across ' + CLAIMS.length + ' claims; survivors: ' + results.filter((r) => r.verdict.startsWith('SURVIVED')).length)
return { perClaim: results }
