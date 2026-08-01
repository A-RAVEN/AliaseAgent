import 'message.dart';
import 'tool_call_activity.dart';

sealed class ChatItem {
  const ChatItem();
}

class ChatMessageItem extends ChatItem {
  final Message message;
  const ChatMessageItem(this.message);
}

class ChatToolCallItem extends ChatItem {
  final ToolCallActivity activity;
  const ChatToolCallItem(this.activity);
}

class ChatStreamingItem extends ChatItem {
  final String text;
  const ChatStreamingItem(this.text);
}

class ChatThinkingItem extends ChatItem {
  final String thinking;
  final String? signature;
  final bool isStreaming;
  const ChatThinkingItem({
    required this.thinking,
    this.signature,
    this.isStreaming = true,
  });
}
