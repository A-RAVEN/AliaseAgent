import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';

import 'package:alias_agent/models/tool_call_activity.dart';

void main() {
  group('ToolCallActivity.fromJson', () {
    test('name key fallback for legacy data', () {
      final json = <String, dynamic>{
        'id': 'tc1',
        'name': 'read_file',
        'input': {'path': '/test.txt'},
        'status': 'done',
        'result': 'file content',
        'resultPreview': 'file content',
      };
      final activity = ToolCallActivity.fromJson(json);
      expect(activity.toolName, 'read_file');
    });

    test('toolName key takes priority over name', () {
      final json = <String, dynamic>{
        'id': 'tc1',
        'name': 'old_name',
        'toolName': 'read_file',
        'input': {'path': '/test.txt'},
        'status': 'done',
      };
      final activity = ToolCallActivity.fromJson(json);
      expect(activity.toolName, 'read_file');
    });

    test('toolName key in new format', () {
      final json = <String, dynamic>{
        'id': 'tc1',
        'toolName': 'web_search',
        'input': {'query': 'test'},
        'status': 'done',
        'result': 'search results',
        'resultPreview': 'search...',
      };
      final activity = ToolCallActivity.fromJson(json);
      expect(activity.toolName, 'web_search');
    });

    test('resultSections deserialized correctly', () {
      final json = <String, dynamic>{
        'id': 'tc1',
        'toolName': 'web_search',
        'input': {'query': 'test'},
        'status': 'done',
        'resultSections': [
          {
            'label': 'search-prime',
            'items': [
              {
                'title': 'Result 1',
                'url': 'https://example.com',
                'content': 'Content snippet',
              },
            ],
          },
        ],
      };
      final activity = ToolCallActivity.fromJson(json);
      expect(activity.resultSections, isNotNull);
      expect(activity.resultSections!.length, 1);
      expect(activity.resultSections![0].label, 'search-prime');
      expect(activity.resultSections![0].items.length, 1);
      expect(activity.resultSections![0].items[0].title, 'Result 1');
      expect(activity.resultSections![0].items[0].url, 'https://example.com');
    });

    test('missing resultSections is null', () {
      final json = <String, dynamic>{
        'id': 'tc1',
        'toolName': 'read_file',
        'input': {'path': '/test.txt'},
        'status': 'done',
      };
      final activity = ToolCallActivity.fromJson(json);
      expect(activity.resultSections, isNull);
    });

    test('missing both toolName and name defaults to unknown', () {
      final json = <String, dynamic>{
        'id': 'tc1',
        'input': {'path': '/test.txt'},
        'status': 'done',
      };
      final activity = ToolCallActivity.fromJson(json);
      expect(activity.toolName, 'unknown');
    });
  });

  group('ToolCallActivity.toJson round-trip', () {
    test('resultSections survive serialization round-trip', () {
      final original = ToolCallActivity(
        id: 'tc1',
        toolName: 'web_search',
        input: {'query': 'test'},
        status: ToolCallStatus.done,
        resultSections: [
          ResultSection(
            label: 'search-prime',
            items: [
              ResultItem(
                title: 'Result 1',
                url: 'https://example.com',
                content: 'Content',
              ),
            ],
          ),
        ],
      );
      final json = original.toJson();
      final restored = ToolCallActivity.fromJson(json);
      expect(restored.resultSections, isNotNull);
      expect(restored.resultSections!.length, 1);
      expect(restored.resultSections![0].items[0].title, 'Result 1');
    });
  });

  group('edit hunks', () {
    test('hunks survive a serialization round-trip', () {
      final original = ToolCallActivity(
        id: 'tc2',
        toolName: 'edit_file',
        input: {'path': 'a.txt'},
        status: ToolCallStatus.done,
        hunks: const [
          EditHunk(startLine: 3, oldText: 'old three', newText: 'new three'),
          EditHunk(startLine: 40, oldText: 'old forty', newText: 'new forty'),
        ],
      );
      final restored = ToolCallActivity.fromJson(original.toJson());
      expect(restored.hunks, isNotNull);
      expect(restored.hunks!.length, 2);
      expect(restored.hunks![0].startLine, 3);
      expect(restored.hunks![0].oldText, 'old three');
      expect(restored.hunks![0].newText, 'new three');
      expect(restored.hunks![1].startLine, 40);
      expect(restored.hunks![1].oldText, 'old forty');
      expect(restored.hunks![1].newText, 'new forty');
    });

    test('an old record without hunks deserializes to null', () {
      final json = <String, dynamic>{
        'id': 'tc2',
        'toolName': 'edit_file',
        'input': {'path': 'a.txt'},
        'status': 'done',
        'result': 'Edited a.txt (1 replacement)',
      };
      final activity = ToolCallActivity.fromJson(json);
      expect(activity.hunks, isNull);
      expect(activity.hunksOmitted, isNull);
    });

    test('a null hunks list is not written into toJson', () {
      const activity = ToolCallActivity(
        id: 'tc3',
        toolName: 'read_file',
        input: {'path': 'a.txt'},
      );
      expect(activity.toJson().containsKey('hunks'), isFalse);
      expect(activity.toJson().containsKey('hunksOmitted'), isFalse);
    });

    test('the omission marker survives a round-trip', () {
      const original = ToolCallActivity(
        id: 'tc4',
        toolName: 'edit_file',
        input: {'path': 'big.txt'},
        status: ToolCallStatus.done,
        hunksOmitted: 'too large',
      );
      final restored = ToolCallActivity.fromJson(original.toJson());
      expect(restored.hunksOmitted, 'too large');
      expect(restored.hunks, isNull);
    });
  });

  group('image（add-image-input 10.4 / 11.2）', () {
    test('11.2：imagePath 写进 toJson、能被 fromJson 读回，copyWith 也带得动', () {
      const original = ToolCallActivity(
        id: 'tc-img',
        toolName: 'read_image',
        input: {'path': 'pic.png'},
        status: ToolCallStatus.done,
        result: '<path>pic.png</path>',
        imagePath: 'C:/tmp/pic.png',
      );
      final json = original.toJson();
      expect(json['image'], {'path': 'C:/tmp/pic.png'});

      final restored = ToolCallActivity.fromJson(json);
      expect(restored.imagePath, 'C:/tmp/pic.png');

      final copied = original.copyWith(result: 'new result');
      expect(copied.imagePath, 'C:/tmp/pic.png',
          reason: 'copyWith 不该把图片路径弄丢（工具结果回填时就是这么复制的）');
    });

    test('11.2：没有图时不写这个键，老数据读出来是 null', () {
      const plain = ToolCallActivity(
        id: 'tc-plain', toolName: 'read_file', input: {'path': 'a.txt'},
        status: ToolCallStatus.done,
      );
      expect(plain.toJson().containsKey('image'), isFalse);

      final legacy = ToolCallActivity.fromJson(<String, dynamic>{
        'id': 'tc-old',
        'toolName': 'read_file',
        'input': {'path': 'a.txt'},
        'status': 'done',
      });
      expect(legacy.imagePath, isNull);
    });

    test('10.4：落库的 tool_calls JSON 里 image 只有一个 path 键，没有任何元数据', () {
      const activity = ToolCallActivity(
        id: 'tc-img',
        toolName: 'read_image',
        input: {'path': 'pic.png'},
        status: ToolCallStatus.done,
        result: '<path>pic.png</path>\n<type>image</type>\n<content>\n'
            'image/png image, 4x3 px, 98 bytes\n</content>',
        imagePath: 'C:/tmp/pic.png',
      );
      // 这一串就是写进 messages.tool_calls 的那段文本
      final persisted = jsonEncode([activity.toJson()]);
      final decoded = (jsonDecode(persisted) as List).first as Map<String, dynamic>;
      final image = decoded['image'] as Map<String, dynamic>;

      expect(image.keys.toList(), ['path'],
          reason: '库里只许存路径：宽高/媒体类型/字节数一个都不许有');
      for (final forbidden in ['width', 'height', 'media_type', 'bytes']) {
        expect(image.containsKey(forbidden), isFalse);
      }
      expect(image['path'], 'C:/tmp/pic.png');
    });
  });
}
