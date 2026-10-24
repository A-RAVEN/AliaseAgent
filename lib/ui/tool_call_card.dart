import 'dart:io';

import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import '../models/tool_call_activity.dart';
import '../services/image_probe.dart';

class ToolCallCard extends StatefulWidget {
  final ToolCallActivity activity;

  const ToolCallCard({super.key, required this.activity});

  @override
  State<ToolCallCard> createState() => _ToolCallCardState();
}

class _ToolCallCardState extends State<ToolCallCard> {
  bool _expanded = false;

  /// diff 展开态里是否已经点开"还有 N 行未显示"。
  bool _showAllDiff = false;

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
    final title = _cardTitle(a, inputPreview);
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
                      title,
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

  /// edit_file / write_file 只显示路径；`read_image` 同理（元数据放正文里，
  /// 不塞进标题）；其余工具沿用整行参数预览。
  String _cardTitle(ToolCallActivity a, String inputPreview) {
    if (a.toolName == 'edit_file' ||
        a.toolName == 'write_file' ||
        a.toolName == 'read_image') {
      final path = (a.input['path'] as String?) ?? '';
      final stat = _diffStat(a);
      return stat == null
          ? '${a.toolName}($path)'
          : '${a.toolName}($path) $stat';
    }
    return '${a.toolName}($inputPreview)';
  }

  /// `read_image` 卡片正文里那一行元数据：`image/png · 800×600 · 12345 字节`。
  ///
  /// 数据从**已经落库的 `result` 信封**里解析（`image/png image, 800x600 px, 12345 bytes`）；
  /// 解析不到才去读一次文件头 —— 库里只存路径，存一份元数据只会在源文件被换掉之后撒谎。
  String _imageMetaLine(ToolCallActivity a) {
    final match = RegExp(r'(\S+) image, (\d+)x(\d+) px, (\d+) bytes')
        .firstMatch(a.result ?? '');
    if (match != null) {
      return '${match.group(1)} · ${match.group(2)}×${match.group(3)} · '
          '${match.group(4)} 字节';
    }
    final path = a.imagePath;
    if (path != null) {
      try {
        final info = probeImageBytes(File(path).readAsBytesSync());
        if (info.ok) {
          return '${info.mediaType} · ${info.width}×${info.height} · '
              '${info.bytes} 字节';
        }
      } catch (_) {
        // 读不到就走下面的兜底字符串
      }
    }
    return '图片元数据不可用';
  }

  /// `read_image` 的卡片正文：缩略图（展开后是大图 + 文字信封）。
  ///
  /// 收起状态就画出图 —— 用户要看的正是"模型看到的那张"，藏起来要他点一下才知道。
  Widget _buildImageBody(ThemeData theme, ToolCallActivity a, bool expanded) {
    final path = a.imagePath!;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        ConstrainedBox(
          constraints: const BoxConstraints(
            maxWidth: 600, // 与卡片自身的 maxWidth 一致
            maxHeight: 400, // 与结果区既有的 maxHeight 一致
          ),
          child: ClipRRect(
            borderRadius: BorderRadius.circular(6),
            child: Image.file(
              File(path),
              fit: BoxFit.contain,
              errorBuilder: (_, _, _) => Text(
                '[图片已丢失：$path]',
                style: TextStyle(fontSize: 12, color: theme.colorScheme.error),
              ),
            ),
          ),
        ),
        const SizedBox(height: 6),
        Text(
          _imageMetaLine(a),
          style: TextStyle(
            fontSize: 11,
            fontFamily: 'monospace',
            color: theme.colorScheme.onSurfaceVariant,
          ),
        ),
        if (expanded && (a.result ?? '').isNotEmpty) ...[
          const SizedBox(height: 6),
          _resultBox(
            theme,
            SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: SelectableText(
                a.result!,
                style: TextStyle(
                  fontSize: 12,
                  fontFamily: 'monospace',
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
            ),
          ),
        ],
      ],
    );
  }

  /// `+N/−M`：所有 hunk 的新增/删除行数；没有 hunks 时给 null。
  String? _diffStat(ToolCallActivity a) {
    final hunks = a.hunks;
    if (hunks == null || hunks.isEmpty) return null;
    var added = 0;
    var removed = 0;
    for (final hunk in hunks) {
      added += _splitLines(hunk.newText).length;
      removed += _splitLines(hunk.oldText).length;
    }
    return '+$added/−$removed';
  }

  /// 省略时的那句话：说清"为什么没有 diff"和这次改了几处。
  String _omissionLabel(ToolCallActivity a) {
    final match = RegExp(r'\((\d+) replacement').firstMatch(a.result ?? '');
    final count = match?.group(1);
    return count == null
        ? 'diff 未显示：改动过大'
        : 'diff 未显示：改动过大（$count 处改动）';
  }

  static List<String> _splitLines(String text) {
    if (text.isEmpty) return const <String>[];
    final trimmed =
        text.endsWith('\n') ? text.substring(0, text.length - 1) : text;
    return trimmed.split('\n');
  }

  /// 展开态里的差异区块：每处先给行号，再按行给 `-`/`+`。
  /// 默认最多 12 行内容（行号行不计），超出折叠成"还有 N 行未显示"。
  Widget _buildDiffBody(ThemeData theme, ToolCallActivity a) {
    const defaultBudget = 12;
    final children = <Widget>[];
    var shown = 0;
    var hidden = 0;
    for (final hunk in a.hunks!) {
      children.add(Padding(
        padding: const EdgeInsets.only(top: 4),
        child: Text('第 ${hunk.startLine} 行',
            style: TextStyle(
                fontSize: 11, color: theme.colorScheme.onSurfaceVariant)),
      ));
      for (final line in _splitLines(hunk.oldText)) {
        if (!_showAllDiff && shown >= defaultBudget) {
          hidden++;
          continue;
        }
        shown++;
        children.add(_diffLine('-', line, theme.colorScheme.error));
      }
      for (final line in _splitLines(hunk.newText)) {
        if (!_showAllDiff && shown >= defaultBudget) {
          hidden++;
          continue;
        }
        shown++;
        children.add(_diffLine('+', line, Colors.green.shade700));
      }
    }
    if (hidden > 0) {
      children.add(GestureDetector(
        onTap: () => setState(() => _showAllDiff = true),
        child: Padding(
          padding: const EdgeInsets.only(top: 4),
          child: Text('还有 $hidden 行未显示，点击展开',
              style: TextStyle(fontSize: 12, color: theme.colorScheme.primary)),
        ),
      ));
    }
    return _resultBox(
      theme,
      ConstrainedBox(
        constraints: const BoxConstraints(maxHeight: 400),
        child: SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: children,
          ),
        ),
      ),
    );
  }

  Widget _diffLine(String prefix, String text, Color color) {
    return Text('$prefix $text',
        style: TextStyle(
            fontSize: 12, fontFamily: 'monospace', color: color));
  }

  Widget _buildResultBody(BuildContext context, ToolCallActivity a, bool expanded) {
    final theme = Theme.of(context);

    // 带图的工具结果（`read_image`）：收起也要画出图，展开再加文字信封。
    if (a.imagePath != null) {
      return _buildImageBody(theme, a, expanded);
    }

    // 省略必须看得见：hunks 因过大被 sidecar 丢了时，卡片要说清为什么没有 diff。
    if (a.hunksOmitted != null) {
      return _resultBox(theme, Text(_omissionLabel(a),
          style: TextStyle(fontSize: 12, fontFamily: 'monospace',
              color: theme.colorScheme.onSurfaceVariant)));
    }

    // edit_file 的差异只在展开的结果区里渲染；折叠态仍是一句话结果。
    if (expanded && a.hunks != null && a.hunks!.isNotEmpty) {
      return _buildDiffBody(theme, a);
    }

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