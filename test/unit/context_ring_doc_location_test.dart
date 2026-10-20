import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// 覆盖 10.7 的判据。
///
/// 为什么单开一条：`test/unit/user_docs_test.dart` 只核带 `界面文案：` 标记的反引号句子，
/// 而"环在哪"那句是普通散文 —— 那句话一个字不改，那边照样全绿。所以这里直接对文档正文
/// 断言"旧位置的说法已经不存在、新位置的说法存在"，这才会因为没改而红。
void main() {
  test('用户文档里环的位置写的是输入行、不再是顶部工具栏', () {
    final doc = File('Docs/user-guide/context-compaction.md').readAsStringSync();

    final oldMentions = '顶部工具栏'.allMatches(doc).length;
    final newMentions = '发送按钮'.allMatches(doc).length;
    // ignore: avoid_print
    print('  [OBS] 「顶部工具栏」出现 $oldMentions 次；「发送按钮」出现 $newMentions 次');

    expect(oldMentions, 0,
        reason: '环 2026-10-18 已从顶部工具栏搬到输入行，文档不该再说它在工具栏');
    expect(newMentions, greaterThanOrEqualTo(1),
        reason: '文档必须说清环在发送按钮旁边');
  });
}
