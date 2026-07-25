## 1. Core fix

- [x] 1.1 Replace `for (int turn = 0; turn < 5; turn++)` with `while (true)` + counter, exit loop only via `turnToolCalls.isEmpty` branch (model's own decision)
- [x] 1.2 Add 50-round safety net: `if (turn >= 50)` → `debugPrint` warning + `_endStreaming()` + `return`

## 2. Verify

- [x] 2.1 Build: `flutter build windows --debug` succeeds
- [x] 2.2 Test: `flutter test` all pass (no test relies on 5-turn limit behavior)
- [x] 2.3 Manual: send a query that triggers multiple rounds of web_search, verify model responds after >5 tool calls
