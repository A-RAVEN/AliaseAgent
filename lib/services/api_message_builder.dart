// 把 `Message` 行序列装配成**实际的** `messages` 请求体（change `agent-group-chat`
// 任务 3.1~3.6；从 `Agent._buildApiMessages` 原样抽出，行为逐字不变）。
//
// 抽出来的理由（design D2 / D9）：成员视图的装配必须与单会话共用**同一份** replay
// 实现 —— thinking 回放、`tool_calls` → `tool_use`、紧随其后的合成 user(tool_result)、
// 近区超长 tool_result 裁剪、图片块拼装都在这里。投影只决定"哪些行进视图、别人说的
// 话以什么身份进"，不复制 replay 逻辑。
//
// 输出形状只有 `role` + `content` 两个键（Anthropic `MessageParam` 的事实形态，
// `Docs/AnthropicAPIDoc.md` §1.3.2）—— 归属只能进正文，不能依赖 `name` 字段。
import 'dart:convert';

import '../models/message.dart';
import 'image_budget.dart';
import 'image_request.dart';
import 'logging.dart';
import 'skills/skill_catalog_service.dart';
import 'slash_commands.dart';
import 'tool_result_text.dart';

/// 工具调用结果里的图片附件路径（`image.path`）；没有就返回 null。
String? toolImagePath(Map<String, dynamic> source) {
  final image = source['image'];
  if (image is! Map) return null;
  final path = image['path'];
  return path is String && path.isNotEmpty ? path : null;
}

/// 一条工具结果交给模型的内容（纯文本，或带图片块 / 明确"图片未发送"提示的块列表）。
Object toolResultContent({
  required String text,
  required String? imagePath,
  required bool acceptsImages,
  required String model,
}) {
  if (imagePath == null) return text;
  final blocks = <Map<String, dynamic>>[
    {'type': 'text', 'text': text},
  ];
  final parts = buildImageRequestParts(imagePath);
  if (parts.block == null) {
    blocks.add({'type': 'text', 'text': parts.note});
  } else if (!acceptsImages) {
    blocks.add({
      'type': 'text',
      'text': '[图片未发送：当前模型 $model 未声明图片输入'
          '（input_modalities 不含 image）；图片路径：$imagePath]',
    });
  } else {
    blocks.add(parts.block!);
  }
  return blocks;
}

/// Strip the internal `index` key from a thinking block before persisting
/// or replaying it to the API.
Map<String, dynamic> thinkingBlockWithoutIndex(Map<String, dynamic> th) {
  if (!th.containsKey('index')) return th;
  final cleaned = Map<String, dynamic>.from(th)..remove('index');
  return cleaned;
}

/// 装配一份请求体。[messages] 是**视图序列**（单会话 = 原始行序列）。
List<Map<String, dynamic>> buildApiMessages(
  List<Message> messages, {
  required bool acceptsImages,
  required String model,
}) {
  final apiMessages = <Map<String, dynamic>>[];
  final emittedToolUseIds = <String>{};
  final imagesAllowed = acceptsImages;
  final modelName = model;
  // 当轮生效技能名：在逐条循环**外**取一次、循环内复用（design D2；禁止缓存到
  // Agent 字段或构造期快照 —— 当轮语义由每轮开头的 `scan()` + getter 保证）。
  //
  // 成员视图与单会话共用本入口（压缩投影对每个原文段各调一次），所以投影里的历史
  // user 消息一并按当轮集合展开；这正是 spec「进入本次请求的每一条 user 消息」的
  // 实现点。压缩折叠进摘要的消息到不了这里，属压缩能力的既定损失（design D2 范围限定）。
  final activeNames = SkillCatalogService.instance.activeSkillNames;

  final preparedByMsg = <int, List<ImageRequestParts>>{};
  final planned = <PlannedImage>[];
  for (var mi = 0; mi < messages.length; mi++) {
    final msg = messages[mi];
    if (msg.role != 'user' || msg.attachments.isEmpty) continue;
    final partsList = <ImageRequestParts>[];
    for (var j = 0; j < msg.attachments.length; j++) {
      final parts = buildImageRequestParts(msg.attachments[j], index: j + 1);
      partsList.add(parts);
      planned.add(PlannedImage(path: msg.attachments[j], parts: parts));
    }
    preparedByMsg[mi] = partsList;
  }
  final omissions = planImageOmissions(planned);
  final omittedByMsg = <int, List<String?>>{};
  var planCursor = 0;
  for (final entry in preparedByMsg.entries) {
    final notes = List<String?>.filled(entry.value.length, null);
    for (var j = 0; j < entry.value.length; j++) {
      notes[j] = omissions[planCursor++];
    }
    omittedByMsg[entry.key] = notes;
  }

  for (var mi = 0; mi < messages.length; mi++) {
    final msg = messages[mi];
    final content = <Map<String, dynamic>>[];
    if (msg.content.isNotEmpty) {
      // 斜杠技能展开的唯一接线点（design D1/D2）：只对 `Message` 行
      // `role == 'user'` 的正文生效，assistant 消息原样。
      //
      // 落库 / 会话标题 / 对话视图气泡都发生在装配**之前**（`_sendMessageRound`
      // 里的 `messageRepo.insert` / `updateTitleIfDefault` 用的就是手打原文），
      // 天然不受影响。**禁止**在工具轮或装配后的 apiMessages 层做替换：那里
      // role=='user' 的条目可能是 tool_result 块列表（content 是 List 而不是 String），
      // 会被误改写。
      //
      // 成员视图里"他人的公开回复"是合成 user 行、正文以「Y 说：」开头，不会以 `/`
      // 起头，所以斜杠展开不会误伤它。
      final text = msg.role == 'user'
          ? expandSlashCommand(msg.content, activeNames)
          : msg.content;
      content.add({'type': 'text', 'text': text});
    }

    if (msg.role == 'user' && msg.attachments.isNotEmpty) {
      final partsList = preparedByMsg[mi]!;
      final omitted = omittedByMsg[mi]!;
      for (var i = 0; i < msg.attachments.length; i++) {
        final path = msg.attachments[i];
        final parts = partsList[i];
        final omission = omitted[i];
        if (omission != null) {
          content.add({'type': 'text', 'text': omission});
        } else if (parts.block == null) {
          content.add({'type': 'text', 'text': parts.note});
        } else if (!imagesAllowed) {
          content.add({
            'type': 'text',
            'text': '[图片未发送：当前模型 $modelName 未声明图片输入'
                '（input_modalities 不含 image）；图片路径：$path]',
          });
        } else {
          content.add({'type': 'text', 'text': parts.note});
          content.add(parts.block!);
        }
      }
    }

    if (msg.role == 'assistant' &&
        msg.thinkingJson != null &&
        msg.thinkingJson!.isNotEmpty) {
      try {
        final thinkingBlocks = jsonDecode(msg.thinkingJson!) as List<dynamic>;
        content.insertAll(
            0,
            thinkingBlocks.map((b) => thinkingBlockWithoutIndex(
                b as Map<String, dynamic>)));
      } catch (e) {
        debugPrint('[AliasAgent] Failed to parse thinkingJson: $e');
      }
    }

    var ownedToolCalls = const <Map<String, dynamic>>[];
    if (msg.role == 'assistant' &&
        msg.toolCallsJson != null &&
        msg.toolCallsJson!.isNotEmpty) {
      try {
        final toolCalls = jsonDecode(msg.toolCallsJson!) as List<dynamic>;
        ownedToolCalls = <Map<String, dynamic>>[];
        for (final tc in toolCalls) {
          final id = ((tc as Map<String, dynamic>)['id'] ?? '').toString();
          if (id.isEmpty || emittedToolUseIds.add(id)) {
            ownedToolCalls.add(tc);
          }
        }
      } catch (e) {
        debugPrint('[AliasAgent] Failed to parse toolCallsJson: $e');
        ownedToolCalls = const [];
      }
    }

    for (final tc in ownedToolCalls) {
      content.add({
        'type': 'tool_use',
        'id': tc['id'] ?? '',
        'name': tc['toolName'] ?? tc['name'] ?? '',
        'input': tc['input'] ?? {},
      });
    }

    apiMessages.add({'role': msg.role, 'content': content});

    if (ownedToolCalls.isNotEmpty) {
      try {
        final toolResults = <Map<String, dynamic>>[];
        for (final tc in ownedToolCalls) {
          final rawBody = (tc['result'] ?? tc['resultPreview'] ?? '').toString();
          final tcInput = (tc['input'] as Map<String, dynamic>?) ?? const {};
          final toolName = (tc['toolName'] ?? tc['name'] ?? '').toString();
          final refetchPath = (tcInput['path'] as String?) ?? '';
          final refetchUrl = (tcInput['url'] as String?) ?? '';
          final refetchArg = refetchPath.isNotEmpty
              ? refetchPath
              : (refetchUrl.isNotEmpty ? refetchUrl : '');
          // spawn_subagent 的最终结论**完整**重放：不套通用省略规则。
          // 其它工具继续沿用既有截断与取回规则（见 tool_result_text.dart）。
          final body = toolName == 'spawn_subagent'
              ? rawBody
              : elideOversizedToolResult(
                  name: toolName, path: refetchArg, body: rawBody);
          toolResults.add({
            'type': 'tool_result',
            'tool_use_id': tc['id'] ?? '',
            'content': toolResultContent(
              text: body,
              imagePath: toolImagePath(tc),
              acceptsImages: imagesAllowed,
              model: modelName,
            ),
          });
        }
        apiMessages.add({'role': 'user', 'content': toolResults});
      } catch (e) {
        debugPrint('[AliasAgent] Failed to build tool_results: $e');
      }
    }
  }
  return apiMessages;
}
