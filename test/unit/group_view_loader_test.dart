// 成员视图的增量装配（change `agent-group-chat` 任务 4.2 / design D9）。
//
// 红靶：**全量查询即抛错**的仓库注入后，成员装配仍成功 —— 证明它按 `seq` 区间读。
// 另外记录每次读的区间：第二轮只读高水位之后的行。
import 'package:flutter_test/flutter_test.dart';

import 'package:alias_agent/models/message.dart';
import 'package:alias_agent/services/group_view_loader.dart';
import 'package:alias_agent/services/message_repository.dart';

import '../widget/helpers/fakes.dart';

/// 全量查询即抛错：成员装配若退化成 `queryBySession`，这条用例立刻炸。
class _NoFullQueryRepo implements MessageRepository {
  _NoFullQueryRepo(this.inner);

  final FakeMessageRepository inner;
  final List<String> fullQueryAttempts = [];

  @override
  Future<List<Message>> queryBySession(String sessionId) async {
    fullQueryAttempts.add(sessionId);
    throw StateError('禁止全量读取整条会话（成员视图必须按 seq 区间装配）');
  }

  @override
  Future<List<Map<String, dynamic>>> queryRawAfterSeq(
          String sessionId, int afterSeq) =>
      inner.queryRawAfterSeq(sessionId, afterSeq);

  @override
  Future<List<Map<String, dynamic>>> queryRawInRange(
          String sessionId, int minSeq, int maxSeq) =>
      inner.queryRawInRange(sessionId, minSeq, maxSeq);

  @override
  Future<Message> insert({
    required String sessionId,
    required String role,
    required String content,
    String? toolCallsJson,
    String? thinkingJson,
    int? tokenCount,
    int? outputTokenCount,
    List<String> attachments = const [],
    String? author,
    String visibility = Message.visibilityPublic,
  }) =>
      inner.insert(
        sessionId: sessionId,
        role: role,
        content: content,
        toolCallsJson: toolCallsJson,
        thinkingJson: thinkingJson,
        tokenCount: tokenCount,
        outputTokenCount: outputTokenCount,
        attachments: attachments,
        author: author,
        visibility: visibility,
      );

  @override
  Future<void> updateToolCalls(String id, String toolCallsJson) =>
      inner.updateToolCalls(id, toolCallsJson);
}

Message _msg(int seq, String role, String content, {String? author}) => Message(
      id: 'm$seq',
      seq: seq,
      sessionId: 'group-1',
      role: role,
      content: content,
      author: author,
      createdAt: seq,
    );

void main() {
  test('全量查询即抛错的仓库下装配成功；第二轮只读高水位之后的行', () async {
    final inner = FakeMessageRepository([
      _msg(1, 'user', '用户第一句'),
      _msg(2, 'assistant', '甲的公开回复', author: 'member-a'),
      _msg(3, 'user', '用户第二句'),
    ]);
    final repo = _NoFullQueryRepo(inner);
    final loader = GroupViewLoader(groupId: 'group-1', messageRepo: repo);

    await loader.assemble(
      memberId: 'member-b',
      displayNames: const {'member-a': '甲', 'member-b': '乙'},
      coveredThrough: 0,
    );
    final firstRange = loader.readRanges.single;
    final firstView = loader.residentView('member-b');
    // ignore: avoid_print
    print('[OBS] 第一轮 区间=${firstRange.afterSeq}..${firstRange.maxSeq} '
        '行数=${firstRange.rows} 视图条数=${firstView.length} '
        '全量查询尝试=${repo.fullQueryAttempts}');
    expect(repo.fullQueryAttempts, isEmpty, reason: '装配不得调用全量查询');
    expect(firstRange.afterSeq, 0);
    expect(firstView.length, 3);
    expect(firstView.map((m) => m.content).join('|'),
        contains('甲 说：甲的公开回复'));

    // 第二轮：只读高水位之后的行。
    inner.messages.add(_msg(4, 'assistant', '乙的公开回复', author: 'member-b'));
    inner.messages.add(_msg(5, 'user', '用户第三句'));
    await loader.assemble(
      memberId: 'member-b',
      displayNames: const {'member-a': '甲', 'member-b': '乙'},
      coveredThrough: 0,
    );
    final secondRange = loader.readRanges.last;
    // ignore: avoid_print
    print('[OBS] 第二轮 区间=${secondRange.afterSeq}..${secondRange.maxSeq} '
        '行数=${secondRange.rows} 高水位=${loader.highWaterOf('member-b')}');
    expect(secondRange.afterSeq, 3, reason: '第二轮只读 seq > 3 的行');
    expect(secondRange.rows, 2);
    expect(loader.highWaterOf('member-b'), 5);
    expect(loader.residentView('member-b').length, 5);
    expect(repo.fullQueryAttempts, isEmpty);
  });

  test('被摘要覆盖的区间不常驻；压缩需要时按需读回', () async {
    final inner = FakeMessageRepository([
      _msg(1, 'user', '旧的用户话'),
      _msg(2, 'assistant', '甲的旧公开回复', author: 'member-a'),
      _msg(3, 'user', '新的用户话'),
    ]);
    final loader =
        GroupViewLoader(groupId: 'group-1', messageRepo: _NoFullQueryRepo(inner));

    await loader.assemble(
      memberId: 'member-a',
      displayNames: const {'member-a': '甲'},
      coveredThrough: 2,
    );
    // ignore: avoid_print
    print('[OBS] 覆盖到 2 的驻留 seq=${loader.residentSeqs('member-a')}');
    expect(loader.residentSeqs('member-a'), {3},
        reason: 'seq <= coveredThrough 的项已被摘要替代，不再常驻');

    final full = await loader.fullViewForCompaction(
      memberId: 'member-a',
      displayNames: const {'member-a': '甲'},
      coveredSpans: const [(min: 1, max: 2)],
    );
    // ignore: avoid_print
    print('[OBS] 压缩输入 seq=${full.map((m) => m.seq).toList()}');
    expect(full.map((m) => m.seq).toList(), [1, 2, 3],
        reason: '压缩时需要完整序列：覆盖区间按 seq 区间读回、与驻留视图合并');
  });
}
