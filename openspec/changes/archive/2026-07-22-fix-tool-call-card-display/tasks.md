## 1. Setup — dependencies

- [x] 1.1 Add `url_launcher` to `pubspec.yaml` dependencies: `flutter pub add url_launcher`

## 2. Data model — ResultSection / ResultItem

- [x] 2.1 Add `ResultSection` class to `lib/models/tool_call_activity.dart`: label (String), error (String?), items (List<ResultItem>); include `toJson()` and `fromJson()` factory
- [x] 2.2 Add `ResultItem` class to `lib/models/tool_call_activity.dart`: title, url, content (all String?); include `toJson()` and `fromJson()` factory
- [x] 2.3 Add `resultSections` (`List<ResultSection>?`) field to `ToolCallActivity`, update `copyWith`, `toJson`, `fromJson` — ensure null-safe backward compatibility (null when missing in JSON)
- [x] 2.4 `fromJson`: accept `name` as fallback for `toolName` — `json['toolName'] ?? json['name'] ?? 'unknown'` — for backward compat with old session data

## 3. Formatting layer — build result sections from raw JSON

- [x] 3.1 Add `_buildResultSections` in `lib/main.dart` that parses web_search result JSON into `List<ResultSection>`: one section per provider, iterate ALL items (not just first), capture per-provider `error` field into `ResultSection.error`
- [x] 3.2 Edge cases in `_buildResultSections`: missing `results` key → return `[]`; empty results map `{}` → return `[]`; `ok: false` → return `[]`; provider with error key → set `error`, leave `items` empty
- [x] 3.3 Add web_fetch branch: single `ResultSection` label "Fetched page", one `ResultItem` with title=URL, content=page content; `ok: false` → return `[]`
- [x] 3.4 Wire `_buildResultSections` into tool result processing block: call it alongside `_formatSearchResultForDisplay`, pass `resultSections` to `ToolCallActivity.copyWith`

## 4. Streaming bubble — lazy creation

- [x] 4.1 Remove the eager `ChatStreamingItem('')` creation at turn start (line 494-496 in `_sendMessage`)
- [x] 4.2 Update `onChunk` callback: create `ChatStreamingItem` on first text chunk if it doesn't exist yet, update existing one otherwise
- [x] 4.3 Verify `removeWhere` cleanup after `sendMessage` return is safe (no-op when no streaming item exists)
- [x] 4.4 Guard `ChatMessageItem(intermediateMsg)` at line 611 with `turnText.isNotEmpty` — skip adding empty intermediate message to `_chatItems` when model does tool_use-only response (same fix as D7 but for live path)

## 5. ToolCallCard UI — structured rendering

- [x] 5.1 Collapsed state: when `resultSections` is non-null and non-empty, show "N providers, M results" one-liner; when `[]` show "No results found"; when null, fall back to existing `resultPreview` 300-char truncation
- [x] 5.2 Expanded state with sections: render each `ResultSection` with a header (provider name + item count, or error indicator if `error` is non-null)
- [x] 5.3 Per-item card: title bold, URL as clickable link (accent color, `launchUrl` on tap), content snippet max 200 chars
- [x] 5.4 Error rendering: section with `error` shows error message instead of items; top-level `ToolCallStatus.error` already handled by existing header logic (unchanged)
- [x] 5.5 Overflow handling: if provider/item count is large, ensure scroll within expanded card (SingleChildScrollView or limited-height ListView)
- [x] 5.6 Executing state preserved: header spinner + "Executing..." + result area hidden (unchanged from current, just verify)

## 6. Persistence fix — store result data in toolCallsJson

- [x] 6.1 After tool execution, serialize `ToolCallActivity.toJson()` and update the corresponding entry in `turnToolCalls` so `result`/`status`/`resultSections` are persisted
- [x] 6.2 Update `_buildChatItems` to reconstruct `ToolCallActivity` with full result data from stored `toolCallsJson` on session reload
- [x] 6.3 In `_buildChatItems`, skip `ChatMessageItem` when `msg.content` is empty and `msg.toolCallsJson` is non-null — tool cards already represent the assistant's response, no empty bubble needed

## 7. Test coverage

- [x] 7.1 `ToolCallActivity.fromJson` unit test in `test/unit/tool_call_activity_test.dart`: JSON with `name` key (legacy format) → `toolName` equals the name value (D9 backward compat)
- [x] 7.2 `ToolCallActivity.fromJson` unit test in `test/unit/tool_call_activity_test.dart`: JSON with `toolName` key (new format) → `toolName` preserved, `resultSections` deserialized correctly
- [x] 7.3 Live tool_use-only test: FakeSidecar queues tool_use + done only (no text chunks). After flow completes, assert: ToolCallCard visible in done state, zero `MessageBubble` widgets with `role == 'assistant'` and empty content (D5 + D8 guards). Add to `tool_call_test.dart`.
- [x] 7.4 Reload tool_use-only test: pre-populate `FakeMessageRepository` with assistant message (`content: ''`, `toolCallsJson` with dummy tool call). Reload session, assert: ToolCallCard visible, zero assistant `MessageBubble` with empty content (D7 guard). Add to `tool_persistence_test.dart`.

## 8. Build & verify

- [x] 8.1 Build: `run.bat` compiles and launches successfully
- [ ] 8.2 Smoke test: send a query that triggers web_search, verify card shows structured results with expand/collapse working
- [ ] 8.3 URL click test: click a result URL in expanded card, verify browser opens
- [ ] 8.4 Non-search tool test: verify read_file / list_dir / get_current_time cards still work using the fallback path
- [ ] 8.5 Empty results test: query that returns no results → "No results found" display
- [ ] 8.6 Empty bubble test: send a query that triggers a direct tool call (no text), verify no empty streaming bubble appears
- [ ] 8.7 Session persistence test: close and reopen app, verify tool cards from previous session show correct status and result data (not "Executing..." with no result)
