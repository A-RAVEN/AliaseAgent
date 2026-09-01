import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../models/chat_item.dart';
import 'message_bubble.dart';
import 'thinking_card.dart';
import 'tool_call_card.dart';

class ChatArea extends StatefulWidget {
  final List<ChatItem> items;
  final bool isStreaming;
  final ValueChanged<String> onSendMessage;

  const ChatArea({
    super.key,
    this.items = const [],
    this.isStreaming = false,
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
        // Input area
        _InputBar(
          controller: _inputCtrl,
          onSubmit: _submit,
        ),
      ],
    );
  }
}

class _InputBar extends StatefulWidget {
  final TextEditingController controller;
  final VoidCallback onSubmit;

  const _InputBar({
    required this.controller,
    required this.onSubmit,
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
            onPressed: widget.onSubmit,
            icon: const Icon(Icons.send, size: 20),
            tooltip: 'Send',
          ),
        ],
      ),
    );
  }
}
