// 覆盖层解析的纯逻辑（change `agent-group-chat` 任务 2.1~2.4 /
// spec `agent-instance-overrides`）。
//
// 覆盖层只有三个字段，全部是"收紧或追加"。这里逐条钉住：
//   2.1 空值三态：缺席 / 显式 [] / 显式空串 三者互不等价；替换类字段被拒。
//   2.2 工具子集只能取模板已有工具（未知 / 超出模板 / 重复 / 空名一律拒绝并列名字）。
//   2.3 生效工具 = 模板 ∩ 子集（顺序按模板）；空子集求交为空；模板漂移只收紧。
//   2.4 提示词 append 语义；思考强度白名单外保存时拒绝、显式空串接受。
import 'package:flutter_test/flutter_test.dart';

import 'package:alias_agent/models/agent_type_config.dart';
import 'package:alias_agent/models/instance_overrides.dart';

AgentTypeConfig _template({
  List<String> tools = const ['read_file', 'list_dir', 'run_command'],
  String systemPrompt = '模板提示词：你是审阅者。',
  String? thinkingEffort,
}) =>
    AgentTypeConfig(
      name: 'reviewer',
      provider: 'test-provider',
      model: 'test-model',
      systemPrompt: systemPrompt,
      tools: tools,
      thinkingEffort: thinkingEffort,
      maxContextTokens: 200000,
    );

void main() {
  group('2.1 覆盖层空值三态', () {
    test('缺席与模板逐字段相等', () {
      final overrides = AgentInstanceOverrides.none;
      // ignore: avoid_print
      print('[OBS] none.isEmpty=${overrides.isEmpty} hasTools=${overrides.hasToolsSubset} '
          'hasAppend=${overrides.hasSystemPromptAppend} hasEffort=${overrides.hasThinkingEffort}');

      final template = _template();
      final effective = overrides.describeEffective(
        templateTools: template.tools,
        templatePrompt: template.systemPrompt,
        templateThinkingMode: 'disabled',
        templateThinkingEffort: '',
        model: template.model,
        windowTokens: template.maxContextTokens!,
      );
      // ignore: avoid_print
      print('[OBS] 无覆盖生效值=$effective');

      expect(overrides.isEmpty, isTrue);
      expect(effective['tools'], template.tools);
      expect(effective['systemPrompt'], template.systemPrompt);
      expect(effective['thinkingMode'], 'disabled');
      expect(effective['thinkingEffort'], '');
      expect(effective['model'], template.model);
      expect(effective['maxContextTokens'], template.maxContextTokens);

      // 从空 JSON 解析出来的也等于"没有覆盖"。
      final fromEmpty = AgentInstanceOverrides.fromJson(const {});
      expect(fromEmpty.isEmpty, isTrue);
      expect(fromEmpty.toJsonString(), isNull,
          reason: '没有覆盖时落库写 NULL，不写 "{}"');
    });

    test('显式 [] 是零工具（与"缺席"不等价）', () {
      final absent = AgentInstanceOverrides.none;
      final explicit = AgentInstanceOverrides.fromJson({'toolsSubset': <String>[]});
      // ignore: avoid_print
      print('[OBS] 缺席工具=${absent.effectiveTools(['read_file', 'list_dir'])} '
          '显式空工具=${explicit.effectiveTools(['read_file', 'list_dir'])} '
          '落库=${explicit.toJsonString()}');

      expect(explicit.hasToolsSubset, isTrue);
      expect(explicit.effectiveTools(['read_file', 'list_dir']), isEmpty);
      expect(absent.effectiveTools(['read_file', 'list_dir']),
          ['read_file', 'list_dir']);
      expect(explicit.toJsonString(), '{"toolsSubset":[]}');
    });

    test('显式空串是关闭思考（与"缺席"不等价）', () {
      final absent = AgentInstanceOverrides.none;
      final closed = AgentInstanceOverrides.fromJson({'thinkingEffort': ''});
      // ignore: avoid_print
      print('[OBS] 缺席推导=${absent.effectiveThinking()} '
          '显式空串=${closed.effectiveThinking()} 落库=${closed.toJsonString()}');

      expect(closed.hasThinkingEffort, isTrue);
      expect(closed.effectiveThinking(), (mode: 'disabled', effort: ''));
      expect(absent.effectiveThinking(), isNull,
          reason: '缺席 = 无覆盖 ⇒ 由调用方按模板 + 目录推导');
      expect(closed.toJsonString(), '{"thinkingEffort":""}');
    });

    test('替换类字段被拒（点名字段，MUST NOT 静默忽略）', () {
      for (final field in ['model', 'max_context_tokens', 'provider', 'system_prompt']) {
        Object? error;
        try {
          AgentInstanceOverrides.fromJson({field: 'x'});
        } catch (e) {
          error = e;
        }
        // ignore: avoid_print
        print('[OBS] 替换字段 $field => $error');
        expect(error, isA<AgentOverridesException>());
        expect('$error', contains(field), reason: '错误必须点名不支持的字段');
      }
    });
  });

  group('2.2 工具子集校验（只能收紧）', () {
    test('扩出模板被拒并列出名字', () {
      final template = _template(tools: ['read_file', 'list_dir']);
      final overrides =
          AgentInstanceOverrides.fromJson({'toolsSubset': <String>['read_file', 'run_command']});
      Object? error;
      try {
        overrides.validateForSave(
            template: template, knownTools: {'read_file', 'list_dir', 'run_command'});
      } catch (e) {
        error = e;
      }
      // ignore: avoid_print
      print('[OBS] 扩出模板 => $error');
      expect(error, isA<AgentOverridesException>());
      expect('$error', contains('run_command'), reason: '必须列出不被接受的名字');
      expect('$error', contains('模板'), reason: '说明是"超出模板"而不是"未知工具"');
    });

    test('未知工具被拒（与模板创建时同一判据）', () {
      final overrides =
          AgentInstanceOverrides.fromJson({'toolsSubset': <String>['no_such_tool']});
      Object? error;
      try {
        overrides.validateForSave(
            template: _template(), knownTools: {'read_file', 'list_dir', 'run_command'});
      } catch (e) {
        error = e;
      }
      // ignore: avoid_print
      print('[OBS] 未知工具 => $error');
      expect(error, isA<AgentOverridesException>());
      expect('$error', contains('no_such_tool'));
      expect('$error', contains('工具目录'), reason: '指出目录里没有这个名字');
    });

    test('重复名与空名被拒', () {
      final known = {'read_file', 'list_dir', 'run_command'};
      final duplicate = AgentInstanceOverrides.fromJson({
        'toolsSubset': ['read_file', 'read_file'],
      });
      Object? dupError;
      try {
        duplicate.validateForSave(template: _template(), knownTools: known);
      } catch (e) {
        dupError = e;
      }
      final empty =
          AgentInstanceOverrides.fromJson({'toolsSubset': <String>['']});
      Object? emptyError;
      try {
        empty.validateForSave(template: _template(), knownTools: known);
      } catch (e) {
        emptyError = e;
      }
      // ignore: avoid_print
      print('[OBS] 重复 => $dupError 空名 => $emptyError');
      expect(dupError, isA<AgentOverridesException>());
      expect('$dupError', contains('重复'));
      expect(emptyError, isA<AgentOverridesException>());
      expect('$emptyError', contains('不能为空'));
    });

    test('空子集合法（零工具是允许的收紧）', () {
      final overrides = AgentInstanceOverrides.fromJson({'toolsSubset': <String>[]});
      // 不抛 = 合法。
      overrides.validateForSave(
          template: _template(),
          knownTools: {'read_file', 'list_dir', 'run_command'});
      expect(overrides.effectiveTools(['read_file']), isEmpty);
    });
  });

  group('2.3 求交与模板漂移', () {
    test('求交按模板顺序', () {
      final template = _template(
          tools: ['read_file', 'list_dir', 'run_command', 'grep_file']);
      final overrides = AgentInstanceOverrides.fromJson({
        'toolsSubset': ['run_command', 'read_file'],
      });
      final effective = overrides.effectiveTools(template.tools);
      // ignore: avoid_print
      print('[OBS] 求交结果=$effective');
      expect(effective, ['read_file', 'run_command'],
          reason: '顺序按模板，不按子集给的顺序');
    });

    test('空子集求交为空', () {
      final overrides = AgentInstanceOverrides.fromJson({'toolsSubset': <String>[]});
      expect(overrides.effectiveTools(['a', 'b']), isEmpty);
    });

    test('模板漂移只收紧且留一行说明', () {
      final overrides = AgentInstanceOverrides.fromJson({
        'toolsSubset': ['read_file', 'grep_file'],
      });
      // 模板后来删掉了 grep_file。
      final effective = overrides.effectiveTools(['read_file', 'list_dir']);
      // ignore: avoid_print
      print('[OBS] 漂移后生效=$effective 覆盖层存储=${overrides.toJsonString()}');
      expect(effective, ['read_file']);
      expect(overrides.toJsonString(), contains('grep_file'),
          reason: '覆盖层存储本身不改写（说明只记日志，不静默改配置）');
    });
  });

  group('2.4 提示词追加与思考强度', () {
    test('追加不替换', () {
      final overrides =
          AgentInstanceOverrides.fromJson({'systemPromptAppend': '协作时先读文件。'});
      final prompt = overrides.effectiveSystemPrompt('模板提示词。');
      // ignore: avoid_print
      print('[OBS] 生效提示词=「$prompt」');
      expect(prompt, startsWith('模板提示词。'));
      expect(prompt, endsWith('协作时先读文件。'));
      expect(prompt, contains('模板提示词。'));
    });

    test('空追加逐字相同（不多空行）', () {
      const template = '模板提示词。\n第二行。';
      final absent = AgentInstanceOverrides.none;
      final empty = AgentInstanceOverrides.fromJson({'systemPromptAppend': ''});
      // ignore: avoid_print
      print('[OBS] 缺席=「${absent.effectiveSystemPrompt(template)}」 '
          '空串=「${empty.effectiveSystemPrompt(template)}」');
      expect(absent.effectiveSystemPrompt(template), template);
      expect(empty.effectiveSystemPrompt(template), template,
          reason: '空追加段不产生多余空行');
    });

    test('非法 effort 保存被拒并列出合法档位', () {
      final overrides =
          AgentInstanceOverrides.fromJson({'thinkingEffort': 'MAX'});
      Object? error;
      try {
        overrides.validateForSave(
            template: _template(), knownTools: {'read_file', 'list_dir', 'run_command'});
      } catch (e) {
        error = e;
      }
      // ignore: avoid_print
      print('[OBS] 非法 effort => $error');
      expect(error, isA<AgentOverridesException>());
      expect('$error', contains('low'), reason: '必须列出合法档位');
      expect('$error', contains('max'));
      expect('$error', contains('空串'), reason: '说明空串表示关闭思考');
    });

    test('显式空串接受为关闭', () {
      final overrides = AgentInstanceOverrides.fromJson({'thinkingEffort': ''});
      overrides.validateForSave(
          template: _template(), knownTools: {'read_file', 'list_dir', 'run_command'});
      expect(overrides.effectiveThinking(), (mode: 'disabled', effort: ''));
    });

    test('白名单内的档位生效', () {
      final overrides =
          AgentInstanceOverrides.fromJson({'thinkingEffort': 'high'});
      overrides.validateForSave(
          template: _template(), knownTools: {'read_file', 'list_dir', 'run_command'});
      expect(overrides.effectiveThinking(), (mode: 'adaptive', effort: 'high'));
    });
  });
}
