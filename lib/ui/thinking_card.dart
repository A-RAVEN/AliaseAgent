import 'package:flutter/material.dart';

import '../models/chat_item.dart';

class ThinkingCard extends StatefulWidget {
  final ChatThinkingItem item;

  const ThinkingCard({super.key, required this.item});

  @override
  State<ThinkingCard> createState() => _ThinkingCardState();
}

class _ThinkingCardState extends State<ThinkingCard> {
  bool _expanded = false;

  int get _charCount => widget.item.thinking.length;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isStreaming = widget.item.isStreaming;

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 2),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Header
          InkWell(
            onTap: () => setState(() => _expanded = !_expanded),
            borderRadius: BorderRadius.circular(8),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Text('💭', style: TextStyle(fontSize: 13)),
                  const SizedBox(width: 6),
                  Text(
                    'Thinking',
                    style: TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.w500,
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                  const SizedBox(width: 6),
                  if (isStreaming)
                    _AnimatedThinkingDots()
                  else
                    Text(
                      '· $_charCount chars',
                      style: TextStyle(
                        fontSize: 11,
                        color: theme.colorScheme.onSurfaceVariant
                            .withValues(alpha: 0.7),
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
          // Body (collapsible)
          AnimatedCrossFade(
            firstChild: const SizedBox.shrink(),
            secondChild: Container(
              width: double.infinity,
              constraints: const BoxConstraints(maxWidth: 600, maxHeight: 400),
              margin: const EdgeInsets.only(left: 6, right: 6, bottom: 4),
              padding: const EdgeInsets.all(10),
              decoration: BoxDecoration(
                color: theme.colorScheme.surfaceContainerLow,
                borderRadius: BorderRadius.circular(8),
                border: Border(
                  left: BorderSide(
                    color: theme.colorScheme.tertiary.withValues(alpha: 0.5),
                    width: 2,
                  ),
                ),
              ),
              child: SingleChildScrollView(
                child: Text(
                  widget.item.thinking,
                  style: TextStyle(
                    fontSize: 12,
                    height: 1.5,
                    fontStyle: FontStyle.italic,
                    color: theme.colorScheme.onSurfaceVariant
                        .withValues(alpha: 0.85),
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

class _AnimatedThinkingDots extends StatefulWidget {
  @override
  State<_AnimatedThinkingDots> createState() => _AnimatedThinkingDotsState();
}

class _AnimatedThinkingDotsState extends State<_AnimatedThinkingDots>
    with SingleTickerProviderStateMixin {
  late final AnimationController _ctrl;

  @override
  void initState() {
    super.initState();
    _ctrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 900),
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
            fontSize: 13,
            fontWeight: FontWeight.bold,
            color: Theme.of(context).colorScheme.tertiary,
          ),
        );
      },
    );
  }
}
