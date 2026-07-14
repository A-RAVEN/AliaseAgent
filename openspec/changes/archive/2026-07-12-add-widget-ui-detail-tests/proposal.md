## Why

Current widget/integration tests verify the core message send→receive flow and session management, but skip three UI detail categories: (1) Markdown rendering (code blocks, bold, italic, inline code), (2) keyboard input behavior (Enter submit vs Shift+Enter newline), and (3) auto-scroll behavior. These are specified in `chat-ui/spec.md` but lack automated verification. Filling these gaps brings test coverage to completeness for the Dart-side UI layer.

## What Changes

- Add widget tests for Markdown rendering: code blocks with monospace font, bold/italic/inline code styling
- Add widget tests for keyboard shortcuts: Enter submits, Shift+Enter inserts newline
- Add widget tests for auto-scroll: list scrolls to bottom on new message and streaming content
- Existing code unchanged — purely additive test coverage

## Capabilities

### New Capabilities
- `markdown-render-tests`: Widget tests verifying that Markdown content (fenced code blocks, bold, italic, inline code, lists, links) renders with correct styling
- `keyboard-input-tests`: Widget tests verifying Enter=submit, Shift+Enter=newline behavior in the chat input field
- `auto-scroll-tests`: Widget tests verifying the message list scrolls to bottom on new user message, assistant chunk, and stream completion

### Modified Capabilities
<!-- None — pure test addition, no requirement changes -->

## Impact

- `test/widget/markdown_render_test.dart` — new file
- `test/widget/keyboard_input_test.dart` — new file
- `test/widget/auto_scroll_test.dart` — new file
- No production code changes
