import 'package:flutter/material.dart';
import 'package:flutter_markdown/flutter_markdown.dart';

class MessageBubble extends StatelessWidget {
  final String role;
  final String content;
  final bool isStreaming;

  const MessageBubble({
    super.key,
    required this.role,
    required this.content,
    this.isStreaming = false,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isUser = role == 'user';

    final alignment = isUser ? CrossAxisAlignment.end : CrossAxisAlignment.start;
    final bgColor = isUser
        ? theme.colorScheme.primaryContainer
        : theme.colorScheme.surfaceContainerHighest;
    final radius = BorderRadius.only(
      topLeft: const Radius.circular(12),
      topRight: const Radius.circular(12),
      bottomLeft: Radius.circular(isUser ? 12 : 4),
      bottomRight: Radius.circular(isUser ? 4 : 12),
    );

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
      child: Column(crossAxisAlignment: alignment, children: [
        Padding(
          padding: const EdgeInsets.only(bottom: 2, left: 4, right: 4),
          child: Text(
            isUser ? 'You' : 'Assistant',
            style: TextStyle(
              fontSize: 11,
              fontWeight: FontWeight.w600,
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
        ),
        Container(
          constraints: const BoxConstraints(maxWidth: 600),
          decoration: BoxDecoration(
            color: bgColor,
            borderRadius: radius,
          ),
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
          child: isUser
              ? Text(content, style: const TextStyle(fontSize: 14, height: 1.5))
              : MarkdownBody(
                  data: content,
                  selectable: true,
                  styleSheet: MarkdownStyleSheet(
                    p: const TextStyle(fontSize: 14, height: 1.5),
                    code: TextStyle(
                      fontSize: 13,
                      backgroundColor: theme.colorScheme.surfaceContainerLow,
                      fontFamily: 'monospace',
                    ),
                    codeblockDecoration: BoxDecoration(
                      color: theme.colorScheme.surfaceContainerLow,
                      borderRadius: BorderRadius.circular(8),
                    ),
                    blockquoteDecoration: BoxDecoration(
                      border: Border(
                        left: BorderSide(
                          color: theme.colorScheme.primary,
                          width: 3,
                        ),
                      ),
                    ),
                  ),
                ),
        ),
        if (isStreaming)
          Padding(
            padding: const EdgeInsets.only(top: 4, left: 4),
            child: _StreamingDots(),
          ),
      ]),
    );
  }
}

class _StreamingDots extends StatefulWidget {
  @override
  State<_StreamingDots> createState() => _StreamingDotsState();
}

class _StreamingDotsState extends State<_StreamingDots>
    with SingleTickerProviderStateMixin {
  late final AnimationController _ctrl;

  @override
  void initState() {
    super.initState();
    _ctrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1200),
    )..repeat();
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _ctrl,
      builder: (_, child) {
        final dots = '.' * (1 + (_ctrl.value * 3).toInt() % 3);
        return Text(
          dots,
          style: TextStyle(
            fontSize: 18,
            fontWeight: FontWeight.bold,
            color: Theme.of(context).colorScheme.onSurfaceVariant,
          ),
        );
      },
    );
  }
}