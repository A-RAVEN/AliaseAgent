## Context

`chat-ui/spec.md` specifies Markdown rendering (code blocks, bold/italic/inline code), keyboard input behavior (Enter/Shift+Enter), and auto-scroll. Current widget tests verify message rendering at a high level but skip these UI details. The existing test infrastructure (widget test + Fake repos) can exercise these without code changes.

## Goals / Non-Goals

**Goals:**
- Add widget tests for Markdown content in `MessageBubble`: fenced code blocks, bold, italic, inline code, links, lists
- Add widget tests for keyboard shortcuts: Enter submits message, Shift+Enter inserts newline
- Add widget tests for auto-scroll: scroll position moves to bottom on new user message, assistant chunk, and streaming completion
- Zero production code changes — test-only addition

**Non-Goals:**
- Not testing every Markdown edge case (nested formatting, HTML passthrough)
- Not testing IME composition or non-US keyboard layouts
- Not testing scroll physics or animation timing (just final position)

## Decisions

### D1: Markdown tests via MessageBubble widget

Test `MessageBubble` directly (not via ChatArea), passing pre-formatted Markdown strings. This isolates rendering from the full app stack.

```dart
testWidgets('renders fenced code block', (tester) async {
  await tester.pumpWidget(MaterialApp(
    home: MessageBubble(role: 'assistant', content: '```dart\nprint("hi");\n```'),
  ));
  // Verify monospace rendering, code background
});
```

**选择**: Direct widget test. Each test pumps MessageBubble with a known Markdown string and verifies the Flutter `flutter_markdown` package's rendered output. No FakeSidecar or repos needed.

### D2: Keyboard tests via ChatArea widget

Pump ChatArea with Fake repos + FakeSidecar, simulate key events using `tester.sendKeyEvent()`.

```dart
await tester.sendKeyEvent(LogicalKeyboardKey.enter);
// Verify message was sent (input cleared, message in list)
```

**选择**: Widget-level keyboard simulation. Flutter test framework supports `sendKeyEvent` and `sendKeyDownEvent`/`sendKeyUpEvent` pairs. The Enter handler in `_InputBar._onKey` already uses `LogicalKeyboardKey.enter` + `HardwareKeyboard.instance.isShiftPressed`.

### D3: Auto-scroll tests via ChatArea + ScrollController

Pump ChatArea, add messages programmatically through the controller, check `ScrollController.offset` == `ScrollController.position.maxScrollExtent`.

**选择**: Direct scroll position assertions. Since ChatArea creates its own ScrollController internally, test accesses it via `find.byType(Scrollable)` and checks `ScrollPosition.pixels`.

## Risks / Trade-offs

- [R] `flutter_markdown` rendering varies by Flutter version → Mitigation: tests assert widget types + text content, not pixel output
- [R] Keyboard events require `HardwareKeyboard.instance.isShiftPressed` — Shift+Enter simulation uses `simulateKeyDownEvent(LogicalKeyboardKey.shift)` + `tester.sendKeyEvent(LogicalKeyboardKey.enter)` + `simulateKeyUpEvent(LogicalKeyboardKey.shift)`. This is fragile because the key event pipeline is Flutter-internal and may change across versions. If too unstable, fall back to testing Enter-only in widget tests and Shift+Enter at integration level.
- [R] `pumpAndSettle` can produce false positives for auto-scroll when content doesn't overflow → Mitigation: use explicit pump sequence (`pump()` → `pump(Duration(ms: 200))`) and assert `maxScrollExtent > 0` before checking scroll position
- [R] Multiple `Scrollable` widgets in tree (ToolCallCard's `SingleChildScrollView`) → use `find.byType(ListView)` or `find.byType(Scrollable).first` to target the correct scrollable
