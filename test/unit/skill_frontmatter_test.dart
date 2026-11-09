// `SKILL.md` frontmatter 切除与规范六字段校验的单测（change
// `add-skill-mechanism` 任务 1.3）。
//
// 每条判据都回链 `Docs/AgentSkillsDoc.md` 第一节字段表（规范硬限 64 / 1024 / 500，
// 1–N 含下界）与该文件第二节关于 Claude Code 加载侧宽松行为的记载（未知键忽略、
// 首行恰 `---` 才算 frontmatter）。
//
// 其中「跨侧夹具」一节与 C++ 侧 `sidecar/test/skill_tool_test.cpp` 读**同一个文件**
// （`sidecar/test/fixtures/skills/edge-skill/SKILL.md`），两侧断言同一个正文串：
// 这就是 design D2 的"两侧切除行为互验"，任一侧改动规则而另一侧没改，这里与那边
// 会各红一条。
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:alias_agent/services/skills/skill_frontmatter.dart';

/// 造一份 `SKILL.md`：frontmatter 块 + 正文。
String skillMd(String frontmatter, {String body = '# 正文\n'}) =>
    '---\n$frontmatter---\n$body';

/// `name` 取值：n 个小写字母（合法字符集，只受长度约束）。
String repeatedName(int n) => 'a' * n;

/// 跨侧夹具的正文预期（与 C++ 侧逐行相同的字面量，见文件头说明）。
const List<String> kEdgeSkillBodyLines = [
  '# 正文第一行',
  '',
  '这一段里有分隔线：',
  '',
  '---',
  '',
  '正文在第二个独立 `---` 之后必须继续（它属于正文，不能被当定界行）。',
];

void main() {
  group('frontmatter 切除规则（design D2）', () {
    test('首行不是 `---` ⇒ 判为无 frontmatter，整个文件都是正文', () {
      const raw = 'name: no-frontmatter\n# 正文\n';
      final split = splitSkillMd(raw);
      // ignore: avoid_print
      print('[切除] 首行不是 ---：hasFrontmatter=${split.hasFrontmatter} '
          'body=${split.body}');
      expect(split.hasFrontmatter, isFalse);
      expect(split.frontmatterText, isEmpty);
      expect(split.body, raw, reason: '无 frontmatter 时正文就是整个文件（D2）');

      final result =
          validateSkillMd(raw: raw, directoryName: 'no-frontmatter');
      // ignore: avoid_print
      print('[切除] 首行不是 --- 的校验结果：ok=${result.ok} error=${result.error}');
      expect(result.ok, isFalse, reason: '没有 frontmatter 必须判校验失败');
      expect(result.error, contains('没有 frontmatter'));
    });

    test('正文里的独立 `---` 行留在正文：只切第一个闭合行', () {
      const raw = '---\n'
          'name: pdf-tools\n'
          'description: 处理 PDF\n'
          '---\n'
          '# 正文\n'
          '\n'
          '---\n'
          '分隔线之后仍然是正文\n';
      final split = splitSkillMd(raw);
      // ignore: avoid_print
      print('[切除] frontmatter=${split.frontmatterText.replaceAll("\n", "\\n")}');
      // ignore: avoid_print
      print('[切除] body=${split.body.replaceAll("\n", "\\n")}');
      expect(split.hasFrontmatter, isTrue);
      expect(split.frontmatterText,
          'name: pdf-tools\ndescription: 处理 PDF\n');
      expect(split.body, '# 正文\n\n---\n分隔线之后仍然是正文\n',
          reason: '闭合行之后的所有内容都是正文，包括其后另一个独立 --- 行');

      final result =
          validateSkillMd(raw: raw, directoryName: 'pdf-tools');
      expect(result.ok, isTrue, reason: result.error);
      expect(result.fields!.body, split.body);
    });

    test('CRLF 文件同样识别（行尾 \\r 不影响定界判定）', () {
      const raw = '---\r\nname: crlf-skill\r\ndescription: CRLF 文件\r\n---\r\n# 正文\r\n';
      final split = splitSkillMd(raw);
      // ignore: avoid_print
      print('[切除] CRLF：hasFrontmatter=${split.hasFrontmatter} '
          'body=${split.body.replaceAll("\r", "\\r").replaceAll("\n", "\\n")}');
      expect(split.hasFrontmatter, isTrue);
      expect(split.frontmatterText, 'name: crlf-skill\r\ndescription: CRLF 文件\r\n');
      expect(split.body, '# 正文\r\n');
      expect(validateSkillMd(raw: raw, directoryName: 'crlf-skill').ok, isTrue);
    });

    test('只有开头 `---` 没有闭合行 ⇒ 无 frontmatter，整个文件是正文', () {
      const raw = '---\nname: dangling\ndescription: 缺闭合行\n';
      final split = splitSkillMd(raw);
      expect(split.hasFrontmatter, isFalse);
      expect(split.body, raw);
    });

    test('跨侧夹具：Dart 侧切除结果 == C++ 侧同一份夹具的预期区间', () {
      final file = File('sidecar/test/fixtures/skills/edge-skill/SKILL.md');
      expect(file.existsSync(), isTrue,
          reason: '跨侧夹具必须存在：${file.absolute.path}');
      final raw = file.readAsStringSync();
      final expectedBody = '${kEdgeSkillBodyLines.join('\n')}\n';

      final split = splitSkillMd(raw);
      // ignore: avoid_print
      print('[跨侧夹具] hasFrontmatter=${split.hasFrontmatter} '
          'bodyBytes=${split.body.length} body=${split.body.replaceAll("\n", "\\n")}');
      expect(split.hasFrontmatter, isTrue);
      expect(split.frontmatterText, contains('context: fork'),
          reason: '夹具的未知键要在 frontmatter 块里（切除不能把它带进正文）');
      expect(split.body, expectedBody,
          reason: 'D2：C++ 侧 skill_tool_test.cpp 对同一文件断言同一个正文串');

      final result =
          validateSkillMd(raw: raw, directoryName: 'edge-skill');
      // ignore: avoid_print
      print('[跨侧夹具] 校验：ok=${result.ok} error=${result.error} '
          'name=${result.fields?.name} description=${result.fields?.description}');
      expect(result.ok, isTrue, reason: result.error);
      expect(result.fields!.name, 'edge-skill',
          reason: 'name 必须与父目录名 edge-skill 一致');
      expect(result.fields!.description,
          '两侧切除互验夹具：值里带引号与冒号：like this');
      expect(result.fields!.compatibility, '只在测试里用');
      expect(result.fields!.body, expectedBody);
    });
  });

  group('name 字段（Docs/AgentSkillsDoc.md 第一节：1–64 字符、字符集、与目录名一致）',
      () {
    test('65 字符 ⇒ 校验失败，原因写明超过 64', () {
      final name = repeatedName(65);
      final result = validateSkillMd(
        raw: skillMd('name: $name\ndescription: 长名字\n'),
        directoryName: name,
      );
      // ignore: avoid_print
      print('[name] 65 字符：ok=${result.ok} error=${result.error}');
      expect(result.ok, isFalse);
      expect(result.error, contains('name 超过 64 字符'));
      expect(result.error, contains('实际 65'));
    });

    test('64 字符 ⇒ 校验通过（1–N 口径含上界）', () {
      final name = repeatedName(64);
      final result = validateSkillMd(
        raw: skillMd('name: $name\ndescription: 边界名字\n'),
        directoryName: name,
      );
      // ignore: avoid_print
      print('[name] 64 字符：ok=${result.ok} error=${result.error}');
      expect(result.ok, isTrue, reason: result.error);
      expect(result.fields!.name, name);
    });

    test('pdf--processing（连续 --）⇒ 校验失败', () {
      final result = validateSkillMd(
        raw: skillMd('name: pdf--processing\ndescription: 双连字符\n'),
        directoryName: 'pdf--processing',
      );
      // ignore: avoid_print
      print('[name] 连续 --：ok=${result.ok} error=${result.error}');
      expect(result.ok, isFalse);
      expect(result.error, contains('不得含连续'));
    });

    test('name 与父目录名不一致 ⇒ 校验失败且两个名字都在原因里', () {
      final result = validateSkillMd(
        raw: skillMd('name: pdf-processing\ndescription: 目录名不符\n'),
        directoryName: 'pdf-tools',
      );
      // ignore: avoid_print
      print('[name] 目录名不符：ok=${result.ok} error=${result.error}');
      expect(result.ok, isFalse);
      expect(result.error, contains('pdf-tools'));
      expect(result.error, contains('pdf-processing'));
    });

    test('大写字母 / 以连字符开头 / 空串 ⇒ 都判失败', () {
      for (final bad in ['Pdf-Tools', '-pdf', '']) {
        final result = validateSkillMd(
          raw: skillMd('name: "$bad"\ndescription: 非法名字\n'),
          directoryName: bad,
        );
        // ignore: avoid_print
        print('[name] "$bad"：ok=${result.ok} error=${result.error}');
        expect(result.ok, isFalse, reason: 'name "$bad" 必须判失败');
      }
    });

    test('缺少 name ⇒ 校验失败并点名必填', () {
      final result = validateSkillMd(
        raw: skillMd('description: 没有 name\n'),
        directoryName: 'no-name',
      );
      // ignore: avoid_print
      print('[name] 缺字段：ok=${result.ok} error=${result.error}');
      expect(result.ok, isFalse);
      expect(result.error, contains('缺少必填字段 name'));
    });
  });

  group('description 字段（第一节：1–1024 字符，非空）', () {
    test('1025 字符 ⇒ 失败；1024 字符 ⇒ 通过', () {
      final tooLong = 'd' * 1025;
      final over = validateSkillMd(
        raw: skillMd('name: d-skill\ndescription: $tooLong\n'),
        directoryName: 'd-skill',
      );
      // ignore: avoid_print
      print('[description] 1025：ok=${over.ok} error=${over.error}');
      expect(over.ok, isFalse);
      expect(over.error, contains('description 超过 1024 字符'));

      final boundary = 'd' * 1024;
      final atLimit = validateSkillMd(
        raw: skillMd('name: d-skill\ndescription: $boundary\n'),
        directoryName: 'd-skill',
      );
      // ignore: avoid_print
      print('[description] 1024：ok=${atLimit.ok} error=${atLimit.error}');
      expect(atLimit.ok, isTrue, reason: atLimit.error);
      expect(atLimit.fields!.description.length, 1024,
          reason: '本应用不再截断或改写 description（规范硬限已在校验处把关）');
    });

    test('缺失 / 空串 / 纯空白 ⇒ 都判失败', () {
      for (final body in ['', 'description: ""\n', 'description: "   "\n']) {
        final result = validateSkillMd(
          raw: skillMd('name: empty-desc\n$body'),
          directoryName: 'empty-desc',
        );
        // ignore: avoid_print
        print('[description] "$body"：ok=${result.ok} error=${result.error}');
        expect(result.ok, isFalse);
      }
    });
  });

  group('compatibility 字段（第一节：若提供则 1–500 字符）', () {
    test('501 字符 ⇒ 失败；500 字符 ⇒ 通过', () {
      final tooLong = 'c' * 501;
      final over = validateSkillMd(
        raw: skillMd(
            'name: c-skill\ndescription: 兼容性\ncompatibility: $tooLong\n'),
        directoryName: 'c-skill',
      );
      // ignore: avoid_print
      print('[compatibility] 501：ok=${over.ok} error=${over.error}');
      expect(over.ok, isFalse);
      expect(over.error, contains('compatibility 超过 500 字符'));

      final boundary = 'c' * 500;
      final atLimit = validateSkillMd(
        raw: skillMd(
            'name: c-skill\ndescription: 兼容性\ncompatibility: $boundary\n'),
        directoryName: 'c-skill',
      );
      // ignore: avoid_print
      print('[compatibility] 500：ok=${atLimit.ok} error=${atLimit.error}');
      expect(atLimit.ok, isTrue, reason: atLimit.error);
      expect(atLimit.fields!.compatibility!.length, 500);
    });

    test('空串 ⇒ 校验失败（1–N 口径含下界）', () {
      final result = validateSkillMd(
        raw: skillMd(
            'name: empty-compat\ndescription: 兼容性\ncompatibility: ""\n'),
        directoryName: 'empty-compat',
      );
      // ignore: avoid_print
      print('[compatibility] 空串：ok=${result.ok} error=${result.error}');
      expect(result.ok, isFalse);
      expect(result.error, contains('compatibility'));
    });

    test('不提供 compatibility ⇒ 通过（可选字段）', () {
      final result = validateSkillMd(
        raw: skillMd('name: no-compat\ndescription: 没有兼容性字段\n'),
        directoryName: 'no-compat',
      );
      expect(result.ok, isTrue, reason: result.error);
      expect(result.fields!.compatibility, isNull);
    });
  });

  group('规范之外的键与取值（第二节：Claude Code 加载侧宽松口径）', () {
    test('带 context: fork 未知键照常通过，且该键不进入载荷', () {
      final result = validateSkillMd(
        raw: skillMd('name: fork-skill\ndescription: 带扩展字段\n'
            'context: fork\nmodel: sonnet\n'),
        directoryName: 'fork-skill',
      );
      // ignore: avoid_print
      print('[未知键] ok=${result.ok} error=${result.error}');
      expect(result.ok, isTrue, reason: result.error);
      expect(result.fields!.name, 'fork-skill');
    });

    test('值里含引号与冒号：原样解析，不改写不截断', () {
      // YAML 单引号标量里 `"` 是普通字符、`:` 不需要转义 —— 这一条测的是
      // "值形态怪但合法"时解析器不被卡住，且我们原样交出去。
      const description = '处理 "PDF": 先读再改；key: value 也照写';
      final result = validateSkillMd(
        raw: skillMd("name: quoted-skill\ndescription: '$description'\n"),
        directoryName: 'quoted-skill',
      );
      // ignore: avoid_print
      print('[取值] description=${result.fields?.description}');
      expect(result.ok, isTrue, reason: result.error);
      expect(result.fields!.description, description);
    });

    test('YAML 解析失败 ⇒ 校验失败并给出原因', () {
      final result = validateSkillMd(
        raw: skillMd('name: "unclosed\ndescription: 坏 YAML\n'),
        directoryName: 'bad-yaml',
      );
      // ignore: avoid_print
      print('[YAML] ok=${result.ok} error=${result.error}');
      expect(result.ok, isFalse);
      expect(result.error, contains('YAML'));
    });

    test('license / metadata / allowed-tools 可选且被保留', () {
      final result = validateSkillMd(
        raw: skillMd('name: extras\ndescription: 可选字段\n'
            'license: MIT\n'
            'metadata:\n  author: someone\n'
            'allowed-tools: "read_file write_file"\n'),
        directoryName: 'extras',
      );
      // ignore: avoid_print
      print('[可选字段] ok=${result.ok} license=${result.fields?.license} '
          'metadata=${result.fields?.metadata} '
          'allowed-tools=${result.fields?.allowedTools}');
      expect(result.ok, isTrue, reason: result.error);
      expect(result.fields!.license, 'MIT');
      expect(result.fields!.metadata, {'author': 'someone'});
      expect(result.fields!.allowedTools, 'read_file write_file');
    });
  });
}
