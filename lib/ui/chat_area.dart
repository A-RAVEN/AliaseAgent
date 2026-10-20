import 'package:flutter/material.dart';

import '../models/chat_item.dart';
import '../models/compaction_status.dart';
import 'compaction_status_banner.dart';
import 'message_bubble.dart';
import 'thinking_card.dart';
import 'tool_call_card.dart';

class ChatArea extends StatefulWidget {
  final List<ChatItem> items;
  final bool isStreaming;

  /// 压缩进行中的状态（空闲时是 [CompactionStatus.idle]，那时不显示任何东西）。
  /// 它只表示"压缩正在做"，与 [isStreaming] 是两件事：没触发压缩的发送不会让它亮。
  final CompactionStatus compactionStatus;

  /// **2026-10-18 起 `ChatArea` 只管消息列表与压缩提示**：输入行（输入框 + 发送按钮）
  /// 搬到了 `lib/ui/input_bar.dart` 的公开控件 `InputBar`，由 `lib/main.dart` 在两屏之间
  /// 共用 —— 这样上下文占用环在「对话视图」与「真实上下文」两屏都能贴着发送按钮显示。
  /// 原来的 `onSendMessage` / `toolsReady` 两个参数随之删除（搬完就没人读了）。
  const ChatArea({
    super.key,
    this.items = const [],
    this.isStreaming = false,
    this.compactionStatus = CompactionStatus.idle,
  });

  @override
  State<ChatArea> createState() => _ChatAreaState();
}

class _ChatAreaState extends State<ChatArea> {
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

  @override
  void dispose() {
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
        // 输入行已经搬到 `lib/main.dart`（与「真实上下文」那一屏共用），这里不再放。
      ],
    );
  }
}


