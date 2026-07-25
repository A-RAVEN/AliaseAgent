import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

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
    final hasResultArea = a.status != ToolCallStatus.executing;
    final hasStructured = a.resultSections != null;

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
            if (hasResultArea) ...[
              const Divider(height: 1),
              // Collapse/expand toggle
              if (hasStructured || a.resultPreview != null)
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
              // Body
              Padding(
                padding: const EdgeInsets.fromLTRB(10, 0, 10, 8),
                child: _buildResultBody(context, a, _expanded),
              ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _buildResultBody(BuildContext context, ToolCallActivity a, bool expanded) {
    final theme = Theme.of(context);

    // Structured results (web_search, web_fetch)
    if (a.resultSections != null) {
      final sections = a.resultSections!;

      if (!expanded) {
        // Collapsed: one-line summary
        if (sections.isEmpty) {
          return _resultBox(theme, Text('No results found',
              style: TextStyle(fontSize: 12, fontFamily: 'monospace',
                  color: theme.colorScheme.onSurfaceVariant)));
        }
        var totalItems = 0;
        for (final s in sections) { totalItems += s.items.length; }
        return _resultBox(theme, Text('${sections.length} providers, $totalItems results',
            style: TextStyle(fontSize: 12, fontFamily: 'monospace',
                color: theme.colorScheme.onSurfaceVariant)));
      }

      // Expanded: per-section rendering
      if (sections.isEmpty) {
        return _resultBox(theme, Text('No results found',
            style: TextStyle(fontSize: 12, fontFamily: 'monospace',
                color: theme.colorScheme.onSurfaceVariant)));
      }

      return ConstrainedBox(
        constraints: const BoxConstraints(maxHeight: 400),
        child: SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: sections.map((section) => _buildSection(theme, section)).toList(),
          ),
        ),
      );
    }

    // Fallback: string-based display (non-search tools)
    final text = expanded ? (a.result ?? '') : (a.resultPreview ?? '');
    return _resultBox(theme, SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      child: SelectableText(
        text,
        style: TextStyle(fontSize: 12, fontFamily: 'monospace',
            color: theme.colorScheme.onSurfaceVariant),
      ),
    ));
  }

  Widget _buildSection(ThemeData theme, ResultSection section) {
    final hasError = section.error != null;
    final count = section.items.length;

    return Container(
      margin: const EdgeInsets.only(bottom: 6),
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(4),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Section header
          Padding(
            padding: const EdgeInsets.fromLTRB(8, 6, 8, 4),
            child: Row(
              children: [
                Text(
                  section.label,
                  style: TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.w600,
                    color: theme.colorScheme.onSurface,
                  ),
                ),
                if (hasError) ...[
                  const SizedBox(width: 6),
                  Icon(Icons.error_outline, size: 14, color: theme.colorScheme.error),
                  const SizedBox(width: 4),
                  Expanded(
                    child: Text(
                      section.error!,
                      style: TextStyle(fontSize: 11, color: theme.colorScheme.error),
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                ] else ...[
                  const SizedBox(width: 6),
                  Text(
                    '$count results',
                    style: TextStyle(
                      fontSize: 11,
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                ],
              ],
            ),
          ),
          // Items
          if (!hasError)
            ...section.items.asMap().entries.map((entry) {
              final idx = entry.key + 1;
              final item = entry.value;
              return _buildItem(theme, idx, item,
                  isLast: idx == section.items.length);
            }),
        ],
      ),
    );
  }

  Widget _buildItem(ThemeData theme, int index, ResultItem item,
      {bool isLast = false}) {
    final snippet = (item.content != null && item.content!.length > 200)
        ? '${item.content!.substring(0, 200)}...'
        : (item.content ?? '');

    return Container(
      padding: const EdgeInsets.fromLTRB(8, 4, 8, 4),
      decoration: BoxDecoration(
        border: isLast
            ? null
            : Border(
                bottom: BorderSide(
                    color: theme.dividerColor.withValues(alpha: 0.3), width: 0.5),
              ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Title
          if (item.title != null && item.title!.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(bottom: 2),
              child: Text(
                '#$index ${item.title}',
                style: TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w600,
                  color: theme.colorScheme.onSurface,
                ),
              ),
            ),
          // URL (clickable)
          if (item.url != null && item.url!.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(bottom: 2),
              child: InkWell(
                onTap: () => _launchUrl(item.url!),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Flexible(
                      child: Text(
                        item.url!,
                        style: TextStyle(
                          fontSize: 11,
                          fontFamily: 'monospace',
                          color: theme.colorScheme.primary,
                          decoration: TextDecoration.underline,
                        ),
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                    const SizedBox(width: 2),
                    Icon(Icons.open_in_new, size: 12,
                        color: theme.colorScheme.primary),
                  ],
                ),
              ),
            ),
          // Content snippet
          if (snippet.isNotEmpty)
            Text(
              snippet,
              style: TextStyle(
                fontSize: 11,
                color: theme.colorScheme.onSurfaceVariant,
              ),
              maxLines: 3,
              overflow: TextOverflow.ellipsis,
            ),
        ],
      ),
    );
  }

  Future<void> _launchUrl(String url) async {
    final uri = Uri.tryParse(url);
    if (uri != null && (uri.scheme == 'http' || uri.scheme == 'https')) {
      await launchUrl(uri, mode: LaunchMode.externalApplication);
    }
  }

  Widget _resultBox(ThemeData theme, Widget child) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(8),
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(4),
      ),
      child: child,
    );
  }
}