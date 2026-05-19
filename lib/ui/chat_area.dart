import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../models/message.dart';
import 'message_bubble.dart';

class ChatArea extends StatefulWidget {
  final List<Message> messages;
  final String? streamingText;
  final bool isStreaming;
  final ValueChanged<String> onSendMessage;

  const ChatArea({
    super.key,
    required this.messages,
    this.streamingText,
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
    final oldLen = old.messages.length + (old.streamingText != null ? 1 : 0);
    final newLen = widget.messages.length + (widget.streamingText != null ? 1 : 0);
    if (newLen > oldLen) {
      WidgetsBinding.instance.addPostFrameCallback((_) => _scrollToBottom());
    }
    // Also auto-scroll while streaming text updates
    if (widget.isStreaming && widget.streamingText != null) {
      _scrollToBottom();
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
    final msgs = widget.messages;

    return Column(
      children: [
        // Message list
        Expanded(
          child: msgs.isEmpty && !widget.isStreaming
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
                  itemCount:
                      msgs.length + (widget.isStreaming ? 1 : 0),
                  itemBuilder: (context, i) {
                    if (i < msgs.length) {
                      return MessageBubble(
                        role: msgs[i].role,
                        content: msgs[i].content,
                      );
                    }
                    // Streaming bubble
                    return MessageBubble(
                      role: 'assistant',
                      content: widget.streamingText ?? '',
                      isStreaming: true,
                    );
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