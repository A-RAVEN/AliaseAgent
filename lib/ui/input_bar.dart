import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

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

  const InputBar({
    super.key,
    required this.controller,
    required this.onSubmit,
    this.toolsReady = true,
    this.accessory,
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
  void _submit() {
    if (widget.controller.text.trim().isEmpty) return;
    widget.onSubmit();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      color: theme.colorScheme.surface,
      padding: const EdgeInsets.fromLTRB(12, 8, 8, 8),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          Expanded(
            child: Focus(
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
          const SizedBox(width: 6),
          // 环与发送按钮在这一小组里**居中对齐**：输入行整体是底对齐（`end`），而发送按钮
          // 是个比图标高的盒子 —— 直接并排放的话环会看起来偏低 14 像素（实测过）。
          Row(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
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
    );
  }
}
