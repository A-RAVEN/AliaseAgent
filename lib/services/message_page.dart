// 消息分页读（change `web-ui-core-shim` 任务 3.1 / design D10；change
// `web-chat-screen` 任务 1.2 增尾锚与反向游标，design D10 additive 扩展）。
//
// **不改 `MessageRepository` 既有接口签名**：用扩展方法提供新入口，既有的
// `queryBySession` 全量方法原样保留（Flutter 界面与 `Agent.restore` 仍在用）。
// 这样 `FakeMessageRepository` / `_RecordingMessageRepo` 这类 `implements
// MessageRepository` 的测试夹具体不用实现新方法，编译不破。
//
// 只服务 `message.query` RPC 读路径：SQL 层直接 `limit`，**不**把整条历史读进内存
// 再切片。游标是页边界那条消息的 `seq`（稳定序，见 `messages.seq`）：
//   - `nextCursor`：前向游标，指向**更新**的一页（既有语义，Flutter/旧客户端不受影响）；
//   - `prevCursor`：反向游标，指向**更早**的一页（`web-chat-screen` 新增，聊天屏上翻
//     加载更早页用）；本页首条即边界，没有更早消息时为 null。
// 页大小由调用方必填，本模块不提供默认值（也不发明上限）。
import 'package:sqflite_common/sqflite.dart';

import '../models/message.dart';
import 'database_service.dart';
import 'message_repository.dart';

/// 一页消息 + 两个方向的页边界游标（null = 该方向没有更多）。
class MessagePage {
  final List<Message> messages;

  /// 前向游标：传给 `afterSeq` 取更新的一页；null = 没有更新的一页。
  final int? nextCursor;

  /// 反向游标：传给 `beforeSeq` 取更早的一页；null = 没有更早的一页。
  final int? prevCursor;

  const MessagePage({
    required this.messages,
    required this.nextCursor,
    this.prevCursor,
  });

  bool get hasMore => nextCursor != null;

  bool get hasEarlier => prevCursor != null;
}

extension PagedMessageQuery on MessageRepository {
  /// 按 `seq` 升序取一页：`seq > afterSeq`（首屏不传 afterSeq 时即"从最旧开始"）。
  ///
  /// 前向兼容：`nextCursor` 的既有语义（满页 = 末条 seq，不满页 = null）保持不变，
  /// 只额外补上 `prevCursor`。
  Future<MessagePage> queryPageBySession(
    String sessionId, {
    required int pageSize,
    int? afterSeq,
  }) async {
    _requirePageSize(pageSize);
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
      return MessagePage(
        messages: messages,
        nextCursor: null,
        prevCursor: await _prevCursor(db, sessionId, messages),
      );
    }
    final lastSeq = messages.last.seq;
    if (lastSeq == null) {
      // seq 在插入时由 rowid 回填（见 MessageRepository.insert）；满页却拿不到
      // seq 说明数据形状被破坏，不能假装"没有下一页"而丢消息。
      throw StateError('会话 "$sessionId" 的分页读拿到满页消息但最后一条没有 seq：'
          '拒绝静默停止分页。');
    }
    return MessagePage(
      messages: messages,
      nextCursor: lastSeq,
      prevCursor: await _prevCursor(db, sessionId, messages),
    );
  }

  /// 尾锚：不传游标时取**最新一页**（`seq` 降序取 pageSize 条，再反转为升序）。
  ///
  /// 聊天屏"打开即在最新回复"用这个入口；扩展前不传游标拿到的是**最旧页**。
  Future<MessagePage> queryLatestPageBySession(
    String sessionId, {
    required int pageSize,
  }) async {
    _requirePageSize(pageSize);
    final db = await DatabaseService.database;
    final rows = await db.query(
      'messages',
      where: 'session_id = ?',
      whereArgs: [sessionId],
      orderBy: 'seq DESC',
      limit: pageSize,
    );
    final messages = rows.map(Message.fromRow).toList().reversed.toList();
    return MessagePage(
      messages: messages,
      nextCursor: await _nextCursor(db, sessionId, messages),
      prevCursor: await _prevCursor(db, sessionId, messages),
    );
  }

  /// 反向游标：`seq < beforeSeq` 降序取 pageSize 条，再反转为升序（不重叠）。
  ///
  /// [beforeSeq] 用上一页的 `prevCursor`；它本身就是"更早一页"的上界。
  Future<MessagePage> queryPageBeforeSeq(
    String sessionId, {
    required int pageSize,
    required int beforeSeq,
  }) async {
    _requirePageSize(pageSize);
    final db = await DatabaseService.database;
    final rows = await db.query(
      'messages',
      where: 'session_id = ? AND seq < ?',
      whereArgs: [sessionId, beforeSeq],
      orderBy: 'seq DESC',
      limit: pageSize,
    );
    final messages = rows.map(Message.fromRow).toList().reversed.toList();
    return MessagePage(
      messages: messages,
      nextCursor: await _nextCursor(db, sessionId, messages),
      prevCursor: await _prevCursor(db, sessionId, messages),
    );
  }
}

/// 参数校验：页大小由请求方必填且为正整数，本模块不提供默认值。
void _requirePageSize(int pageSize) {
  if (pageSize <= 0) {
    throw ArgumentError.value(pageSize, 'pageSize', '必须是正整数');
  }
}

/// 本页首条 seq —— 只有确实存在更早消息时才是游标（否则 null，不指回空页）。
Future<int?> _prevCursor(
  DatabaseExecutor db,
  String sessionId,
  List<Message> page,
) async {
  if (page.isEmpty) return null;
  final firstSeq = page.first.seq;
  if (firstSeq == null) {
    throw StateError('会话 "$sessionId" 的分页读拿到没有 seq 的消息：'
        '拒绝把 null 当作"没有更早页"而丢消息。');
  }
  final earlier = await db.query(
    'messages',
    columns: ['seq'],
    where: 'session_id = ? AND seq < ?',
    whereArgs: [sessionId, firstSeq],
    orderBy: 'seq DESC',
    limit: 1,
  );
  return earlier.isEmpty ? null : firstSeq;
}

/// 本页末条 seq —— 只在确实存在更新消息时作为前向游标（否则 null）。
Future<int?> _nextCursor(
  DatabaseExecutor db,
  String sessionId,
  List<Message> page,
) async {
  if (page.isEmpty) return null;
  final lastSeq = page.last.seq;
  if (lastSeq == null) {
    throw StateError('会话 "$sessionId" 的分页读拿到没有 seq 的消息：'
        '拒绝把 null 当作"没有更新页"而丢消息。');
  }
  final newer = await db.query(
    'messages',
    columns: ['seq'],
    where: 'session_id = ? AND seq > ?',
    whereArgs: [sessionId, lastSeq],
    orderBy: 'seq ASC',
    limit: 1,
  );
  return newer.isEmpty ? null : lastSeq;
}
