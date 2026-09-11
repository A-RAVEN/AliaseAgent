export const meta = {
  name: 'map-test-infrastructure',
  description: 'Map the full test infrastructure + standards of this project (Dart unit/widget/integration, smoke, window live suites, C++ sidecar Catch2, debug/dmp reading, authoritative rules) so the main loop can write an accurate TESTING GUIDE. Read-only, LOCAL-source-only, structured output.',
  phases: [
    { title: 'Map', detail: '6 readers each map one subsystem and return structured facts' },
  ],
}

const CWD = 'E:/Projects/AliasAgent'

const MAP_SCHEMA = {
  type: 'object',
  required: ['area', 'files', 'conventions', 'runCommands', 'standards', 'debugReading'],
  properties: {
    area: { type: 'string' },
    files: { type: 'array', items: { type: 'string' }, description: 'relevant file paths (repo-relative)' },
    conventions: { type: 'array', items: { type: 'string' }, description: 'how tests are structured/named/grouped/anotated in this area' },
    runCommands: { type: 'array', items: { type: 'string' }, description: 'exact shell commands to run these tests' },
    standards: { type: 'array', items: { type: 'string' }, description: 'implementation standards specific to this area (error handling, log output, assertion style)' },
    debugReading: { type: 'array', items: { type: 'string' }, description: 'how a developer/agent reads debug/observability output from this area' },
    notes: { type: 'array', items: { type: 'string' }, description: 'gotchas, caveats, ordering, timeouts, environment requirements' },
  },
}

const READERS = [
  {
    key: 'dart-unit-widget',
    prompt: 'Map the DART UNIT + WIDGET test area of this project. Read the directories test/, test/unit/, test/widget/ (and test/widget/helpers/), plus pubspec.yaml test/dev deps. Report: which files exist and what they test; the conventions (testWidgets vs test() group style, mocking of sidecar/DB, how the widget tree is pumped — e.g. pump MyApp vs ChatScreen, injected fakes); the exact run command(s); typical assertion/error-handling conventions; and any known gotchas (pumpAndSettle vs manual pump, SharedPreferences/db openAt temp, sidecar fakes). Return STRICTLY facts found in local source only.',
  },
  {
    key: 'dart-integration-smoke',
    prompt: 'Map the DART INTEGRATION + SMOKE test area. Read test/integration/ (and test/integration/helpers/), test/smoke/ (and test/smoke/references/, test/smoke/output/). Report: files and what each tests; how they are structured (gates, temp DB, config); the exact run command(s); any reference-file/snapshot conventions; error-handling and output; gotchas. Return STRICTLY facts from local source only.',
  },
  {
    key: 'live-suite',
    prompt: 'Map the WINDOW LIVE test suite at integration_test/. Read integration_test/real_api_test.dart, integration_test/live_file_tools_test.dart, integration_test/live_observability.dart, integration_test/screenshot_test.dart, and dart_test.yaml. Report: the `live` tag + how to run (flutter test --tags live --run-skipped ... -d windows); the [OBS] observability pattern (dumpToolCards/dumpNoTool/dumpFile/readFinalAssistantReply/captureLiveShot/clearLiveVisualDir/byte-floor-threshold); how each live suite pumps the app (RepaintBoundary+MyApp) and uses try/finally for screenshots; the 150s timeouts; the error-reporting conventions (dump before fail/skip, markTestSkipped for external errors vs fail for internal). Return STRICTLY facts from local source.',
  },
  {
    key: 'sidecar-cpp',
    prompt: 'Map the C++ SIDE CAR test area at sidecar/test/. Read sidecar/test/*.cpp (ffi_tracing_test, http_client_test, search_provider_test, search_tools_test, sse_parser_test, subprocess_test, tool_execution_test, test_main.cpp), sidecar/test/mock_server.h, sidecar/test/README.md, and sidecar/CMakeLists.txt (the test target). Report: the Catch2 harness + how the test executable is built and run (cmake/ctest target, the exact build+run command); what each test file covers; mock_server.h usage; fixtures; any ASan notes; gotchas (DLL deploy, subprocess, working dir). Return STRICTLY facts from local source.',
  },
  {
    key: 'debug-reading',
    prompt: 'Map the DEBUG / DIAGNOSTIC facilities so a dev or agent can READ the data. Read DEBUGGING.md, sidecar/src/crash_handler.cpp, sidecar/src/logger.h, and any sidecar log-level docs. Report: the sidecar.log location + log levels (trace/info/warn/error) + how to enable trace (ALIASAGENT_LOG_LEVEL); the crash artifacts in ~/.aliasagent/crashes/ (sidecar_crash_*.dmp, crash.log, crash_backtrace_*.log, the FFI ring buffer of last 256 C->Dart callbacks) and how to read each; the note that MiniDumpNormal has no heap (no API key) and that PDB is needed for symbols; any scripts/tools to inspect dmp; how to attach to the sidecar debug log path from the app. Return STRICTLY facts from local source.',
  },
  {
    key: 'authoritative-rules',
    prompt: 'Extract the AUTHORITATIVE TEST RULES of this project. Read CLAUDE.md (the rules about 测试输出可观测性 / 禁止修改验收标准 / tasks 诚实性审查 / no-user-in-the-loop tasks / three-tier test strategy / read logs proactively), and any memory or docs about testing standards. Report the definitive rules governing how tests are writable/verifiable: the observability requirement (tests must show ACTUAL tool calls + file state before assertions; output must be attributable) and the implementation standards; the test tier strategy; that manual/user-run verification tasks are prohibited (must be automatable by the agent); and how tests are wired into OpenSpec changes. Return STRICTLY the rules as written.',
  },
]

phase('Map')

const results = await parallel(
  READERS.map((r) => () =>
    agent(
      'You are a documentation mapper in working dir ' + CWD + '. Read ONLY local files (no network, no MCP/WebSearch/WebFetch). ' + r.prompt + ' Be precise and concrete — cite file paths and exact text/commands. Do NOT invent anything not present in the source. If a behavior is absent, state it is absent; never assume.',
      { label: 'map:' + r.key, phase: 'Map', schema: MAP_SCHEMA }
    ).then((m) => ({ key: r.key, map: m }))
  )
)

const maps = {}
for (const r of results) {
  if (r && r.map) maps[r.key] = r.map
}

log('Mapped ' + Object.keys(maps).length + '/6 subsystems')
return { maps }
