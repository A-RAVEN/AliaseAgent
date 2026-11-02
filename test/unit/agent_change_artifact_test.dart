import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// 本 change 的工件自检（任务 4.3）。
///
/// 逐条核对：proposal 的 Capabilities 与 8 份 delta 一一对应；MODIFIED 标题与主
/// 规范逐字一致；tasks.md 的每个任务编号都存在，且任务点名的 `test/...` 文件真实
/// 存在；每项实现任务都能落到一条可执行测试（或明确的全量验证命令）上。
/// 任何一份 delta 缺失、标题不一致、点名的测试文件不存在，这条用例红。
void main() {
  const changeDir =
      'openspec/changes/archive/2026-11-02-add-agent-object-and-templates';
  final proposal = File('$changeDir/proposal.md');
  final design = File('$changeDir/design.md');
  final tasks = File('$changeDir/tasks.md');

  List<String> capabilityDirs() {
    final dir = Directory('$changeDir/specs');
    if (!dir.existsSync()) return const [];
    return [
      for (final d in dir.listSync().whereType<Directory>())
        d.uri.pathSegments.where((s) => s.isNotEmpty).last,
    ]..sort();
  }

  /// proposal 里 New / Modified Capabilities 两节的反引号名字。
  Set<String> proposalCapabilities() {
    final text = proposal.readAsStringSync();
    final names = <String>{};
    var section = '';
    for (final line in text.split('\n')) {
      if (line.startsWith('### New Capabilities')) {
        section = 'new';
        continue;
      }
      if (line.startsWith('### Modified Capabilities')) {
        section = 'modified';
        continue;
      }
      if (line.startsWith('## Impact')) {
        section = '';
        continue;
      }
      if (section.isEmpty) continue;
      final m = RegExp(r'^- `([a-z0-9-]+)`').firstMatch(line);
      if (m != null) names.add(m.group(1)!);
    }
    return names;
  }

  test('proposal 的 Capabilities 与 specs 下的 delta 一一对应', () {
    final dirs = capabilityDirs();
    final declared = proposalCapabilities();
    final files = [
      for (final d in dirs)
        if (File('$changeDir/specs/$d/spec.md').existsSync()) d,
    ]..sort();
    // ignore: avoid_print
    print('  [OBS] proposal 声明=${declared.toList()..sort()}');
    // ignore: avoid_print
    print('  [OBS] 磁盘上的 delta=$files');
    expect(files.length, 8, reason: '本 change 应有 8 份 delta spec');
    expect(files.toSet(), declared,
        reason: 'proposal 的 Capabilities 与 delta 目录必须一一对应');
    for (final name in declared) {
      final f = File('$changeDir/specs/$name/spec.md');
      expect(f.existsSync(), isTrue, reason: '缺少 delta：$name');
      final text = f.readAsStringSync();
      expect(
          text.startsWith('## ADDED Requirements') ||
              text.startsWith('## MODIFIED Requirements'),
          isTrue,
          reason: '$name/spec.md 必须以 ADDED 或 MODIFIED Requirements 开头');
    }
  });

  test('MODIFIED 标题与主规范逐字一致', () {
    final modified = <String>[];
    for (final name in capabilityDirs()) {
      final delta = File('$changeDir/specs/$name/spec.md').readAsStringSync();
      if (!delta.startsWith('## MODIFIED Requirements')) continue;
      modified.add(name);
      final master = File('openspec/specs/$name/spec.md');
      expect(master.existsSync(), isTrue,
          reason: 'MODIFIED 的 $name 没有主规范可对照');
      final masterText = master.readAsStringSync();
      final titles = RegExp(r'^### Requirement: (.+)$', multiLine: true)
          .allMatches(delta)
          .map((m) => m.group(1)!.trim())
          .toList();
      // ignore: avoid_print
      print('  [OBS] $name 的 MODIFIED 标题=$titles');
      expect(titles, isNotEmpty, reason: '$name 的 delta 没有任何 Requirement');
      for (final title in titles) {
        final exists =
            masterText.split('\n').any((l) => l.trim() == '### Requirement: $title');
        expect(exists, isTrue,
            reason: '$name 的 MODIFIED 标题在主规范里逐字找不到：「$title」');
      }
    }
    // ignore: avoid_print
    print('  [OBS] MODIFIED 的 delta=${modified..sort()}');
    expect(modified.toSet(), {
      'agent-config',
      'session-persistence',
      'command-tool',
      'file-edit-tools',
      'file-search',
      'context-occupancy-ring',
    });
  });

  test('tasks.md 的任务编号完整，且每个任务都能落到可执行测试上', () {
    final text = tasks.readAsStringSync();
    final lines = text.split('\n');
    final entries = <({String id, List<String> body})>[];
    for (var i = 0; i < lines.length; i++) {
      final m = RegExp(r'^- \[[ x]\] (\d+\.\d+) ').firstMatch(lines[i]);
      if (m == null) continue;
      final body = <String>[lines[i]];
      for (var j = i + 1; j < lines.length; j++) {
        if (RegExp(r'^- \[[ x]\] \d+\.\d+ ').hasMatch(lines[j])) break;
        if (lines[j].startsWith('## ')) break;
        body.add(lines[j]);
      }
      entries.add((id: m.group(1)!, body: body));
    }
    // ignore: avoid_print
    print('  [OBS] tasks.md 里的任务编号=${entries.map((e) => e.id).toList()}');

    final expectedIds = <String>[
      for (var i = 1; i <= 4; i++)
        for (var j = 1; j <= 6; j++)
          if (!(i == 1 && j > 3) && !(i == 2 && j > 5) && !(i == 4 && j > 5))
            '$i.$j',
    ];
    expect(entries.map((e) => e.id).toList(), expectedIds,
        reason: '任务编号必须连续且完整（1.1-1.3、2.1-2.5、3.1-3.6、4.1-4.5）');
    expect(entries.length, 19);

    final testPathPattern = RegExp(r'`(test/[A-Za-z0-9_./-]+\.dart)`');
    final missing = <String>[];
    final withoutTest = <String>[];
    for (final entry in entries) {
      final joined = entry.body.join('\n');
      final paths = testPathPattern
          .allMatches(joined)
          .map((m) => m.group(1)!)
          .toSet()
          .toList();
      // ignore: avoid_print
      print('  [OBS] 任务 ${entry.id} 点名的测试文件=$paths');
      for (final p in paths) {
        if (!File(p).existsSync()) missing.add('${entry.id} → $p');
      }
      final hasVerificationCommand = joined.contains('flutter test') ||
          joined.contains('flutter analyze') ||
          joined.contains('openspec validate');
      if (paths.isEmpty && !hasVerificationCommand) {
        withoutTest.add(entry.id);
      }
    }
    expect(missing, isEmpty,
        reason: '任务点名的测试文件不存在：$missing');
    expect(withoutTest, isEmpty,
        reason: '这些任务既没有点名测试文件，也没有全量验证命令：$withoutTest');
  });

  test('design、spec 与实现文件的关键名字对得上', () {
    final designText = design.readAsStringSync();
    final runtimeSpec =
        File('$changeDir/specs/agent-runtime/spec.md').readAsStringSync();
    final templateSpec = File('$changeDir/specs/agent-template-management/spec.md')
        .readAsStringSync();
    for (final name in const [
      'ResolvedAgentConfig',
      'AgentFactory',
      'AgentRegistry',
      'ToolCatalog',
    ]) {
      // ignore: avoid_print
      print('  [OBS] 关键名字 $name：design=${designText.contains(name)} '
          'runtime=${runtimeSpec.contains(name)}');
      expect(designText, contains(name), reason: 'design 没有提到 $name');
    }
    expect(runtimeSpec, contains('ToolCatalog'));
    expect(templateSpec, contains('ToolCatalog'));
    expect(designText, contains('AgentTemplateController'));

    for (final entry in const {
      'ResolvedAgentConfig': 'lib/models/resolved_agent_config.dart',
      'AgentConfigResolver': 'lib/services/agent_config_resolver.dart',
      'AgentFactory': 'lib/services/agent_factory.dart',
      'AgentRegistry': 'lib/services/agent_registry.dart',
      'AgentTemplateController': 'lib/services/agent_template_controller.dart',
      'ToolCatalog': 'lib/services/tool_catalog.dart',
    }.entries) {
      final file = File(entry.value);
      expect(file.existsSync(), isTrue,
          reason: 'design 点名的 ${entry.key} 缺文件 ${entry.value}');
      expect(file.readAsStringSync(), contains(entry.key),
          reason: '${entry.value} 里找不到 ${entry.key}');
    }
  });

  test('Session 切换规范、返工测试与实现接线齐全（4.5 返工要求）', () {
    final runtimeSpec =
        File('$changeDir/specs/agent-runtime/spec.md').readAsStringSync();
    final persistenceSpec =
        File('$changeDir/specs/session-persistence/spec.md').readAsStringSync();
    final tasksText = tasks.readAsStringSync();
    final mainDart = File('lib/main.dart');
    final controllerFile = File('lib/services/agent_session_controller.dart');
    final switcherFile = File('lib/ui/session_agent_switcher.dart');
    final agentFile = File('lib/services/agent.dart');
    final factoryFile = File('lib/services/agent_factory.dart');
    final repoFile = File('lib/services/session_repository.dart');
    for (final f in [
      mainDart,
      controllerFile,
      switcherFile,
      agentFile,
      factoryFile,
      repoFile
    ]) {
      expect(f.existsSync(), isTrue, reason: '缺少实现文件：${f.path}');
    }
    final mainText = mainDart.readAsStringSync();
    final controllerText = controllerFile.readAsStringSync();
    final agentText = agentFile.readAsStringSync();
    final factoryText = factoryFile.readAsStringSync();
    final repoText = repoFile.readAsStringSync();

    // ① 规范必须含"Session 切换必须替换运行实例"标题与全部关键场景 —— 删任一条
    //    这条用例就红（这是 0011 那条复核要求的落点）。
    const switchTitle = '### Requirement: Session 切换模板必须替换运行实例';
    expect(runtimeSpec, contains(switchTitle),
        reason: 'agent-runtime 缺少切换要求标题：「$switchTitle」');
    for (final scenario in const [
      '#### Scenario: 切换后真实请求使用新模板',
      '#### Scenario: 在途轮次切换先排空',
      '#### Scenario: 回车与直接发送不能在切换中穿透',
      '#### Scenario: 切换与删除互斥',
      '#### Scenario: 切换保留工作区与历史溢出引用',
      '#### Scenario: 切换不影响其它 Session',
      '#### Scenario: 切换后清除旧实例占用快照',
      '#### Scenario: 无当前会话时直接发送保持既有行为',
      '#### Scenario: 普通恢复发现实例模板不一致',
      '#### Scenario: 切换中途失败不伪装成功',
    ]) {
      // ignore: avoid_print
      print('  [OBS] agent-runtime 场景「$scenario」='
          '${runtimeSpec.contains(scenario)}');
      expect(runtimeSpec, contains(scenario),
          reason: 'agent-runtime 缺场景：$scenario');
    }
    expect(runtimeSpec, contains('不得只改显示或数据库而继续复用旧实例'));

    // ② session-persistence 必须含切换持久化与失败回读场景。
    for (final scenario in const [
      '#### Scenario: Switch the current session template',
      '#### Scenario: Switched template survives restoration',
      '#### Scenario: Invalid switch has no side effects',
      '#### Scenario: Switch requires an existing session row',
      '#### Scenario: Failure restores the persisted UI value',
    ]) {
      // ignore: avoid_print
      print('  [OBS] session-persistence 场景「$scenario」='
          '${persistenceSpec.contains(scenario)}');
      expect(persistenceSpec, contains(scenario),
          reason: 'session-persistence 缺场景：$scenario');
    }

    // ③ 返工测试文件真实存在，且 tasks.md 点名了它们。
    for (final path in const [
      'test/unit/session_agent_controller_test.dart',
      'test/widget/session_agent_switcher_test.dart',
      'test/integration/session_agent_switch_test.dart',
    ]) {
      // ignore: avoid_print
      print('  [OBS] 返工测试文件 $path 存在=${File(path).existsSync()} '
          'tasks 点名=${tasksText.contains(path)}');
      expect(File(path).existsSync(), isTrue,
          reason: '返工测试文件不存在：$path');
      expect(tasksText, contains(path), reason: 'tasks.md 没有点名 $path');
    }

    // ④ 界面必须真的接到实例替换上（不是只加了一个下拉框）。
    for (final needle in const [
      'SessionAgentSwitcher(',
      '_sessionController.switchTemplate(',
      '_callbacksFor(sessionId)',
      'sendMessageDirectly',
      'beginDelete(',
      'endDelete(',
      '_contextSnapshot = null',
    ]) {
      // ignore: avoid_print
      print('  [OBS] lib/main.dart 含「$needle」=${mainText.contains(needle)}');
      expect(mainText, contains(needle),
          reason: '界面没有接通切换路径：缺少「$needle」');
    }
    expect(controllerText, contains('AgentSwitchStage'),
        reason: '控制器必须报出失败阶段');
    expect(controllerText, contains('updateAgentType'),
        reason: '控制器必须持久化新的 agent_type');
    expect(repoText, contains('updateAgentType'));
    expect(repoText, contains('updated != 1'),
        reason: '未更新到唯一既有行必须显式失败');
    expect(factoryText, contains('validateCandidate'),
        reason: '候选预检必须与创建路径共用规则');
    expect(factoryText, contains('AgentTemplateMismatchException'),
        reason: 'ensure 必须拒绝复用模板名不一致的实例');
    expect(agentText, contains('Future<void> retire()'));
    expect(agentText, contains('isRetiring'));

    // ⑤ 退役路径的源代码级守卫：`_retire()` 方法体里出现 disposeContext /
    //    cancelRequest / 提前中断标记就红（这一条守着"保留溢出文件与在途轮次"）。
    final retireBody = _methodBody(agentText, 'Future<void> _retire()');
    // ignore: avoid_print
    print('  [OBS] _retire() 方法体=${retireBody.replaceAll('\n', ' ')}');
    expect(retireBody, isNot(contains('disposeContext')),
        reason: '退役不得调用 disposeContext（会删掉溢出目录）');
    expect(retireBody, isNot(contains('cancelRequest')),
        reason: '退役不得 cancelRequest（会中断在途整轮）');
    expect(retireBody, isNot(contains('_disposed = true')),
        reason: '退役不得提前把实例标成已销毁');
    expect(retireBody, isNot(contains('_cancelledEpoch')));
  });
}

/// 抽取以 [signature] 开头的方法（含签名）到配对右括号为止的源码块。
///
/// 用括号配对而不是行号：文件一被编辑行号就失效（这也是本仓库的既有教训）。
String _methodBody(String source, String signature) {
  final start = source.indexOf(signature);
  expect(start >= 0, isTrue, reason: '源码里找不到方法签名「$signature」');
  final begin = source.indexOf('{', start + signature.length);
  expect(begin >= 0, isTrue, reason: '「$signature」后面没有方法体');
  var depth = 0;
  var i = begin;
  for (; i < source.length; i++) {
    final c = source[i];
    if (c == '{') depth++;
    if (c == '}') {
      depth--;
      if (depth == 0) break;
    }
  }
  expect(i < source.length, isTrue, reason: '「$signature」的方法体括号没有配对');
  return source.substring(begin, i + 1);
}
