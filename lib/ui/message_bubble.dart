import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show LogicalKeyboardKey;
import 'package:flutter_markdown/flutter_markdown.dart';

/// 16.5：全窗查看层的稳定 key，用例靠它判断"查看层有没有打开"。
const Key imageViewerKey = ValueKey('bubble-image-viewer');

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

  /// 气泡内边距（多图布局要按内容区算格子，所以提成常量给两处共用）。
  static const EdgeInsets bubblePadding =
      EdgeInsets.symmetric(horizontal: 14, vertical: 10);

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
          padding: bubblePadding,
          child: Column(
            crossAxisAlignment:
                isUser ? CrossAxisAlignment.end : CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              // 图在文字上面（design D6 的顺序：先看到图，再看它旁边说了什么）
              // 16.7：单张走 600×400 的原路径；两张以上按 2 列排、最多 4 格
              // （2 行 × 200 = 400 = 气泡的高度上界），超过 4 张时第 4 格盖「+N」。
              if (imagePaths.isNotEmpty) ...[
                imagePaths.length == 1
                    ? _buildImage(context, imagePaths.first)
                    : _buildImageGrid(context),
                // 只有后面还有文字时才留这 6 像素；否则图下会多出一块空白，
                // 让"两行图 + 气泡 padding"超过 400 的高度上界（实测 406）。
                if (content.isNotEmpty) const SizedBox(height: 6),
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

  /// 16.7：多张图按 2 列排，最多显示 4 格；第 4 格在超过 4 张时盖一层「+N」。
  ///
  /// 数字链见 `openspec/changes/add-image-input/tasks.md` 的 16.7：每格 300×200 来自
  /// 既有 `maxImageWidth/2` 与 `maxImageHeight/2`，两行合计 400 = 既有的 `maxImageHeight`，
  /// 所以气泡高度不会因为附图多而被撑破。
  Widget _buildImageGrid(BuildContext context) {
    const perRow = 2;
    // 间距沿用产品里既有的 6（图与文字之间的 `SizedBox(height: 6)`），不另造新数。
    // 每格尺寸从"气泡内容区"反推，保证两行合计不超过气泡的高度上界：
    //   内容区宽 = 600 − 2×14 = 572（14 是气泡既有的水平 padding）
    //   内容区高 = 400 − 2×10 = 380（10 是既有垂直 padding）
    //   cellW = (572 − 2×6) / 2 = 280 ；cellH = (380 − 2×6) / 2 = 184
    //   两行 (184 + 6) × 2 = 380 ≤ 400 ✓
    const gap = 6.0;
    final innerW = maxImageWidth - bubblePadding.horizontal;
    final innerH = maxImageHeight - bubblePadding.vertical;
    final cellW = (innerW - gap * perRow) / perRow;
    final cellH = (innerH - gap * perRow) / perRow;
    final shown = imagePaths.length > 4 ? 4 : imagePaths.length;
    final rows = <Widget>[];
    for (var r = 0; r * perRow < shown; r++) {
      final cells = <Widget>[];
      for (var c = 0; c < perRow; c++) {
        final i = r * perRow + c;
        if (i >= shown) break;
        cells.add(Padding(
          padding: EdgeInsets.only(right: c == 0 ? gap : 0, bottom: gap),
          child: _buildImageCell(context, i, cellW, cellH),
        ));
      }
      rows.add(Row(mainAxisSize: MainAxisSize.min, children: cells));
    }
    return Column(
      crossAxisAlignment:
          imagePaths.isNotEmpty ? CrossAxisAlignment.end : CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: rows,
    );
  }

  /// 多图里的一格；第 4 格且总数超过 4 时，右下角盖一句「+N」。
  Widget _buildImageCell(BuildContext context, int index, double w, double h) {
    final theme = Theme.of(context);
    final path = imagePaths[index];
    final hiddenCount =
        (imagePaths.length > 4 && index == 3) ? imagePaths.length - 4 : 0;
    return ConstrainedBox(
      constraints: BoxConstraints(maxWidth: w, maxHeight: h),
      child: InkWell(
        key: ValueKey('bubble-image-$path'),
        onTap: () => _openImageViewer(context, imagePaths, index),
        child: ClipRRect(
          borderRadius: BorderRadius.circular(8),
          child: Stack(
            children: [
              Image.file(
                File(path),
                width: w,
                height: h,
                fit: BoxFit.cover,
                errorBuilder: (_, _, _) => SizedBox(
                  width: w,
                  height: h,
                  child: Center(
                    child: Text(
                      '[图片已丢失]',
                      style: TextStyle(
                          fontSize: 12, color: theme.colorScheme.error),
                    ),
                  ),
                ),
              ),
              if (hiddenCount > 0)
                Positioned.fill(
                  child: Container(
                    color: Colors.black54,
                    alignment: Alignment.center,
                    child: Text(
                      '+$hiddenCount',
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 18,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }

  /// 一张附件图。读不出来（文件被删、路径失效）时退回一句可见的说明 ——
  /// 不让整条气泡抛异常，也不留一块空白让人以为"图就是这么小"。
  ///
  /// 16.5（2026-10-24 用户要求）：点一下可以看原图。缩略图受 600×400 限制，
  /// 细节看不清（官方规格里模型那侧也只看到约 1300×1300 的缩放结果，所以缩略图
  /// 本来就不该承担"看清细节"），所以点开一个覆盖整窗的查看层。
  Widget _buildImage(BuildContext context, String path) {
    final theme = Theme.of(context);
    return ConstrainedBox(
      constraints: const BoxConstraints(
        maxWidth: maxImageWidth,
        maxHeight: maxImageHeight,
      ),
      child: InkWell(
        key: ValueKey('bubble-image-$path'),
        onTap: () => _openImageViewer(context, imagePaths, 0),
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
      ),
    );
  }

  /// 16.5：覆盖整个窗口的查看层。多图时可用左右按钮翻页（16.7 的「+N」点进来
  /// 就落在第 4 张上，再往后翻能看到被折起来的那些）。
  ///
  /// 缩放用 `InteractiveViewer` 的默认上下限（不自定义倍数）；退出方式给两个：
  /// 右上角关闭按钮、以及 `Esc`。
  static void _openImageViewer(
      BuildContext context, List<String> images, int startIndex) {
    showDialog<void>(
      context: context,
      barrierDismissible: true,
      barrierColor: Colors.black87,
      builder: (dialogContext) {
        var index = startIndex.clamp(0, images.length - 1);
        return StatefulBuilder(
          builder: (builderContext, setDialogState) {
            void close() => Navigator.of(dialogContext).pop();
            return CallbackShortcuts(
              bindings: {
                const SingleActivator(LogicalKeyboardKey.escape): close,
              },
              child: Focus(
                autofocus: true,
                child: Stack(
                  key: imageViewerKey,
                  children: [
                    Positioned.fill(
                      child: InteractiveViewer(
                        child: Center(
                          child: Image.file(
                            File(images[index]),
                            fit: BoxFit.contain,
                            errorBuilder: (_, _, _) => const Text(
                              '[图片已丢失]',
                              style: TextStyle(color: Colors.white),
                            ),
                          ),
                        ),
                      ),
                    ),
                    Positioned(
                      top: 8,
                      right: 8,
                      child: Row(children: [
                        if (images.length > 1)
                          Padding(
                            padding: const EdgeInsets.only(right: 8),
                            child: Text(
                              '${index + 1}/${images.length}',
                              style: const TextStyle(color: Colors.white),
                            ),
                          ),
                        IconButton(
                          tooltip: '关闭',
                          onPressed: close,
                          icon: const Icon(Icons.close, color: Colors.white),
                        ),
                      ]),
                    ),
                    if (index > 0)
                      Positioned(
                        left: 8,
                        top: 0,
                        bottom: 0,
                        child: IconButton(
                          tooltip: '上一张',
                          onPressed: () =>
                              setDialogState(() => index = index - 1),
                          icon: const Icon(Icons.chevron_left,
                              color: Colors.white, size: 32),
                        ),
                      ),
                    if (index < images.length - 1)
                      Positioned(
                        right: 8,
                        top: 0,
                        bottom: 0,
                        child: IconButton(
                          tooltip: '下一张',
                          onPressed: () =>
                              setDialogState(() => index = index + 1),
                          icon: const Icon(Icons.chevron_right,
                              color: Colors.white, size: 32),
                        ),
                      ),
                  ],
                ),
              ),
            );
          },
        );
      },
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