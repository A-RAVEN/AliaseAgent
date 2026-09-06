import 'dart:convert';

import 'package:flutter/material.dart';

import '../models/chat_item.dart';
import '../services/context_snapshot.dart';
import 'message_bubble.dart';
import 'thinking_card.dart';

/// Which view the conversation area shows (task 3.1). Referenced by
/// `ChatScreenState` to toggle between the original conversation view and the
/// real context view.
enum ContextViewMode { conversation, context }

/// A faithful, per-block rendering of the context snapshot actually handed to
/// the model gateway on the main-conversation request (design D5).
///
/// Each message is shown with a `[idx] role` header (the first — typically a
/// user — message is numbered 0). Content blocks are dispatched by type:
/// `text` → `MessageBubble` (or `SummaryItem` / `(no text)` placeholder),
/// `thinking` → `ThinkingCard`, `tool_use` → pretty-printed `JsonBlock`,
/// `tool_result` → its `tool_use_id` + live-sent body. Collapsible
/// "System Prompt" / "Tools (N)" / raw-JSON-copy sections sit above the list.
class ContextView extends StatelessWidget {
  final ContextSnapshot? snapshot;

  const ContextView({super.key, this.snapshot});

  @override
  Widget build(BuildContext context) {
    final snap = snapshot;
    if (snap == null) {
      return const _NoSnapshot();
    }
    final messages = snap.messages;
    return ListView.builder(
      padding: const EdgeInsets.all(8),
      // index 0 = collapsible System Prompt / Tools / raw-JSON sections,
      // then one item per message.
      itemCount: messages.length + 1,
      itemBuilder: (context, index) {
        if (index == 0) {
          return _ContextHeader(snapshot: snap);
        }
        return _MessageBlock(message: messages[index - 1], index: index - 1);
      },
    );
  }
}

// ---------------------------------------------------------------------------
// No snapshot yet
// ---------------------------------------------------------------------------

class _NoSnapshot extends StatelessWidget {
  const _NoSnapshot();

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Text(
        '尚无捕获的上下文快照',
        style: TextStyle(color: Theme.of(context).colorScheme.onSurfaceVariant),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Per-message block rendering (task 2.1 block dispatch, 2.2 reuse, 2.6 traps)
// ---------------------------------------------------------------------------

class _MessageBlock extends StatelessWidget {
  final Map<String, dynamic> message;
  final int index;

  const _MessageBlock({required this.message, required this.index});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final role = (message['role'] as String?) ?? 'unknown';
    final contentRaw = message['content'];
    final blocks = contentRaw is List ? contentRaw : const <dynamic>[];

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 6),
          child: Text(
            '[$index] $role',
            style: TextStyle(
              fontSize: 12,
              fontWeight: FontWeight.w700,
              color: theme.colorScheme.primary,
            ),
          ),
        ),
        for (final block in blocks)
          if (block is Map<String, dynamic>) _BlockView(block: block, role: role),
        if (blocks.isEmpty)
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 2),
            child: Text(
              '(no content)',
              style: TextStyle(
                fontSize: 12,
                fontStyle: FontStyle.italic,
                color: theme.colorScheme.onSurfaceVariant
                    .withValues(alpha: 0.7),
              ),
            ),
          ),
        const Divider(height: 12),
      ],
    );
  }
}

class _BlockView extends StatelessWidget {
  final Map<String, dynamic> block;
  final String role;

  const _BlockView({required this.block, required this.role});

  @override
  Widget build(BuildContext context) {
    final type = block['type'] as String?;
    switch (type) {
      case 'text':
        final text = (block['text'] as String?) ?? '';
        if (text.trim().isEmpty) {
          return _NoTextPlaceholder();
        }
        if (_isSummaryMarker(text)) {
          return SummaryItem(text: text);
        }
        return MessageBubble(role: role, content: text);
      case 'thinking':
        return ThinkingCard(
          item: ChatThinkingItem(
            thinking: (block['thinking'] as String?) ?? '',
            signature: block['signature'] as String?,
            isStreaming: false,
          ),
        );
      case 'tool_use':
        return JsonBlock(
          label: 'tool_use: ${block['name'] ?? 'unknown'} · id=${block['id'] ?? ''}',
          value: block['input'] ?? {},
        );
      case 'tool_result':
        return _ToolResultBlock(block: block);
      default:
        return Padding(
          padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 2),
          child: Text(
            '(未知块: $type)',
            style: TextStyle(
              fontSize: 12,
              color: Theme.of(context).colorScheme.onSurfaceVariant,
            ),
          ),
        );
    }
  }
}

/// An empty `text` block of an assistant (纯工具轮) is shown as an explicit
/// placeholder rather than hiding the message (task 2.6 / design D5).
class _NoTextPlaceholder extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
      child: Text(
        '(no text)',
        style: TextStyle(
          fontSize: 13,
          fontStyle: FontStyle.italic,
          color: theme.colorScheme.onSurfaceVariant.withValues(alpha: 0.7),
        ),
      ),
    );
  }
}

bool _isSummaryMarker(String text) =>
    text.startsWith('## 更早上下文');

// ---------------------------------------------------------------------------
// tool_result block (task 2.5)
// ---------------------------------------------------------------------------

class _ToolResultBlock extends StatelessWidget {
  final Map<String, dynamic> block;

  const _ToolResultBlock({required this.block});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final toolUseId = (block['tool_use_id'] as String?) ?? '';
    // The body is EXACTLY what was transmitted this send. On a live tool-loop
    // round that is the raw body; but when the request is a replay/compaction
    // projection (full-send or fold path), an oversized body has already been
    // elided by _elideOversizedToolResult and carries this marker — so the view
    // must label the elided/raw form truthfully, never blanket-claim un-elided
    // (honesty review F-impl-1).
    final body = block['content'] ?? '';
    final isElided = body is String && body.contains('[tool_result body elided:');
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'tool_result · id=$toolUseId · 现场发送版 (${isElided ? 'elided' : 'un-elided'})',
            style: TextStyle(
              fontSize: 12,
              fontWeight: FontWeight.w600,
              color: theme.colorScheme.tertiary,
            ),
          ),
          const SizedBox(height: 4),
          JsonBlock(
            label: 'content',
            value: block['content'] ?? '',
          ),
        ],
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Summary text block (task 2.4)
// ---------------------------------------------------------------------------

/// A summary text block whose text begins with the consolidation marker is
/// rendered as its own labeled, collapsible card — NOT merged into the same
/// paragraph as neighboring blocks (the compaction projection inserts multiple
/// summary blocks into a single role:user message's content).
class SummaryItem extends StatefulWidget {
  final String text;

  const SummaryItem({super.key, required this.text});

  @override
  State<SummaryItem> createState() => _SummaryItemState();
}

class _SummaryItemState extends State<SummaryItem> {
  bool _expanded = false;

  // The marker line (e.g. "## 更早上下文(压缩xN,非用户发言)") and the summary
  // body after it, so the header stays short.
  String get _marker =>
      widget.text.split('\n').first.trim();

  String get _body {
    final nl = widget.text.indexOf('\n');
    return nl < 0 ? '' : widget.text.substring(nl + 1);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Card(
      elevation: 0,
      color: theme.colorScheme.surfaceContainerHigh,
      margin: const EdgeInsets.symmetric(vertical: 4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          InkWell(
            onTap: () => setState(() => _expanded = !_expanded),
            borderRadius: BorderRadius.circular(8),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
              child: Row(
                children: [
                  const Icon(Icons.summarize, size: 14),
                  const SizedBox(width: 6),
                  Expanded(
                    child: Text(
                      _marker,
                      style: TextStyle(
                        fontSize: 12,
                        fontWeight: FontWeight.w600,
                        color: theme.colorScheme.primary,
                      ),
                    ),
                  ),
                  Icon(
                    _expanded
                        ? Icons.keyboard_arrow_up
                        : Icons.keyboard_arrow_down,
                    size: 16,
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ],
              ),
            ),
          ),
          AnimatedCrossFade(
            firstChild: const SizedBox.shrink(),
            secondChild: Padding(
              padding: const EdgeInsets.fromLTRB(10, 8, 10, 10),
              child: Align(
                alignment: Alignment.centerLeft,
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 600),
                  child: Text(
                    _body,
                    style: const TextStyle(fontSize: 13, height: 1.5),
                  ),
                ),
              ),
            ),
            crossFadeState:
                _expanded ? CrossFadeState.showSecond : CrossFadeState.showFirst,
            duration: const Duration(milliseconds: 200),
          ),
        ],
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// JsonBlock (task 2.3)
// ---------------------------------------------------------------------------

/// A collapsible, height-clamped, copyable rendering of a JSON value.
/// Pretty-printed with `JsonEncoder.withIndent` (Dart's top-level `jsonEncode`
/// has no `indent` parameter). Used for `tool_use.input` (which may carry
/// absolute paths = re-execution keys, so it is NEVER truncated) and for a
/// `tool_result.content` that parses as JSON.
///
/// For a `String` value that isn't valid JSON (e.g. plain tool output), it is
/// shown verbatim; otherwise a Map/List is pretty-printed.
class JsonBlock extends StatefulWidget {
  final String label;
  final Object? value;

  const JsonBlock({super.key, required this.label, this.value});

  @override
  State<JsonBlock> createState() => _JsonBlockState();
}

class _JsonBlockState extends State<JsonBlock> {
  bool _expanded = false;

  late final String _pretty;

  @override
  void initState() {
    super.initState();
    _pretty = _computePretty(widget.value);
  }

  static String _computePretty(Object? value) {
    if (value == null) return 'null';
    if (value is String) {
      // A string is already a value: try to pretty-print if it parses as JSON,
      // else show it verbatim (e.g. plain tool output).
      try {
        return const JsonEncoder.withIndent('  ')
            .convert(jsonDecode(value));
      } catch (_) {
        return value;
      }
    }
    if (value is Map || value is List) {
      return const JsonEncoder.withIndent('  ').convert(value);
    }
    return value.toString();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          InkWell(
            onTap: () => setState(() => _expanded = !_expanded),
            borderRadius: BorderRadius.circular(8),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 5),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Icon(Icons.data_object, size: 13),
                  const SizedBox(width: 6),
                  Flexible(
                    child: Text(
                      widget.label,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 12,
                        fontWeight: FontWeight.w600,
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                    ),
                  ),
                  const SizedBox(width: 4),
                  Icon(
                    _expanded
                        ? Icons.keyboard_arrow_up
                        : Icons.keyboard_arrow_down,
                    size: 16,
                    color: theme.colorScheme.onSurfaceVariant
                        .withValues(alpha: 0.6),
                  ),
                ],
              ),
            ),
          ),
          AnimatedCrossFade(
            firstChild: const SizedBox.shrink(),
            secondChild: Container(
              width: double.infinity,
              constraints: const BoxConstraints(maxWidth: 700, maxHeight: 400),
              margin: const EdgeInsets.only(left: 6, right: 6, bottom: 4),
              padding: const EdgeInsets.all(8),
              decoration: BoxDecoration(
                color: theme.colorScheme.surfaceContainerLow,
                borderRadius: BorderRadius.circular(8),
                border: Border(
                  left: BorderSide(
                    color: theme.colorScheme.primary.withValues(alpha: 0.5),
                    width: 2,
                  ),
                ),
              ),
              child: SingleChildScrollView(
                child: SelectableText(
                  _pretty,
                  style: const TextStyle(
                    fontFamily: 'monospace',
                    fontSize: 12,
                    height: 1.4,
                  ),
                ),
              ),
            ),
            crossFadeState:
                _expanded ? CrossFadeState.showSecond : CrossFadeState.showFirst,
            duration: const Duration(milliseconds: 200),
          ),
        ],
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Collapsible System Prompt / Tools / raw-JSON sections (task 2.6, 2.7)
// ---------------------------------------------------------------------------

class _ContextHeader extends StatelessWidget {
  final ContextSnapshot snapshot;

  const _ContextHeader({required this.snapshot});

  @override
  Widget build(BuildContext context) {
    final tools = _parseTools(snapshot.toolsJson);
    final rawJson = const JsonEncoder.withIndent('  ')
        .convert(snapshot.toRawJson());
    final theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 6),
          child: Text(
            snapshot.sessionLabel,
            style: TextStyle(
              fontSize: 12,
              fontStyle: FontStyle.italic,
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
        ),
        _CollapsibleSection(
          title: 'System Prompt',
          body: SelectableText(snapshot.systemPrompt),
        ),
        _CollapsibleSection(
          title: 'Tools (${tools.length})',
          body: tools.isEmpty
              ? const Text('(no tools)')
              : Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    for (final t in tools)
                      Padding(
                        padding: const EdgeInsets.symmetric(vertical: 2),
                        child: Text('• $t'),
                      ),
                  ],
                ),
        ),
        _CollapsibleSection(
          title: 'Copy 原始 JSON',
          body: SelectableText(rawJson),
        ),
        const Divider(),
      ],
    );
  }

  /// Extract tool names from the toolsJson array (each entry's `name`).
  static List<String> _parseTools(String toolsJson) {
    try {
      final decoded = jsonDecode(toolsJson);
      if (decoded is List) {
        return [
          for (final t in decoded)
            if (t is Map<String, dynamic>) '${t['name'] ?? 'unknown'}',
        ];
      }
    } catch (_) {
      // Non-JSON / empty toolsJson — treat as no tools.
    }
    return const [];
  }
}

class _CollapsibleSection extends StatefulWidget {
  final String title;
  final Widget body;

  const _CollapsibleSection({required this.title, required this.body});

  @override
  State<_CollapsibleSection> createState() => _CollapsibleSectionState();
}

class _CollapsibleSectionState extends State<_CollapsibleSection> {
  bool _expanded = false;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          InkWell(
            onTap: () => setState(() => _expanded = !_expanded),
            borderRadius: BorderRadius.circular(8),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
              child: Row(
                children: [
                  Icon(
                    _expanded
                        ? Icons.keyboard_arrow_down
                        : Icons.keyboard_arrow_right,
                    size: 16,
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                  const SizedBox(width: 6),
                  Text(
                    widget.title,
                    style: TextStyle(
                      fontSize: 13,
                      fontWeight: FontWeight.w600,
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                ],
              ),
            ),
          ),
          if (_expanded)
            Padding(
              padding: const EdgeInsets.only(left: 14, bottom: 6, top: 2),
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 700, maxHeight: 400),
                child: SingleChildScrollView(
                  child: Align(
                    alignment: Alignment.centerLeft,
                    child: widget.body,
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}
