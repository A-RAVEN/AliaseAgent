// 请求级图片预算（add-image-input 任务 10.2）。
//
// 四条用例对应官方 §6.4.3 的四条上限，全部用**构造出来的** `PlannedImage`：
// 不需要真的写一个 40 MiB 的文件，`info.bytes` 就是判据依赖的那个数。
import 'package:flutter_test/flutter_test.dart';

import 'package:alias_agent/services/image_budget.dart';
import 'package:alias_agent/services/image_probe.dart';
import 'package:alias_agent/services/image_request.dart';

/// 造一张"看起来正常"的候选图。`bytes` 只写进 info，不真的占内存。
PlannedImage image(
  String path, {
  int bytes = 4096,
  int width = 800,
  int height = 600,
}) {
  return PlannedImage(
    path: path,
    parts: ImageRequestParts(
      note: '[图片：$path]',
      info: ImageInfo(
        format: ImageFormat.png,
        width: width,
        height: height,
        bytes: bytes,
      ),
      block: {
        'type': 'image',
        'source': {'type': 'base64', 'media_type': 'image/png', 'data': 'AA=='},
      },
    ),
  );
}

void main() {
  test('单张超过 32 MiB：只丢它，其余照发', () {
    final notes = planImageOmissions([
      image('a.png'),
      image('big.png', bytes: 40 * 1024 * 1024),
      image('c.png'),
    ]);
    expect(notes[0], isNull);
    expect(notes[2], isNull);
    expect(notes[1], isNotNull);
    expect(notes[1], contains('big.png'));
    expect(notes[1], contains('33554432'));
    expect(notes[1], contains('${40 * 1024 * 1024} 字节'));
  });

  test('单边超过 8192 像素：只丢它', () {
    final notes = planImageOmissions([
      image('wide.png', width: 9000, height: 100),
      image('ok.png'),
    ]);
    expect(notes[0], isNotNull);
    expect(notes[0], contains('单边上限 8192'));
    expect(notes[0], contains('9000x100'));
    expect(notes[1], isNull);
  });

  test('一次请求含 15 张时单边超过 4096：只丢那一张', () {
    final images = <PlannedImage>[
      // 14 张正常 + 1 张 5000 宽，总数恰好 15
      for (var i = 0; i < 14; i++) image('p$i.png'),
      image('long.png', width: 5000, height: 100),
    ];
    expect(images.length, 15);
    final notes = planImageOmissions(images);
    expect(notes.last, isNotNull);
    expect(notes.last, contains('5000x100'));
    expect(notes.last, contains('≥15'));
    expect(notes.last, contains('4096'));
    // 其余 14 张照发
    expect(notes.take(14).where((n) => n != null), isEmpty);
  });

  test('14 张时 5000 宽不算超限（降级只在 ≥15 张时生效）', () {
    final images = <PlannedImage>[
      for (var i = 0; i < 13; i++) image('p$i.png'),
      image('long.png', width: 5000, height: 100),
    ];
    expect(images.length, 14);
    final notes = planImageOmissions(images);
    expect(notes.where((n) => n != null), isEmpty,
        reason: '14 张时单边上限仍是 8192，5000 宽不该被丢');
  });

  test('两张 24 MiB：从最旧的开始丢，剩下的负载不超过 48 MiB', () {
    const one = 24 * 1024 * 1024;
    final notes = planImageOmissions([
      image('old.png', bytes: one),
      image('new.png', bytes: one),
    ]);
    // 两张原图合计 48 MiB（未超 64 MiB 那道门），但 base64 后约 64 MiB
    expect(notes[0], isNotNull, reason: '总量超限时丢的是最旧那张');
    expect(notes[0], contains('old.png'));
    expect(notes[0], contains('50331648'));
    expect(notes[1], isNull, reason: '丢到满足上限就停');

    // 剩下的 base64 负载确实在 48 MiB 以内
    final payload = ((one + 2) ~/ 3) * 4;
    expect(payload, lessThanOrEqualTo(kMaxBase64ImageBytes));
  });

  test('读不出来的图本来就不进请求，不参与预算也不影响别人', () {
    final broken = PlannedImage(
      path: 'missing.png',
      parts: const ImageRequestParts(note: '[图片已丢失：missing.png]'),
    );
    final notes = planImageOmissions([broken, image('ok.png')]);
    expect(notes[0], isNull, reason: '它已经有"图片已丢失"的标记，不该再被省略');
    expect(notes[1], isNull);
  });
}
