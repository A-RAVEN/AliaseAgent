import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_markdown/flutter_markdown.dart';

class MessageBubble extends StatelessWidget {
  final String role;
  final String content;
  final bool isStreaming;

  /// 这条消息带的图片路径（只存路径，见 `Message.attachments`）。
  /// 用户消息才有；助手消息恒为空。
  final List<String> imagePaths;

  /// 这次请求到底有没有把图发出去。false 时在气泡里加一行说明
  /// （模型没声明 `input_modalities` 含 image），不静默。
  final bool imagesSent;

  const MessageBubble({
    super.key,
    required this.role,
    required this.content,
    this.isStreaming = false,
    this.imagePaths = const [],
    this.imagesSent = true,
  });

  /// 气泡里图片的显示上界：宽度沿用气泡自己的 `maxWidth: 600`，高度沿用
  /// `lib/ui/tool_call_card.dart` 里既有的 `maxHeight: 400` —— 与 `read_image`
  /// 卡片用同一组界，一张 4000×3000 的截图不会把对话推走。
  static const double maxImageWidth = 600;
  static const double maxImageHeight = 400;

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
          child: Column(
            crossAxisAlignment:
                isUser ? CrossAxisAlignment.end : CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              // 图在文字上面（design D6 的顺序：先看到图，再看它旁边说了什么）
              for (final path in imagePaths) ...[
                _buildImage(context, path),
                const SizedBox(height: 6),
              ],
              if (content.isNotEmpty)
                isUser
                    ? Text(content,
                        style: const TextStyle(fontSize: 14, height: 1.5))
                    : _buildMarkdown(theme, content),
              if (!imagesSent && imagePaths.isNotEmpty) ...[
                const SizedBox(height: 6),
                Text(
                  '模型未声明图片输入，本次没有发送图片',
                  style: TextStyle(
                    fontSize: 12,
                    color: theme.colorScheme.error,
                  ),
                ),
              ],
            ],
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

  /// 一张附件图。读不出来（文件被删、路径失效）时退回一句可见的说明 ——
  /// 不让整条气泡抛异常，也不留一块空白让人以为"图就是这么小"。
  Widget _buildImage(BuildContext context, String path) {
    final theme = Theme.of(context);
    return ConstrainedBox(
      constraints: const BoxConstraints(
        maxWidth: maxImageWidth,
        maxHeight: maxImageHeight,
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(8),
        child: Image.file(
          File(path),
          fit: BoxFit.contain,
          errorBuilder: (_, _, _) => Text(
            '[图片已丢失：$path]',
            style: TextStyle(fontSize: 12, color: theme.colorScheme.error),
          ),
        ),
      ),
    );
  }

  Widget _buildMarkdown(ThemeData theme, String content) {
    return MarkdownBody(
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