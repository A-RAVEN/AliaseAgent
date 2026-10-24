/// 一次请求里的图片该发哪几张（add-image-input，task 10.2）。
///
/// 所有上限都来自官方文档 `Docs/DeepSeekAPIDoc.md` §6.4.3 与 §6.4.1，没有一个是
/// 本项目自己定的：
///
/// | 检查 | 数值 | 出处 |
/// |---|---|---|
/// | 单张字节数 | 33554432（32 MiB） | §6.4.3「单张图片最大大小（base64 / 外部 URL）」 |
/// | 单边像素 | 8192 | §6.4.3「图片最大尺寸」 |
/// | 一次请求图片数 ≥ 15 时单边 | 4096 | §6.4.3 同一行后半句 |
/// | 一次请求的 base64 图片负载 | 50331648（48 MiB） | §6.4.3「请求体大小」+ §6.4.1「编码后的数据会计入 48 MiB 请求体大小限制」 |
///
/// 超限不是整条失败，而是**把那一张换成一句可见的省略说明**：图没了要能看出来，
/// 其余内容照发。总量超限时**从最旧的开始丢**（与 DSH 的 `offloadOldestImages`
/// 同一口径），这样同一段历史每次投影的结果是确定的。
library;

import 'image_request.dart';

/// 单张图片上限：32 MiB（官方「单张图片最大大小」）。
const int kMaxImageBytes = 33554432;

/// 单边像素上限（官方「图片最大尺寸」）。
const int kMaxImageSide = 8192;

/// 一次请求里图片数达到这个值（含）时，单边上限降为 [kMaxImageSideWhenMany]。
const int kManyImagesThreshold = 15;

/// 图片数 ≥ [kManyImagesThreshold] 时的单边上限。
const int kMaxImageSideWhenMany = 4096;

/// 一次请求的 base64 图片负载上限：48 MiB（官方「请求体大小」）。
const int kMaxBase64ImageBytes = 50331648;

/// 一张候选图片：路径 + 已经准备好的请求部件（读失败的那种 `block == null`，
/// 它本来就不会进请求，不参与预算）。
class PlannedImage {
  final String path;
  final ImageRequestParts parts;

  const PlannedImage({required this.path, required this.parts});
}

/// 决定每一张发不发。
///
/// @param images 按**请求里出现的顺序**（最旧的在前）
/// @return 与 [images] 等长的列表：`null` = 照发；非空 = 这一张的省略说明
///         （调用方把它当成文本块放在原位置）
List<String?> planImageOmissions(List<PlannedImage> images) {
  final notes = List<String?>.filled(images.length, null);

  // 只有"读到了、本来要发"的才算进张数
  var liveIndices = <int>[];
  for (var i = 0; i < images.length; i++) {
    if (images[i].parts.block != null && images[i].parts.info != null) {
      liveIndices.add(i);
    }
  }
  final totalImages = liveIndices.length;

  // ---- 单张 / 单边 ----
  final survivors = <int>[];
  for (final i in liveIndices) {
    final info = images[i].parts.info!;
    final path = images[i].path;
    if (info.bytes > kMaxImageBytes) {
      notes[i] = '[图片已省略：$path（${info.bytes} 字节，'
          '单张上限 $kMaxImageBytes 字节）]';
      continue;
    }
    if (info.width > kMaxImageSide || info.height > kMaxImageSide) {
      notes[i] = '[图片已省略：$path（${info.width}x${info.height} 像素，'
          '单边上限 $kMaxImageSide）]';
      continue;
    }
    if (totalImages >= kManyImagesThreshold &&
        (info.width > kMaxImageSideWhenMany || info.height > kMaxImageSideWhenMany)) {
      notes[i] = '[图片已省略：$path（${info.width}x${info.height} 像素，'
          '本次请求图片数 ≥$kManyImagesThreshold 时单边上限 '
          '$kMaxImageSideWhenMany）]';
      continue;
    }
    survivors.add(i);
  }

  // ---- 一次请求的 base64 负载总量：从最旧的开始丢 ----
  var payload = 0;
  for (final i in survivors) {
    payload += _base64Length(images[i].parts.info!.bytes);
  }
  var cursor = 0;
  while (payload > kMaxBase64ImageBytes && cursor < survivors.length) {
    final i = survivors[cursor++];
    payload -= _base64Length(images[i].parts.info!.bytes);
    notes[i] = '[图片已省略：${images[i].path}（本次请求的 base64 图片负载超过 '
        '$kMaxBase64ImageBytes 字节上限）]';
  }

  return notes;
}

/// 原图字节数 → base64 之后的字符数（每 3 字节 4 个字符，末尾补 `=`）。
int _base64Length(int bytes) => ((bytes + 2) ~/ 3) * 4;
