// 消息分页读（change `web-ui-core-shim` 任务 3.1 / design D10）。
//
// **不改 `MessageRepository` 既有接口签名**：用扩展方法提供新入口，既有的
// `queryBySession` 全量方法原样保留（Flutter 界面与 `Agent.restore` 仍在用）。
// 这样 `FakeMessageRepository` / `_RecordingMessageRepo` 这类 `implements
// MessageRepository` 的测试夹具体不用实现新方法，编译不破。
//
// 只服务 `message.query` RPC 读路径：SQL 层直接 `limit`，**不**把整条历史读进内存
// 再切片。游标是上一页最后一条的 `seq`（稳定序，见 `messages.seq`）；没有更多页时
// `nextCursor` 为 null。页大小由调用方必填，本模块不提供默认值。
import '../models/message.dart';
import 'database_service.dart';
import 'message_repository.dart';

/// 一页消息 + 下一页游标（null = 没有更多）。
class MessagePage {
  final List<Message> messages;
  final int? nextCursor;

  const MessagePage({required this.messages, required this.nextCursor});

  bool get hasMore => nextCursor != null;
}

extension PagedMessageQuery on MessageRepository {
  /// 按 `seq` 升序取一页：`seq > afterSeq`（首屏不传 afterSeq）。
  ///
  /// [pageSize] 必须由调用方给定且为正整数；这里只做参数校验，不发明默认页大小。
  /// SQL 层用 `limit: pageSize`，读路径不载入整条历史。
  Future<MessagePage> queryPageBySession(
    String sessionId, {
    required int pageSize,
    int? afterSeq,
  }) async {
    if (pageSize <= 0) {
      throw ArgumentError.value(pageSize, 'pageSize', '必须是正整数');
    }
    final db = await DatabaseService.database;
    final rows = await db.query(
      'messages',
      where: afterSeq == null ? 'session_id = ?' : 'session_id = ? AND seq > ?',
      whereArgs: afterSeq == null ? [sessionId] : [sessionId, afterSeq],
      orderBy: 'seq ASC',
      limit: pageSize,
    );
    final messages = rows.map(Message.fromRow).toList();
    if (messages.length < pageSize) {
      return MessagePage(messages: messages, nextCursor: null);
    }
    final lastSeq = messages.last.seq;
    if (lastSeq == null) {
      // seq 在插入时由 rowid 回填（见 MessageRepository.insert）；满页却拿不到
      // seq 说明数据形状被破坏，不能假装"没有下一页"而丢消息。
      throw StateError('会话 "$sessionId" 的分页读拿到满页消息但最后一条没有 seq：'
          '拒绝静默停止分页。');
    }
    return MessagePage(messages: messages, nextCursor: lastSeq);
  }
}
