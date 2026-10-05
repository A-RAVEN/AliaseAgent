import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../models/chat_item.dart';
import '../models/compaction_status.dart';
import 'compaction_status_banner.dart';
import 'message_bubble.dart';
import 'thinking_card.dart';
import 'tool_call_card.dart';

class ChatArea extends StatefulWidget {
  final List<ChatItem> items;
  final bool isStreaming;
  final ValueChanged<String> onSendMessage;

  /// 压缩进行中的状态（空闲时是 [CompactionStatus.idle]，那时不显示任何东西）。
  /// 它只表示"压缩正在做"，与 [isStreaming] 是两件事：没触发压缩的发送不会让它亮。
  final CompactionStatus compactionStatus;

  /// 工具清单是否已经装好（含按可用性动态加入的 `web_search` / `web_fetch` / 浏览器
  /// 四件套 / `run_command`）。**缺省 true**，保证既有用例与既有调用点的行为不变。
  ///
  /// 为什么需要它：界面启动后有一小段"动态工具仍在探测"的窗口，那期间发出的请求里
  /// 工具清单是**残缺的**（本地那 8 个在 await 之前就装好了，缺的是动态那批），模型
  /// 因此没有搜索工具可用 —— 真机实测过一整轮空转。未就绪时这里禁用发送并给出文案。
  final bool toolsReady;

  const ChatArea({
    super.key,
    this.items = const [],
    this.isStreaming = false,
    this.compactionStatus = CompactionStatus.idle,
    this.toolsReady = true,
    required this.onSendMessage,
  });

  @override
  State<ChatArea> createState() => _ChatAreaState();
}

class _ChatAreaState extends State<ChatArea> {
  final _inputCtrl = TextEditingController();
  final _scrollCtrl = ScrollController();

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _scrollToBottom());
  }

  @override
  void didUpdateWidget(ChatArea old) {
    super.didUpdateWidget(old);
    if (widget.items.length > old.items.length) {
      WidgetsBinding.instance.addPostFrameCallback((_) => _scrollToBottom());
    }
    // Auto-scroll while streaming (instant jump to avoid animation jank)
    if (widget.isStreaming) {
      if (_scrollCtrl.hasClients) {
        _scrollCtrl.jumpTo(_scrollCtrl.position.maxScrollExtent);
      }
    }
  }

  void _scrollToBottom() {
    if (_scrollCtrl.hasClients) {
      _scrollCtrl.animateTo(
        _scrollCtrl.position.maxScrollExtent,
        duration: const Duration(milliseconds: 150),
        curve: Curves.easeOut,
      );
    }
  }

  void _submit() {
    // 工具清单没装好就不发：那一轮请求会带着残缺的工具清单出去，模型白白空转一轮。
    if (!widget.toolsReady) return;
    final text = _inputCtrl.text;
    if (text.trim().isEmpty) return;
    widget.onSendMessage(text);
    _inputCtrl.clear();
  }

  @override
  void dispose() {
    _inputCtrl.dispose();
    _scrollCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final items = widget.items;
    final hasContent = items.isNotEmpty || widget.isStreaming;

    return Column(
      children: [
        // Message list
        Expanded(
          child: !hasContent
              ? Center(
                  child: Text(
                    'No messages yet.\nType something to get started.',
                    textAlign: TextAlign.center,
                    style: theme.textTheme.bodyMedium?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                )
              : ListView.builder(
                  controller: _scrollCtrl,
                  padding: const EdgeInsets.symmetric(vertical: 8),
                  itemCount: items.length,
                  itemBuilder: (context, i) {
                    return switch (items[i]) {
                      ChatMessageItem(:final message) => message.content.isEmpty
                          // A content-empty message (e.g. a tool-call assistant whose
                          // ToolCallCard represents the response, D7) — still tracked
                          // in the message list (so the tool round reaches the model /
                          // summarizer) but never renders an empty bubble.
                          ? const SizedBox.shrink()
                          : MessageBubble(
                              role: message.role,
                              content: message.content,
                            ),
                      ChatToolCallItem(:final activity) => ToolCallCard(
                          activity: activity,
                        ),
                      ChatThinkingItem item => ThinkingCard(
                          item: item,
                        ),
                      ChatStreamingItem(:final text) => MessageBubble(
                          role: 'assistant',
                          content: text,
                          isStreaming: true,
                        ),
                    };
                  },
                ),
        ),
        const Divider(height: 1),
        // 压缩期间在输入框上方显示提示：用户等的地方就是这里（今天从按下发送到
        // 模型吐出第一个字，这一屏此前毫无变化）。
        CompactionStatusBanner(status: widget.compactionStatus),
        // Input area
        _InputBar(
          controller: _inputCtrl,
          onSubmit: _submit,
          toolsReady: widget.toolsReady,
        ),
      ],
    );
  }
}

class _InputBar extends StatefulWidget {
  final TextEditingController controller;
  final VoidCallback onSubmit;

  /// 工具清单是否已就绪（见 [ChatArea.toolsReady]）。未就绪时发送按钮禁用。
  final bool toolsReady;

  const _InputBar({
    required this.controller,
    required this.onSubmit,
    this.toolsReady = true,
  });

  @override
  State<_InputBar> createState() => _InputBarState();
}

class _InputBarState extends State<_InputBar> {
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
      widget.onSubmit();
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
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
          IconButton.filled(
            // 未就绪时禁用并给出可见原因（不是静默排队 —— 排队在用户看来还是"发出去了"）。
            onPressed: widget.toolsReady ? widget.onSubmit : null,
            icon: const Icon(Icons.send, size: 20),
            tooltip: widget.toolsReady ? 'Send' : '正在准备工具…',
          ),
        ],
      ),
    );
  }
}
