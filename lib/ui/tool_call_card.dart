import 'package:flutter/material.dart';

import '../models/tool_call_activity.dart';

class ToolCallCard extends StatefulWidget {
  final ToolCallActivity activity;

  const ToolCallCard({super.key, required this.activity});

  @override
  State<ToolCallCard> createState() => _ToolCallCardState();
}

class _ToolCallCardState extends State<ToolCallCard> {
  bool _expanded = false;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final a = widget.activity;

    final Color borderColor;
    final IconData statusIcon;
    final String statusLabel;
    final Color statusColor;

    switch (a.status) {
      case ToolCallStatus.executing:
        borderColor = theme.colorScheme.tertiary;
        statusIcon = Icons.hourglass_top;
        statusLabel = 'Executing...';
        statusColor = theme.colorScheme.tertiary;
      case ToolCallStatus.done:
        borderColor = Colors.green.shade600;
        statusIcon = Icons.check_circle_outline;
        statusLabel = 'Done';
        statusColor = Colors.green.shade600;
      case ToolCallStatus.error:
        borderColor = theme.colorScheme.error;
        statusIcon = Icons.error_outline;
        statusLabel = 'Error';
        statusColor = theme.colorScheme.error;
    }

    final inputPreview = a.input.entries.map((e) => '${e.key}=${e.value}').join(', ');

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
      child: Container(
        constraints: const BoxConstraints(maxWidth: 600),
        decoration: BoxDecoration(
          color: theme.colorScheme.surfaceContainerLow,
          borderRadius: BorderRadius.circular(8),
          border: Border(left: BorderSide(color: borderColor, width: 3)),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Header: icon + tool name + input + status
            Padding(
              padding: const EdgeInsets.fromLTRB(10, 8, 10, 6),
              child: Row(
                children: [
                  Icon(Icons.build_outlined, size: 16, color: borderColor),
                  const SizedBox(width: 6),
                  Expanded(
                    child: Text(
                      '${a.toolName}($inputPreview)',
                      style: TextStyle(
                        fontSize: 13,
                        fontFamily: 'monospace',
                        color: theme.colorScheme.onSurface,
                      ),
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                  const SizedBox(width: 8),
                  if (a.status == ToolCallStatus.executing)
                    SizedBox(
                      width: 14,
                      height: 14,
                      child: CircularProgressIndicator(
                        strokeWidth: 2,
                        color: statusColor,
                      ),
                    ),
                  Icon(statusIcon, size: 14, color: statusColor),
                  const SizedBox(width: 4),
                  Text(
                    statusLabel,
                    style: TextStyle(fontSize: 12, color: statusColor),
                  ),
                ],
              ),
            ),
            // Result area (collapsible, only when done/error)
            if (a.status != ToolCallStatus.executing && a.resultPreview != null)
              Column(
                children: [
                  const Divider(height: 1),
                  InkWell(
                    onTap: () => setState(() => _expanded = !_expanded),
                    child: Padding(
                      padding: const EdgeInsets.fromLTRB(10, 6, 10, 6),
                      child: Row(
                        children: [
                          Icon(
                            _expanded ? Icons.expand_less : Icons.expand_more,
                            size: 16,
                            color: theme.colorScheme.onSurfaceVariant,
                          ),
                          const SizedBox(width: 4),
                          Text(
                            _expanded ? 'Collapse' : 'Expand result',
                            style: TextStyle(
                              fontSize: 11,
                              color: theme.colorScheme.onSurfaceVariant,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                  Padding(
                    padding: const EdgeInsets.fromLTRB(10, 0, 10, 8),
                    child: Container(
                      width: double.infinity,
                      padding: const EdgeInsets.all(8),
                      decoration: BoxDecoration(
                        color: theme.colorScheme.surfaceContainerHighest,
                        borderRadius: BorderRadius.circular(4),
                      ),
                      child: SingleChildScrollView(
                        scrollDirection: Axis.horizontal,
                        child: SelectableText(
                          _expanded ? (a.result ?? '') : a.resultPreview!,
                          style: TextStyle(
                            fontSize: 12,
                            fontFamily: 'monospace',
                            color: theme.colorScheme.onSurfaceVariant,
                          ),
                        ),
                      ),
                    ),
                  ),
                ],
              ),
          ],
        ),
      ),
    );
  }
}