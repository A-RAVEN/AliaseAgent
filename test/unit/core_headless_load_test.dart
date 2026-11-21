// 纯 Dart VM 可加载性守卫（change `web-ui-core-shim` 任务 1.3）。
//
// 本文件**故意不 import `package:flutter` / `package:flutter_test`**：
//   dart test test/unit/core_headless_load_test.dart
// 走纯 VM 编译器。解耦前，核心 services + models 传递 import
// `package:flutter/foundation.dart`（→ dart:ui），这条命令会编译失败；解耦后必须变绿。
//
// 同时覆盖：debugPrint shim 与 foundation 同签名、可重赋值、核心代码输出可观察；
// 核心 services/models 能在无 Flutter 引擎的上下文里实例化。
import 'dart:io';

import 'package:test/test.dart';

import 'package:alias_agent/models/agent_type_config.dart';
import 'package:alias_agent/models/app_config.dart';
import 'package:alias_agent/models/message.dart';
import 'package:alias_agent/models/model_catalog_entry.dart';
import 'package:alias_agent/models/provider_config.dart';
import 'package:alias_agent/models/resolved_agent_config.dart';
import 'package:alias_agent/services/agent.dart';
import 'package:alias_agent/services/agent_config_resolver.dart';
import 'package:alias_agent/services/agent_factory.dart';
import 'package:alias_agent/services/agent_registry.dart';
import 'package:alias_agent/services/agent_type_registry.dart';
import 'package:alias_agent/services/compaction/guard_anchors.dart';
import 'package:alias_agent/services/compaction/model_summary_provider.dart';
import 'package:alias_agent/services/logging.dart' as logging;
import 'package:alias_agent/services/message_repository.dart';
import 'package:alias_agent/services/provider_resolver.dart';
import 'package:alias_agent/services/session_repository.dart';
import 'package:alias_agent/services/sidecar_bridge.dart' show ISidecar;
import 'package:alias_agent/services/skills/skill_catalog_service.dart';
import 'package:alias_agent/services/subagent_runner.dart';
import 'package:alias_agent/services/summary_node_repository.dart';

/// 纯加载测试不碰真实 sidecar：任何调用都当测试缺陷炸出来（不静默返回假数据）。
class _NoSidecar implements ISidecar {
  @override
  dynamic noSuchMethod(Invocation invocation) {
    throw UnsupportedError(
        'headless load test 不应调用 sidecar.${invocation.memberName}');
  }
}

void _obs(String label, Object? value) {
  // ignore: avoid_print
  print('[OBS] $label: $value');
}

void main() {
  group('无头核心纯 Dart 可加载性', () {
    test('models 可实例化并往返解析', () {
      final agentType = AgentTypeConfig.fromJson('general', {
        'provider': 'p',
        'model': 'm',
        'system_prompt': 'hi',
        'max_context_tokens': 100000,
        'input_modalities': ['text'],
      });
      final provider = ProviderConfig.fromJson({
        'api_key': 'k',
        'base_url': 'http://127.0.0.1:1',
        'models': [
          {'id': 'm', 'context_window': 100000},
        ],
      });
      final catalog = ModelCatalogEntry.fromJson({'id': 'm'});
      final message = Message.fromRow({
        'id': 'msg-1',
        'session_id': 's-1',
        'role': 'user',
        'content': 'hello',
        'created_at': 1,
      });
      final config = AppConfig.fromJson({
        'version': 1,
        'providers': {
          'p': {'api_key': 'k', 'base_url': 'http://127.0.0.1:1'},
        },
        'agent_types': {
          'general': {
            'provider': 'p',
            'model': 'm',
            'system_prompt': '',
            'max_context_tokens': 100000,
          },
        },
      });
      _obs('agentType', agentType.toJson());
      _obs('provider', provider.toJson());
      _obs('catalog', catalog?.toJson());
      _obs('message', message.toRow());
      _obs('config.agentTypes', config.agentTypes.keys.toList());

      expect(agentType.name, 'general');
      expect(provider.models.single.id, 'm');
      expect(catalog!.id, 'm');
      expect(message.attachments, isEmpty);
      expect(config.agentTypes['general']!.model, 'm');
    });

    test('核心 services 可实例化：解析器/摘要/子运行/工厂/Agent', () async {
      const template = AgentTypeConfig(
        name: 'general',
        provider: 'p',
        model: 'm',
        systemPrompt: '',
        maxContextTokens: 100000,
      );
      final appConfig = AppConfig(
        version: 1,
        providers: const {
          'p': ProviderConfig(apiKey: 'k', baseUrl: 'http://127.0.0.1:1'),
        },
        agentTypes: const {'general': template},
      );
      final providers = ProviderResolver(appConfig);
      final resolved = AgentConfigResolver(providers).resolve(
        template: template,
        spillPreviewChars: appConfig.spillPreviewChars,
      );
      _obs('resolved', resolved.toJson());
      expect(resolved, isA<ResolvedAgentConfig>());
      expect(resolved.compactionThresholdTokens,
          resolved.maxContextTokens * resolved.compactionThresholdPercent ~/ 100);

      final sidecar = _NoSidecar();
      final summary = ModelSummaryProvider(sidecar: sidecar, resolver: providers);
      final templates = AgentTypeRegistry()..register(template);
      final agents = AgentRegistry();
      final sessionRepo = SessionRepository();
      final messageRepo = MessageRepository();
      final summaryRepo = SummaryNodeRepository();
      late final AgentFactory factory;
      final runner = SubagentRunner(factory: () => factory, sidecar: sidecar);
      factory = AgentFactory(
        templates: templates,
        providerResolver: () => providers,
        config: appConfig,
        sidecar: sidecar,
        sessionRepo: sessionRepo,
        messageRepo: messageRepo,
        summaryNodeRepo: summaryRepo,
        registry: agents,
        summaryProvider: summary,
        seamSelector: null,
        guard: GuardAnchors(),
        backgroundFoldEnabled: false,
        summaryStoreOpen: () => true,
        subagentRunner: runner,
      );
      final agent = Agent(
        sessionId: 's-1',
        agentTypeName: 'general',
        config: resolved,
        template: template,
        provider: providers.resolve('p')!,
        sessionRepo: sessionRepo,
        messageRepo: messageRepo,
        summaryNodeRepo: summaryRepo,
        sidecar: sidecar,
        summaryProvider: summary,
        seamSelector: null,
        guard: GuardAnchors(),
        backgroundFoldEnabled: false,
        summaryStoreOpen: true,
        subagentRunner: runner,
      );
      _obs('agent', '${agent.sessionId}/${agent.agentTypeName} '
          'toolDefinitions=${agent.toolDefinitions.length}');
      expect(factory, isA<AgentFactory>());
      expect(agent.messageHistory, isEmpty);
      expect(agent.isStreaming, isFalse);
    });

    test('SkillCatalogService 在纯 Dart 下可扫描并给出逐条失败明细', () async {
      final tmp = Directory.systemTemp.createTempSync('alias_headless_skill_');
      try {
        // 子目录缺 SKILL.md ⇒ 一条失败明细（proves 扫描真的读了文件系统）。
        Directory('${tmp.path}${Platform.pathSeparator}bad-skill').createSync();
        final captured = <String?>[];
        final original = logging.debugPrint;
        logging.debugPrint = (String? message, {int? wrapWidth}) {
          captured.add(message);
        };
        try {
          await SkillCatalogService.instance.scan(rootPath: tmp.path);
        } finally {
          logging.debugPrint = original;
        }
        final notices = SkillCatalogService.instance.noticeLines;
        _obs('skill.noticeLines', notices);
        _obs('skill.capturedLog', captured);
        expect(notices.any((line) => line.contains('bad-skill')), isTrue,
            reason: '失败技能必须逐条点名，不能静默消失');
        expect(captured.whereType<String>().join('\n'), contains('技能目录增量刷新'));
      } finally {
        try {
          tmp.deleteSync(recursive: true);
        } catch (_) {
          // Windows 文件锁：临时目录删不掉不影响断言。
        }
      }
    });

    test('debugPrint shim 可重赋值且核心代码输出可观察', () {
      final captured = <String?>[];
      final original = logging.debugPrint;
      logging.debugPrint = (String? message, {int? wrapWidth}) {
        captured.add(message);
      };
      try {
        Message.fromRow({
          'id': 'msg-bad',
          'session_id': 's-1',
          'role': 'user',
          'content': 'x',
          'created_at': 1,
          'attachments': 'not-json',
        });
      } finally {
        logging.debugPrint = original;
      }
      _obs('shim.captured', captured);
      expect(captured, isNotEmpty, reason: 'shim 被替换后核心代码的日志必须进钩子');
      expect(captured.join('\n'), contains('attachments'));
    });
  });
}
