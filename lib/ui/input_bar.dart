import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

/// `Ctrl+V` 在输入行里的意图：先试贴图，没贴到再退回文本粘贴。
///
/// 单独定义一个 Intent 才能用 `Actions` 覆盖默认的 `PasteTextIntent`
/// （默认那条把 Ctrl+V 直接当"粘贴文本"，不走我们这条判断）。
class _PasteImageShortcutIntent extends Intent {
  const _PasteImageShortcutIntent();
}

/// 输入行：输入框 +（可选的）附件 + 发送按钮。
///
/// **为什么它是公开且在 `lib/` 下**：它原来叫 `_InputBar`，是 `lib/ui/chat_area.dart`
/// 里的私有类。2026-10-18 用户把上下文占用环从顶部工具栏挪到"右下角、发送按钮附近"，
/// 而「真实上下文」那一屏里没有输入区 —— 环要两屏都在，输入行就必须提到两屏共用的位置
/// 并由 `lib/main.dart` 直接构造。私有类另一个库引用不到，所以这里改成公开类、单独成文件。
///
/// 附件（`accessory`）就是给占用环留的位置：它排在输入框与发送按钮之间，
/// 与发送按钮同一行、位于其左侧。
class InputBar extends StatefulWidget {
  final TextEditingController controller;
  final VoidCallback onSubmit;

  /// 工具清单是否已就绪。未就绪时发送按钮禁用并给出可见原因
  /// （不是静默排队 —— 排队在用户看来还是"发出去了"）。
  final bool toolsReady;

  /// 排在发送按钮**左侧**的附件（今天就是上下文占用环）。
  final Widget? accessory;

  /// 已经贴进来、还没发出去的图片路径（add-image-input）。
  ///
  /// 它只参与**一条**判断：输入框没有文字时，还能不能提交。有它就能（贴一张图
  /// 就是这个用法），没它就不行。真正的缩略图渲染与移除按钮由调用方给。
  final List<String> pendingImagePaths;

  /// 点「粘贴图片」按钮时调用（读剪贴板）。传 null 就不显示这个按钮。
  final VoidCallback? onPasteImage;

  /// 点某张待发缩略图上的删除按钮时调用，参数是它在 [pendingImagePaths] 里的下标。
  final void Function(int index)? onRemoveImage;

  /// `Ctrl+V` 真正的"贴图"动作：调用方去读剪贴板，返回**是否贴到了一张图**。
  ///
  /// 返回 false 时输入行会退回普通文本粘贴（把剪贴板文本插入光标处、替换选区）——
  /// 也就是说这个快捷键不会因为加了贴图而失效。传 null 表示不接管 `Ctrl+V`。
  final Future<bool> Function()? onPasteShortcut;

  const InputBar({
    super.key,
    required this.controller,
    required this.onSubmit,
    this.toolsReady = true,
    this.accessory,
    this.pendingImagePaths = const [],
    this.onPasteImage,
    this.onRemoveImage,
    this.onPasteShortcut,
  });

  @override
  State<InputBar> createState() => _InputBarState();
}

class _InputBarState extends State<InputBar> {
  final _focusNode = FocusNode();

  @override
  void dispose() {
    _focusNode.dispose();
    super.dispose();
  }

  KeyEventResult _onKey(FocusNode node, KeyEvent event) {
    if (event is KeyDownEvent &&
        event.logicalKey == LogicalKeyboardKey.enter) {
      if (HardwareKeyboard.instance.isShiftPressed) {
        return KeyEventResult.ignored; // let TextField handle newline
      }
      _submit();
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  /// 空内容（含只有空白）不提交 —— **这条守卫住在这里**，因为输入框归它管；
  /// 这样"空输入点发送不发出去"能由 `InputBar` 自己的用例验证，而不是只靠调用方自觉。
  ///
  /// 但"空"只看文字已经不够（add-image-input）：贴了一张图、一个字没写，这条消息
  /// 是**合法**的，必须发得出去。所以判据是「没有文字**且**没有待发图片」。
  void _submit() {
    final hasText = widget.controller.text.trim().isNotEmpty;
    final hasImages = widget.pendingImagePaths.isNotEmpty;
    if (!hasText && !hasImages) return;
    widget.onSubmit();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      color: theme.colorScheme.surface,
      padding: const EdgeInsets.fromLTRB(12, 8, 8, 8),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // 待发图片条：只有真的贴了图才占位，平时一点高度都不占。
          if (widget.pendingImagePaths.isNotEmpty) _buildPendingStrip(context),
          Row(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              Expanded(
                child: _shortcutLayer(
                  Focus(
                    onKeyEvent: _onKey,
                    child: TextField(
                      controller: widget.controller,
                      focusNode: _focusNode,
                      maxLines: 5,
                      minLines: 1,
                      textInputAction: TextInputAction.newline,
                      decoration: const InputDecoration(
                        hintText: 'Type a message...',
                        border: OutlineInputBorder(),
                        contentPadding:
                            EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                        isDense: true,
                      ),
                    ),
                  ),
                ),
              ),
              const SizedBox(width: 6),
              // 环与发送按钮在这一小组里**居中对齐**：输入行整体是底对齐（`end`），而发送
              // 按钮是个比图标高的盒子 —— 直接并排放的话环会看起来偏低 14 像素（实测过）。
              Row(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.center,
                children: [
                  if (widget.onPasteImage != null) ...[
                    IconButton(
                      onPressed: widget.toolsReady ? widget.onPasteImage : null,
                      icon: const Icon(Icons.add_photo_alternate_outlined, size: 20),
                      tooltip: '粘贴图片',
                    ),
                    const SizedBox(width: 6),
                  ],
                  if (widget.accessory != null) ...[
                    widget.accessory!,
                    const SizedBox(width: 6),
                  ],
                  IconButton.filled(
                    onPressed: widget.toolsReady ? _submit : null,
                    icon: const Icon(Icons.send, size: 20),
                    tooltip: widget.toolsReady ? 'Send' : '正在准备工具…',
                  ),
                ],
              ),
            ],
          ),
        ],
      ),
    );
  }

  /// 把 `Ctrl+V` 映射到"先试贴图"。只有在调用方真的提供了 [InputBar.onPasteShortcut]
  /// 时才挂这一层，否则 Ctrl+V 保持按编辑器默认行为走。
  ///
  /// 为什么要用 `Shortcuts`+`Actions` 而不是 `Focus.onKeyEvent`：文本编辑的默认快捷键
  /// 是 `WidgetsApp` 那一层注册的，从焦点节点往上找，先命中谁由距离决定。放在输入框正上方
  /// 这一层才稳定压过默认的"粘贴文本"。
  Widget _shortcutLayer(Widget child) {
    if (widget.onPasteShortcut == null) return child;
    return Shortcuts(
      shortcuts: const {
        SingleActivator(LogicalKeyboardKey.keyV, control: true):
            _PasteImageShortcutIntent(),
      },
      child: Actions(
        actions: <Type, Action<Intent>>{
          _PasteImageShortcutIntent: CallbackAction<_PasteImageShortcutIntent>(
            onInvoke: (_) {
              _pasteViaShortcut();
              return null;
            },
          ),
        },
        child: child,
      ),
    );
  }

  /// `Ctrl+V` 的实际行为：先让调用方去贴图；**没贴到就退回普通文本粘贴**，
  /// 所以这个快捷键不会因为加了贴图功能而失效。
  Future<void> _pasteViaShortcut() async {
    final shortcut = widget.onPasteShortcut;
    if (shortcut != null) {
      final attached = await shortcut();
      if (attached) return;
    }
    await _insertClipboardText();
  }

  /// 把剪贴板文本插入到光标处（有选区就替换选区）—— 与编辑器默认粘贴等价。
  Future<void> _insertClipboardText() async {
    final data = await Clipboard.getData(Clipboard.kTextPlain);
    final text = data?.text;
    if (text == null || text.isEmpty) return;
    final current = widget.controller.text;
    final selection = widget.controller.selection;
    final valid = selection.isValid && selection.start >= 0 && selection.end >= 0;
    final start = valid ? selection.start : current.length;
    final end = valid ? selection.end : current.length;
    widget.controller.value = TextEditingValue(
      text: current.replaceRange(start, end, text),
      selection: TextSelection.collapsed(offset: start + text.length),
    );
  }

  /// 待发图片条：每张一个缩略图 + 右上角删除按钮。
  ///
  /// 缩略图 48×48 是**布局尺寸**（不是上限/阈值）；图片读不出来（文件被删、路径
  /// 失效）时退回一个图标，不让整行抛异常。
  Widget _buildPendingStrip(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        child: Row(
          children: [
            for (var i = 0; i < widget.pendingImagePaths.length; i++)
              Padding(
                padding: const EdgeInsets.only(right: 8),
                child: Stack(
                  clipBehavior: Clip.none,
                  children: [
                    ClipRRect(
                      borderRadius: BorderRadius.circular(6),
                      child: Image.file(
                        File(widget.pendingImagePaths[i]),
                        width: 48,
                        height: 48,
                        fit: BoxFit.cover,
                        errorBuilder: (_, _, _) => Container(
                          width: 48,
                          height: 48,
                          color: theme.colorScheme.surfaceContainerHighest,
                          child: Icon(Icons.broken_image_outlined,
                              size: 24, color: theme.colorScheme.onSurfaceVariant),
                        ),
                      ),
                    ),
                    if (widget.onRemoveImage != null)
                      Positioned(
                        top: -6,
                        right: -6,
                        child: IconButton(
                          onPressed: () => widget.onRemoveImage!(i),
                          icon: const Icon(Icons.close, size: 14),
                          tooltip: '移除这张图',
                          visualDensity: VisualDensity.compact,
                          constraints: const BoxConstraints(),
                          padding: const EdgeInsets.all(2),
                          style: IconButton.styleFrom(
                            backgroundColor: theme.colorScheme.surfaceContainerHighest,
                          ),
                        ),
                      ),
                  ],
                ),
              ),
          ],
        ),
      ),
    );
  }
}
