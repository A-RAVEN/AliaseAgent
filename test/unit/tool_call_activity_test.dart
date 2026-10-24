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
}
