import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_markdown/flutter_markdown.dart';

import 'package:alias_agent/ui/message_bubble.dart';

/// Traverse [InlineSpan] tree; return true if any [TextSpan] matches [predicate].
bool _hasTextSpan(InlineSpan root, bool Function(TextSpan span) predicate) {
  if (root is TextSpan) {
    if (predicate(root)) return true;
    for (final child in root.children ?? <InlineSpan>[]) {
      if (_hasTextSpan(child, predicate)) return true;
    }
  }
  return false;
}

/// Build the TextSpan tree that flutter_markdown renders via EditableText.
InlineSpan _markdownSpans(WidgetTester tester) {
  final edit = tester.widget<EditableText>(find.byType(EditableText));
  return edit.controller.buildTextSpan(
    context: tester.element(find.byType(MarkdownBody)),
    withComposing: false,
  );
}

Widget _bubble(String content) {
  return MaterialApp(
    home: Scaffold(
      body: MessageBubble(role: 'assistant', content: content),
    ),
  );
}

void main() {
  group('Markdown rendering', () {
    // ── 1.1 Fenced code block ──────────────────────────────────────

    testWidgets('fenced code block with language renders monospace + bg color',
        (tester) async {
      await tester.pumpWidget(_bubble('```dart\nprint("hello");\n```'));

      // Text content is visible
      expect(find.textContaining('print'), findsOneWidget);

      // Code span has monospace font + background color
      final spans = _markdownSpans(tester);
      final hasMonoBg = _hasTextSpan(spans, (s) {
        final t = s.text ?? '';
        return t.contains('print') &&
            s.style?.fontFamily == 'monospace' &&
            s.style?.backgroundColor != null;
      });
      expect(hasMonoBg, isTrue);
    });

    testWidgets('fenced code block without language renders monospace', (tester) async {
      await tester.pumpWidget(_bubble('```\nplain text\n```'));

      expect(find.textContaining('plain text'), findsOneWidget);

      final spans = _markdownSpans(tester);
      final hasMono = _hasTextSpan(spans, (s) {
        final t = s.text ?? '';
        return t.contains('plain text') && s.style?.fontFamily == 'monospace';
      });
      expect(hasMono, isTrue);
    });

    // ── 1.2 Inline code ────────────────────────────────────────────

    testWidgets('inline code renders monospace with distinct background', (tester) async {
      await tester.pumpWidget(_bubble('Use `code` inline.'));

      expect(find.textContaining('Use'), findsOneWidget);
      expect(find.textContaining('inline'), findsOneWidget);

      final spans = _markdownSpans(tester);
      final hasInlineCode = _hasTextSpan(spans, (s) {
        final t = s.text ?? '';
        return t == 'code' &&
            s.style?.fontFamily == 'monospace' &&
            s.style?.backgroundColor != null;
      });
      expect(hasInlineCode, isTrue);
    });

    // ── 1.3 Bold ───────────────────────────────────────────────────

    testWidgets('bold text renders with FontWeight.bold', (tester) async {
      await tester.pumpWidget(_bubble('This is **bold** text.'));

      expect(find.textContaining('This is'), findsOneWidget);

      final spans = _markdownSpans(tester);
      final hasBold = _hasTextSpan(spans, (s) {
        final t = s.text ?? '';
        return t == 'bold' && s.style?.fontWeight == FontWeight.bold;
      });
      expect(hasBold, isTrue);
    });

    // ── 1.4 Italic ─────────────────────────────────────────────────

    testWidgets('italic text renders with italic style', (tester) async {
      await tester.pumpWidget(_bubble('This is *italic* text.'));

      expect(find.textContaining('This is'), findsOneWidget);

      final spans = _markdownSpans(tester);
      final hasItalic = _hasTextSpan(spans, (s) {
        final t = s.text ?? '';
        return t == 'italic' && s.style?.fontStyle == FontStyle.italic;
      });
      expect(hasItalic, isTrue);
    });

    // ── 1.5 Links ──────────────────────────────────────────────────

    testWidgets('link text is rendered with colored style', (tester) async {
      await tester.pumpWidget(_bubble('Visit [example](https://example.com) for more.'));

      // Link text appears
      expect(find.textContaining('example'), findsOneWidget);

      final spans = _markdownSpans(tester);
      final hasColored = _hasTextSpan(spans, (s) {
        final t = s.text ?? '';
        // Link text "example" should have color (not default text color)
        return t == 'example' && s.style?.color != null;
      });
      expect(hasColored, isTrue);
    });

    // ── 1.6 Unordered list ─────────────────────────────────────────

    testWidgets('unordered list renders bullets', (tester) async {
      await tester.pumpWidget(_bubble('- item1\n- item2'));

      expect(find.textContaining('item1'), findsOneWidget);
      expect(find.textContaining('item2'), findsOneWidget);

      // flutter_markdown renders bullet "•" as a Text widget
      expect(find.text('•'), findsAtLeast(1));
    });
  });
}
