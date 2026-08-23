import 'message.dart';
import 'tool_call_activity.dart';

sealed class ChatItem {
  const ChatItem();
}

class ChatMessageItem extends ChatItem {
  final Message message;

  /// Whether this assistant message is the FINAL reply of its turn (the turn
  /// concluded with no further tool calls). Distinguished from an intermediate
  /// tool-round text bubble, which is the same type (role=assistant, non-empty
  /// content). Not persisted — an observability/identifier flag the live test
  /// reads via `ChatScreenState.finalAssistantReply`.
  final bool isFinalReply;

  const ChatMessageItem(this.message, {this.isFinalReply = false});
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

  /// Content-block index within the current turn (SSE index restarts at 0 for
  /// each new message). Scoped to the current turn: incremental lookup matches
  /// only streaming cards of the active turn, never history-rebuilt cards.
  /// NOT a persisted field — rebuilt cards derive it from array order (0..N-1).
  final int index;

  const ChatThinkingItem({
    required this.thinking,
    this.signature,
    this.isStreaming = true,
    this.index = 0,
  });
}
