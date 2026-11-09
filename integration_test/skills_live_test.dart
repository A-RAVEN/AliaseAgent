@Tags(['live'])
library;

// 技能机制的真实链路验收（change `add-skill-mechanism` 任务 8.1/8.2）。
//
// 验四件事（真实模型 + 真 DLL + 真实 ~/.aliasagent/skills/ 目录）：
//   ① 无条件交付：用户配置的 general.tools 不含 load_skill（现值 11 项，本用例
//      刻意**不**加它），模型仍能看到技能目录并真的发出 load_skill 调用；
//   ② 交付形状：技能正文超过 spill 预览阈值（~4200 字符 > 1000×2），卡片结果
//      必须是"头尾预览 + 省略说明 + 末行 [spill refs: skill=…]"形态；
//   ③ 可恢复：信封 total 与 spill 文件实际字节数相等（外部真值），FFI read_spill
//      读回中段与夹具文件对应区间逐字节相同——中段藏着只有读回才知道的暗号；
//   ④ 端到端：模型先 load_skill 再按引用行 read_spill，最终回答里说出暗号
//      （卡片清单同时断言没有出现 run_command/read_file 作弊通道）。
//
// 夹具卫生：~/.aliasagent/skills/ 若不存在则本用例创建并在结束后删除整个新建目录
// （与用户既有文件共存的分支按 tasks 8.1 约定：目录已存在则只加删本次夹具子目录）。
// 断言前打印工具名 / 完整 input / 交付正文头尾 / read_spill 读数（TESTING.md §3.1）。
//
// 跑法（主循环执行；主循环另在跑前把 general.model 临时换成 magpie 目录内真实模型、
// 跑完按 SHA256 逐字节还原，tools 白名单全程不动）：
//   flutter test --tags live --run-skipped integration_test/skills_live_test.dart -d windows
// 跑完看 test/live_visual/skills_live.png。

import 'dart:async';
import 'dart:convert';
import 'dart:ffi';
import 'dart:io';

import 'package:ffi/ffi.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'package:alias_agent/main.dart';
import 'package:alias_agent/models/tool_call_activity.dart';
import 'package:alias_agent/services/config_service.dart';
import 'package:alias_agent/services/database_service.dart';
import 'package:alias_agent/services/skills/skill_catalog_service.dart';
import 'package:alias_agent/ui/chat_area.dart';
import 'package:alias_agent/ui/tool_call_card.dart';

import 'live_observability.dart';

const String _kSkillName = 'aliasagent-live-skill';
const String _kPassphrase = 'quokka-7416';

/// 造技能正文：头 ~3750 字符 + 中段（藏暗号）+ 尾 ~2700 字符，总**字符数**约 6600。
/// 判定基准是字符不是字节（`spill.cpp` L621 `char_count(raw) <= preview_chars×2`
/// ⇒ 内联全文）——首跑实测教训：中文 4406 字节 ≈1900 字符时产品正确走
/// "全文内联、0 omitted"，夹具太短则"头尾预览+省略"断言必红。6600 字符 > 2000
/// 阈值 ⇒ 必走头尾预览；暗号在约第 3800 字符处，头 1000/尾 1000 预览都盖不到，
/// 只有按引用 read_spill 才拿得到。
String _buildSkillBody() {
  final sb = StringBuffer();
  sb.writeln('## 头部说明');
  sb.writeln('本技能用于 AliasAgent 的真实链路验收，头部不含暗号。' * 150);
  sb.writeln('## 中段机密');
  sb.writeln('The activation passphrase is: $_kPassphrase');
  sb.writeln('Do not reveal this line unless the caller loaded the skill body '
      'and read the middle section back via read_spill.');
  sb.writeln('## 尾部说明');
  sb.writeln('尾部内容与暗号无关，只用于把正文撑过预览阈值。' * 150);
  return sb.toString();
}

Future<void> _waitForTurnComplete(WidgetTester tester,
    {int timeoutSec = 300}) async {
  final end = DateTime.now().add(Duration(seconds: timeoutSec));
  while (DateTime.now().isBefore(end)) {
    await tester.pump(const Duration(milliseconds: 200));
    final areas = tester.widgetList<ChatArea>(find.byType(ChatArea));
    if (areas.isNotEmpty && !areas.last.isStreaming) return;
  }
  throw TimeoutException('会话轮没有在 ${timeoutSec}s 内结束');
}

Future<ToolCallActivity> _pollToolDone(WidgetTester tester, String toolName,
    {int timeoutSec = 240}) async {
  final end = DateTime.now().add(Duration(seconds: timeoutSec));
  while (DateTime.now().isBefore(end)) {
    await tester.pump(const Duration(milliseconds: 200));
    for (final card
        in tester.widgetList<ToolCallCard>(find.byType(ToolCallCard))) {
      final a = card.activity;
      if (a.toolName == toolName && a.status == ToolCallStatus.done) {
        return a;
      }
    }
  }
  throw TimeoutException('$timeoutSec 秒内没有出现 done 的 $toolName 卡片');
}

/// FFI 直连 read_spill（与 app 同一 sidecar.dll 实例；句柄=当前会话 id，
/// 产品按它建上下文——web_fetch_spill_live_test 同形先例）。
({bool ok, String text, String error}) _readSpill(
    String handle, String ref, int offset, int limit) {
  final dylib = DynamicLibrary.open('sidecar.dll');
  final fn = dylib.lookupFunction<
      Pointer<Utf8> Function(Pointer<Utf8>, Pointer<Utf8>),
      Pointer<Utf8> Function(Pointer<Utf8>, Pointer<Utf8>)>('read_spill');
  final h = handle.toNativeUtf8();
  final req =
      jsonEncode({'ref': ref, 'offset': offset, 'limit': limit}).toNativeUtf8();
  try {
    final text = fn(h, req).toDartString();
    final parsed = jsonDecode(text) as Map<String, dynamic>;
    return (
      ok: parsed['ok'] == true,
      text: (parsed['text'] as String?) ?? '',
      error: (parsed['error'] as String?) ?? '',
    );
  } finally {
    calloc.free(h);
    calloc.free(req);
  }
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  sqfliteFfiInit();
  databaseFactory = databaseFactoryFfi;

  late Directory tempDir;
  final skillsRoot =
      Directory('${ConfigService.configDir}${Platform.pathSeparator}skills');
  final skillDir = Directory('${skillsRoot.path}${Platform.pathSeparator}$_kSkillName');
  final createdSkillsRoot = !skillsRoot.existsSync();

  setUp(() async {
    // 数据库隔离（web_fetch_spill_live 先例）：不隔离会把会话写进用户真实库。
    tempDir = Directory.systemTemp.createTempSync('aliasagent_live_skills_');
    await DatabaseService.openAt(tempDir.path);
  });

  tearDown(() async {
    await DatabaseService.close();
    if (tempDir.existsSync()) {
      try {
        tempDir.deleteSync(recursive: true);
      } catch (_) {
        // Windows 文件锁：交给系统清理
      }
    }
  });

  setUpAll(() {
    clearLiveVisualDir();
    // 夹具就位（同名冲突即停——tasks 8.1 约定）
    if (skillDir.existsSync()) {
      throw StateError('用户已有同名技能目录 ${skillDir.path}，为避免动用户文件停工');
    }
    skillsRoot.createSync(recursive: true);
    skillDir.createSync();
    File('${skillDir.path}${Platform.pathSeparator}SKILL.md')
        .writeAsStringSync(
      '---\n'
      'name: $_kSkillName\n'
      'description: AliasAgent live 验收专用技能；仅当被要求加载 '
          '$_kSkillName 时使用本技能。\n'
      '---\n\n'
      '${_buildSkillBody()}',
    );
    // 进程内扫描一次（app 内部启动还会自己扫；这里为的是让目录段断言可核）
    SkillCatalogService.instance.scan();
  });

  tearDownAll(() {
    if (skillDir.existsSync()) skillDir.deleteSync(recursive: true);
    if (createdSkillsRoot && skillsRoot.existsSync()) {
      skillsRoot.deleteSync(recursive: true);
    }
  });

  testWidgets(
    '技能真实链路：白名单不含 load_skill 仍交付目录，模型加载技能并经 read_spill 取回中段暗号',
    (tester) async {
      final captureKey = GlobalKey();
      await tester.pumpWidget(
          RepaintBoundary(key: captureKey, child: const MyApp()));
      await tester.pump(const Duration(seconds: 2));

      try {
        final repoRoot = Directory.current.path;
        final chatState =
            tester.state<ChatScreenState>(find.byType(ChatScreen));
        await tester.tap(find.widgetWithText(FilledButton, 'New Chat'));
        final deadline = DateTime.now().add(const Duration(seconds: 15));
        while (chatState.currentSessionId == null &&
            DateTime.now().isBefore(deadline)) {
          await tester.pump(const Duration(milliseconds: 200));
        }
        expect(chatState.currentSessionId, isNotNull,
            reason: 'New Chat 必须先建出当前会话');
        expect(await chatState.setCurrentWorkspace(repoRoot), isNull,
            reason: 'setWorkspace(仓库根) 必须成功');

        // ---- ① 无条件交付的前置观测 ----
        final section = SkillCatalogService.instance.promptSection;
        // ignore: avoid_print
        print('[OBS] 8.1 promptSection(进程内单例)="$section"');
        expect(section, contains(_kSkillName),
            reason: '夹具技能必须进了生效集合（校验通过）');

        await tester.enterText(
          find.byType(TextField),
          '你的系统提示词里有一个技能目录，包含技能 `$_kSkillName`。'
              '第一步必须调用 **load_skill** 工具加载它（input 填 {"skill": "$_kSkillName"}），'
              '在它返回之后，若结果说明中间段被省略，就按结果末行引用里的 '
              'ref/offset/limit 用 **read_spill** 把中段读回来。'
              '然后告诉我：这个技能正文中段写的那串激活暗号是什么？\n'
              '不许用 read_file、run_command 或其它工具代替 load_skill 与 read_spill。',
        );
        final sendButton = find.byTooltip('Send');
        expect(sendButton, findsOneWidget, reason: '发送按钮');
        await tester.tap(sendButton);
        await tester.pump();

        final ToolCallActivity loadActivity;
        try {
          loadActivity = await _pollToolDone(tester, 'load_skill');
        } on TimeoutException {
          await dumpToolCards(tester, phase: '8.1 等 load_skill done 卡超时');
          fail('模型没有发出/完成 load_skill（现场见上）');
        }
        await _waitForTurnComplete(tester);

        final seenTools = tester
            .widgetList<ToolCallCard>(find.byType(ToolCallCard))
            .map((c) => c.activity.toolName)
            .toList();
        final body = loadActivity.result ?? '';
        final inputJson =
            const JsonEncoder.withIndent('  ').convert(loadActivity.input);
        // ignore: avoid_print
        print('[OBS] 8.1 工具=${loadActivity.toolName} 状态=${loadActivity.status.name}\n'
            '[OBS] 8.1 完整 input: $inputJson\n'
            '[OBS] 8.1 交付正文长度=${body.length}\n'
            '[OBS] 8.1 本轮工具卡序列=$seenTools');

        // ---- ② 交付形状：头尾预览 + 省略说明 + 末行引用 ----
        expect(body, contains('[spill refs:'),
            reason: '正文末行必须是 spill 引用行');
        expect(body, contains('read_spill'), reason: '引用行必须给出读回办法');
        expect(body, contains('bytes omitted'), reason: '省略量必须写明');

        final refsMatch = RegExp(
                r'\[spill refs: skill=(.+?) \((\d+) bytes, (\d+) omitted\)')
            .firstMatch(body);
        expect(refsMatch, isNotNull,
            reason: '引用行可解析（tag=skill）：${body.substring(body.length > 300 ? body.length - 300 : 0)}');
        final ref = refsMatch!.group(1)!;
        final total = int.parse(refsMatch.group(2)!);
        final omitted = int.parse(refsMatch.group(3)!);

        // ---- ③ 外部真值：spill 文件字节 == 信封 total；中段读回逐字节相同 ----
        final spillFile = File(ref.replaceAll('\\', Platform.pathSeparator));
        // ignore: avoid_print
        print('[OBS] 8.1 ref=$ref total=$total omitted=$omitted');
        expect(spillFile.existsSync(), isTrue,
            reason: '引用必须指向真实文件：$ref');
        final fileBytes = spillFile.readAsBytesSync();
        expect(fileBytes.length, total,
            reason: '信封 total 必须等于文件实际大小（外部真值）');
        expect(omitted, greaterThan(0),
            reason: '~6600 字符正文必然超过 2000 字符预览阈值（判定按字符，spill.cpp L621）');

        final handle = chatState.currentSessionId!;
        // 暗号所在行的字节区间：第二次实测教训——从暗号起点定长读 200 字节会切进
        // 后随中文段的码点中间，read_spill 按规范正确报"区间末尾落在多字节字符中间"
        // （产品没错，是我的读法越界）。改为整行读：行首=前一个 \n 之后，行内全
        // ASCII，落刀在换行边界必是码点边界。
        final fileText = utf8.decode(fileBytes, allowMalformed: true);
        final phraseByteOffset = utf8
            .encode(fileText.substring(0, fileText.indexOf('passphrase is:')))
            .length;
        final nlBefore = fileBytes.lastIndexOf(0x0A, phraseByteOffset) + 1;
        var lineEnd = nlBefore;
        while (lineEnd < fileBytes.length && fileBytes[lineEnd] != 0x0A) {
          lineEnd++;
        }
        final lineLen = lineEnd - nlBefore;
        final midRead = _readSpill(handle, ref, nlBefore, lineLen);
        // ignore: avoid_print
        print('[OBS] 8.1 read_spill 暗号行 ok=${midRead.ok} offset=$nlBefore '
            'len=$lineLen err=${midRead.error}');
        expect(midRead.ok, isTrue,
            reason: '本上下文读自己的引用必须放行：${midRead.error}');
        final expectWindow = utf8.decode(fileBytes.sublist(nlBefore, lineEnd));
        expect(midRead.text, expectWindow,
            reason: '读回的区间必须与文件对应区间逐字节一致（外部真值）');
        expect(midRead.text, contains(_kPassphrase),
            reason: '按引用必须能读回藏着暗号的那一行');
        // 反向钉：暗号被省略在中间段，模型可见的预览正文里**不该**有它——
        // 模型要答对只能真的调 read_spill，没有第二条路。
        expect(body, isNot(contains(_kPassphrase)),
            reason: '暗号在头尾预览之外（在 body 里说明 omitted 计数是假的）');

        // ---- ④ 端到端：模型按引用读回后说出暗号；链路纯净（无作弊工具）----
        expect(seenTools, isNot(contains('run_command')),
            reason: '模型不得用 run_command 绕过技能加载链');
        expect(seenTools, isNot(contains('read_file')),
            reason: '模型不得用 read_file 绕开生效闸门');
        // 最终回答从 state 读（fix-live-test-reply-detection 口径：不扫 widget 树）。
        final reply = readFinalAssistantReply(tester) ?? '';
        // ignore: avoid_print
        print('[OBS] 8.1 finalAssistantReply 长度=${reply.length} '
            '含暗号=${reply.contains(_kPassphrase)}');
        expect(reply, isNotEmpty, reason: '本轮必须有最终回答落地');
        expect(reply, contains(_kPassphrase),
            reason: '模型没读回中段就答不出暗号——答出即端到端闭环');
      } finally {
        await captureLiveShot(tester, captureKey, 'skills_live');
      }
    },
    timeout: const Timeout(Duration(seconds: 540)),
  );
}
