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

  group('spawn_subagent 卡片（add-spawn-subagent-tool 6.1）', () {
    Future<void> pumpCard(WidgetTester tester, ToolCallActivity a) async {
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(body: ToolCallCard(activity: a)),
      ));
      await tester.pump();
    }

    testWidgets('等待中显示任务、模板与 Executing 状态', (tester) async {
      await pumpCard(
          tester,
          ToolCallActivity(
            id: 't1',
            toolName: 'spawn_subagent',
            input: const {
              'task': '调查子任务-卡片-独特',
              'agent_type': 'worker',
            },
            status: ToolCallStatus.executing,
          ));
      // ignore: avoid_print
      print('  [OBS] 等待态：任务=${find.textContaining('调查子任务-卡片-独特').evaluate().length} '
          '模板=${find.textContaining('worker').evaluate().length} '
          '执行中=${find.text('Executing...').evaluate().length}');
      expect(find.textContaining('调查子任务-卡片-独特'), findsOneWidget,
          reason: '等待期间也要能读到子任务');
      expect(find.textContaining('子 Agent 模板：worker'), findsOneWidget);
      expect(find.text('Executing...'), findsOneWidget);
      expect(find.byType(CircularProgressIndicator), findsOneWidget);
      expect(find.text('Expand result'), findsNothing,
          reason: '还没有结论时没有结果区');
    });

    testWidgets('成功后展开显示完整结论，模板用实际元数据', (tester) async {
      final conclusion = '结论头|${'A' * 600}|结论尾-独特';
      await pumpCard(
          tester,
          ToolCallActivity(
            id: 't2',
            toolName: 'spawn_subagent',
            input: const {'task': '子任务', 'agent_type': 'worker'},
            status: ToolCallStatus.done,
            result: conclusion,
            resultPreview: '${conclusion.substring(0, 300)}...',
            childSessionId: 'child-1',
            childAgentType: 'worker',
            childModel: 'worker-model',
            childMetering: const {'requests': 2},
          ));
      // 收起态只显示预览：结尾不在视野里。
      expect(find.textContaining('结论尾-独特'), findsNothing);
      await tester.tap(find.text('Expand result'));
      await tester.pump();
      // ignore: avoid_print
      print('  [OBS] 成功后展开：完整结论出现='
          '${find.textContaining('结论尾-独特').evaluate().length} '
          '模板=${find.textContaining('子 Agent 模板：worker').evaluate().length}');
      expect(find.textContaining('结论尾-独特'), findsOneWidget,
          reason: '展开后必须能看到完整结论（卡片不是只给预览）');
      expect(find.textContaining('子 Agent 模板：worker'), findsOneWidget);
    });

    testWidgets('失败时展开显示完整错误，状态是 Error', (tester) async {
      await pumpCard(
          tester,
          ToolCallActivity(
            id: 't3',
            toolName: 'spawn_subagent',
            input: const {'task': '子任务'},
            status: ToolCallStatus.error,
            result: 'subagent_failed: 子模型炸了-卡片-独特',
            resultPreview: 'subagent_failed: 子模型炸了-卡片-独特',
          ));
      await tester.tap(find.text('Expand result'));
      await tester.pump();
      // ignore: avoid_print
      print('  [OBS] 失败态：错误出现='
          '${find.textContaining('子模型炸了-卡片-独特').evaluate().length} '
          'Error 状态=${find.text('Error').evaluate().length} '
          '未指定模板时标签=${find.textContaining('继承父模板').evaluate().length}');
      expect(find.textContaining('子模型炸了-卡片-独特'), findsWidgets);
      expect(find.text('Error'), findsOneWidget);
      expect(find.textContaining('子 Agent 模板：继承父模板'), findsOneWidget,
          reason: '省略 agent_type 时卡片要说明继承父模板');
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
