import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:alias_agent/models/tool_call_activity.dart';
import 'package:alias_agent/ui/tool_call_card.dart';
import 'helpers/test_utils.dart';

void main() {
  group('ToolCallCard', () {
    testWidgets('renders tool name and input', (tester) async {
      final activity = testToolActivity(
        toolName: 'list_dir',
        input: const {'path': '/home'},
        status: ToolCallStatus.done,
      );

      await tester.pumpWidget(MaterialApp(
        home: Scaffold(body: ToolCallCard(activity: activity)),
      ));

      expect(find.textContaining('list_dir'), findsOneWidget);
      expect(find.textContaining('path=/home'), findsOneWidget);
    });

    testWidgets('shows executing state with spinner', (tester) async {
      final activity = testToolActivity(
        status: ToolCallStatus.executing,
      );

      await tester.pumpWidget(MaterialApp(
        home: Scaffold(body: ToolCallCard(activity: activity)),
      ));

      expect(find.text('Executing...'), findsOneWidget);
      expect(find.byType(CircularProgressIndicator), findsOneWidget);
    });

    testWidgets('shows done state with check icon', (tester) async {
      final activity = testToolActivity(
        status: ToolCallStatus.done,
      );

      await tester.pumpWidget(MaterialApp(
        home: Scaffold(body: ToolCallCard(activity: activity)),
      ));

      expect(find.text('Done'), findsOneWidget);
      expect(find.byIcon(Icons.check_circle_outline), findsOneWidget);
    });

    testWidgets('shows error state with error icon', (tester) async {
      final activity = testToolActivity(
        status: ToolCallStatus.error,
      );

      await tester.pumpWidget(MaterialApp(
        home: Scaffold(body: ToolCallCard(activity: activity)),
      ));

      expect(find.text('Error'), findsOneWidget);
      expect(find.byIcon(Icons.error_outline), findsOneWidget);
    });

    testWidgets('shows result preview when done', (tester) async {
      final activity = testToolActivity(
        status: ToolCallStatus.done,
        resultPreview: 'file content here',
      );

      await tester.pumpWidget(MaterialApp(
        home: Scaffold(body: ToolCallCard(activity: activity)),
      ));

      expect(find.text('file content here'), findsOneWidget);
      expect(find.text('Expand result'), findsOneWidget);
    });
  });

  group('edit_file 的差异区块', () {
    ToolCallActivity activityWithHunks(
      List<EditHunk>? hunks, {
      String? hunksOmitted,
      String result = 'Edited /a.txt (1 replacement)',
    }) {
      return ToolCallActivity(
        id: 't1',
        toolName: 'edit_file',
        input: const {'path': '/a.txt'},
        status: ToolCallStatus.done,
        result: result,
        resultPreview: result,
        hunks: hunks,
        hunksOmitted: hunksOmitted,
      );
    }

    Future<void> pumpCard(WidgetTester tester, ToolCallActivity a) async {
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(body: ToolCallCard(activity: a)),
      ));
      await tester.pump();
    }

    testWidgets('展开后每处 hunk 有行号且改动带 - / + 前缀', (tester) async {
      await pumpCard(
          tester,
          activityWithHunks(const [
            EditHunk(startLine: 3, oldText: 'old three', newText: 'new three'),
            EditHunk(startLine: 40, oldText: 'old forty', newText: 'new forty'),
            EditHunk(startLine: 88, oldText: 'old eighty', newText: 'new eighty'),
          ]));
      await tester.tap(find.text('Expand result'));
      await tester.pump();

      for (final line in [3, 40, 88]) {
        expect(find.text('第 $line 行'), findsOneWidget);
      }
      expect(find.text('- old three'), findsOneWidget);
      expect(find.text('+ new three'), findsOneWidget);

      // 三个 hunk 按文件顺序依次出现
      final y3 = tester.getTopLeft(find.text('第 3 行')).dy;
      final y40 = tester.getTopLeft(find.text('第 40 行')).dy;
      final y88 = tester.getTopLeft(find.text('第 88 行')).dy;
      expect(y3, lessThan(y40));
      expect(y40, lessThan(y88));
    });

    testWidgets('折叠态不渲染差异，仍显示一句话结果', (tester) async {
      await pumpCard(
          tester,
          activityWithHunks(const [
            EditHunk(startLine: 3, oldText: 'a', newText: 'b'),
          ]));
      expect(find.textContaining('第 3 行'), findsNothing);
      expect(find.text('Edited /a.txt (1 replacement)'), findsOneWidget);
    });

    testWidgets('4 行内容不出现折叠标记', (tester) async {
      await pumpCard(
          tester,
          activityWithHunks(const [
            EditHunk(startLine: 1, oldText: 'a\nb', newText: 'c\nd'),
          ]));
      await tester.tap(find.text('Expand result'));
      await tester.pump();
      expect(find.textContaining('未显示'), findsNothing);
    });

    testWidgets('30 行内容折叠成"还有 18 行未显示"，点开后全部出现', (tester) async {
      final oldLines = List.generate(15, (i) => 'old $i').join('\n');
      final newLines = List.generate(15, (i) => 'new $i').join('\n');
      await pumpCard(
          tester,
          activityWithHunks([
            EditHunk(startLine: 1, oldText: oldLines, newText: newLines),
          ]));
      await tester.tap(find.text('Expand result'));
      await tester.pump();

      expect(find.text('还有 18 行未显示，点击展开'), findsOneWidget);
      await tester.tap(find.text('还有 18 行未显示，点击展开'));
      await tester.pump();

      expect(find.textContaining('未显示'), findsNothing);
      expect(find.text('+ new 14'), findsOneWidget);
      expect(find.text('- old 14'), findsOneWidget);
    });

    testWidgets('标题只显示路径并带 +N/−M', (tester) async {
      await pumpCard(
          tester,
          activityWithHunks(const [
            EditHunk(startLine: 1, oldText: 'a', newText: 'x\ny\nz'),
          ], result: 'Edited /a.txt (1 replacement)'));
      expect(find.textContaining('edit_file(/a.txt)'), findsOneWidget);
      expect(find.textContaining('+3/−1'), findsOneWidget);
      expect(find.textContaining('old_text='), findsNothing);
    });

    testWidgets('hunks_omitted 时显示省略原因且不显示计数', (tester) async {
      await pumpCard(
          tester,
          activityWithHunks(const [], hunksOmitted: 'too large',
              result: 'Edited /a.txt (3 replacements)'));
      expect(find.text('diff 未显示：改动过大（3 处改动）'), findsOneWidget);
      expect(find.textContaining('+'), findsNothing);
    });

    testWidgets('没有 hunks 的老记录回退成字符串结果', (tester) async {
      await pumpCard(
          tester,
          activityWithHunks(null,
              result: 'Edited /a.txt (2 replacements)'));
      await tester.tap(find.text('Expand result'));
      await tester.pump();
      expect(find.textContaining('第 '), findsNothing);
      expect(find.text('Edited /a.txt (2 replacements)'), findsOneWidget);
      expect(find.textContaining('+'), findsNothing);
    });

    testWidgets('其它工具的标题保持原样', (tester) async {
      await pumpCard(
          tester,
          testToolActivity(
              toolName: 'list_dir',
              input: const {'path': '/home'},
              status: ToolCallStatus.done));
      expect(find.textContaining('list_dir(path=/home)'), findsOneWidget);
    });
  });
}
