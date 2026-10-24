import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'image_probe.dart';

/// 一张图片在请求里的两样东西：给模型看的说明文本，和真正的 `image` 块。
class ImageRequestParts {
  /// 说明文本。**总是有**：
  ///
  /// - 成功时写清路径、媒体类型、像素宽高、字节数（模型事后想再引用这个文件，
  ///   靠的就是这里的路径 —— `image` 块自己不带路径）；
  /// - 失败时是一句可见的标记，告诉模型"这里本来有张图，但它不在了/读不出来"。
  final String note;

  /// 要发给模型的 `image` 块；null 表示这一张没发出去（只有 [note]）。
  final Map<String, dynamic>? block;

  /// 读出这张图时拿到的元信息（宽高/字节数/媒体类型）；失败时为 null。
  ///
  /// 请求级图片预算（`image_budget.dart`）要拿它做上限判断，说明文本里的那些数字
  /// 也来自它 —— 所以不在别处再解析一遍。
  final ImageInfo? info;

  const ImageRequestParts({required this.note, this.block, this.info});
}

/// 读一张图并备好请求里要用的东西。
///
/// @param path  绝对路径（用户贴进来的图，或 `read_image` 描述过的文件）
/// @param index 这条消息里它是第几张（从 1 开始），只用于说明文本
///
/// 失败一律**降级成可见文本**而不是跳过：文件不在 → `[图片已丢失：<path>]`；
/// 读不出来或认不出格式 → 一句说明它为什么读不出来的标记。静默少发一张图是缺陷。
ImageRequestParts buildImageRequestParts(String path, {int index = 1}) {
  Uint8List bytes;
  try {
    bytes = File(path).readAsBytesSync();
  } on FileSystemException {
    return ImageRequestParts(note: '[图片已丢失：$path]');
  } catch (_) {
    return ImageRequestParts(note: '[图片已丢失：$path]');
  }

  final info = probeImageBytes(bytes);
  if (!info.ok) {
    return ImageRequestParts(
      note: '[图片 $index 读不出来：$path（不是可识别的 PNG/JPEG/GIF/WebP，'
          '或文件头已损坏）]',
    );
  }

  return ImageRequestParts(
    note: '[图片 $index：${info.mediaType}，${info.width}x${info.height}px，'
        '${info.bytes} 字节，路径：$path]',
    info: info,
    block: {
      'type': 'image',
      'source': {
        'type': 'base64',
        'media_type': info.mediaType,
        'data': base64Encode(bytes),
      },
    },
  );
}
