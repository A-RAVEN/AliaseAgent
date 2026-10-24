import 'dart:typed_data';

/// 图片格式与像素尺寸判定（Dart 侧，给"拼请求"用）。
///
/// C++ 那边 `sidecar/src/image_probe.cpp` 有一份同样职责的实现（给 `read_image`
/// 工具用）。两份都存在的理由：工具在工作区里由 sidecar 读，而拼请求时 Dart 手里
/// 只有路径，不能为了问一句宽高再穿一次 FFI 调工具。
///
/// 判定一律看**字节**，不看扩展名 —— 官方原话是"格式由文件实际内容判断，而非文件名
/// 或声明的 MIME 类型"（`Docs/DeepSeekAPIDoc.md` §6.4）。
enum ImageFormat { unknown, png, jpeg, gif, webp }

/// 一次判定结果。`format == unknown` 时其余字段没有意义。
class ImageInfo {
  final ImageFormat format;
  final int width;
  final int height;
  final int bytes;

  const ImageInfo({
    required this.format,
    required this.width,
    required this.height,
    required this.bytes,
  });

  bool get ok => format != ImageFormat.unknown && width > 0 && height > 0;

  /// 请求里 `image.source.media_type` 该填什么；认不出时为空串。
  String get mediaType => switch (format) {
        ImageFormat.png => 'image/png',
        ImageFormat.jpeg => 'image/jpeg',
        ImageFormat.gif => 'image/gif',
        ImageFormat.webp => 'image/webp',
        ImageFormat.unknown => '',
      };
}

/// 从**整个文件的字节**里判格式并取宽高（只读头部，不解像素）。
///
/// 取不到尺寸时返回 `ImageInfo(format: 认出的格式或 unknown, width: 0, height: 0)`；
/// 调用方用 [ImageInfo.ok] 判断能不能发。
ImageInfo probeImageBytes(Uint8List bytes) {
  final format = _formatOf(bytes);
  if (format == ImageFormat.unknown) {
    return ImageInfo(format: format, width: 0, height: 0, bytes: bytes.length);
  }
  final size = switch (format) {
    ImageFormat.png => _pngSize(bytes),
    ImageFormat.jpeg => _jpegSize(bytes),
    ImageFormat.gif => _gifSize(bytes),
    ImageFormat.webp => _webpSize(bytes),
    ImageFormat.unknown => (0, 0),
  };
  return ImageInfo(
    format: format,
    width: size.$1,
    height: size.$2,
    bytes: bytes.length,
  );
}

ImageFormat _formatOf(Uint8List b) {
  if (b.length >= 8 &&
      b[0] == 0x89 &&
      b[1] == 0x50 &&
      b[2] == 0x4E &&
      b[3] == 0x47 &&
      b[4] == 0x0D &&
      b[5] == 0x0A &&
      b[6] == 0x1A &&
      b[7] == 0x0A) {
    return ImageFormat.png;
  }
  if (b.length >= 3 && b[0] == 0xFF && b[1] == 0xD8 && b[2] == 0xFF) {
    return ImageFormat.jpeg;
  }
  if (b.length >= 6 &&
      b[0] == 0x47 && // G
      b[1] == 0x49 && // I
      b[2] == 0x46 && // F
      b[3] == 0x38 && // 8
      (b[4] == 0x37 || b[4] == 0x39)) {
    return ImageFormat.gif;
  }
  if (b.length >= 12 &&
      b[0] == 0x52 && // R
      b[1] == 0x49 && // I
      b[2] == 0x46 && // F
      b[3] == 0x46 && // F
      b[8] == 0x57 && // W
      b[9] == 0x45 && // E
      b[10] == 0x42 && // B
      b[11] == 0x50) {
    return ImageFormat.webp;
  }
  return ImageFormat.unknown;
}

int _be32(Uint8List b, int o) =>
    (b[o] << 24) | (b[o + 1] << 16) | (b[o + 2] << 8) | b[o + 3];

int _le16(Uint8List b, int o) => b[o] | (b[o + 1] << 8);

int _le24(Uint8List b, int o) => b[o] | (b[o + 1] << 8) | (b[o + 2] << 16);

int _le32(Uint8List b, int o) =>
    b[o] | (b[o + 1] << 8) | (b[o + 2] << 16) | (b[o + 3] << 24);

/// PNG：8 字节签名之后就是 IHDR，宽度/高度各 4 字节大端。
(int, int) _pngSize(Uint8List b) {
  if (b.length < 24) return (0, 0);
  return (_be32(b, 16), _be32(b, 20));
}

/// GIF：逻辑屏幕描述符里的宽高各 2 字节小端。
(int, int) _gifSize(Uint8List b) {
  if (b.length < 10) return (0, 0);
  return (_le16(b, 6), _le16(b, 8));
}

/// JPEG：一路找 SOFn（0xFFC0..0xFFCF，排除 C4/C8/CC），其载荷里高在 +5、宽在 +7。
(int, int) _jpegSize(Uint8List b) {
  var i = 2; // 跳过 SOI
  while (i + 9 < b.length) {
    if (b[i] != 0xFF) {
      i++;
      continue;
    }
    final marker = b[i + 1];
    if (marker == 0xFF) {
      i++;
      continue;
    }
    if (marker == 0xD8 || marker == 0xD9 ||
        (marker >= 0xD0 && marker <= 0xD7) || marker == 0x01) {
      i += 2;
      continue;
    }
    final length = (b[i + 2] << 8) | b[i + 3];
    if (length < 2) return (0, 0);
    final isSof = marker >= 0xC0 &&
        marker <= 0xCF &&
        marker != 0xC4 &&
        marker != 0xC8 &&
        marker != 0xCC;
    if (isSof) {
      if (i + 9 >= b.length) return (0, 0);
      final h = (b[i + 5] << 8) | b[i + 6];
      final w = (b[i + 7] << 8) | b[i + 8];
      return (w, h);
    }
    i += 2 + length;
  }
  return (0, 0);
}

/// WebP：RIFF 容器里第一个认得的块决定尺寸。
///   VP8X: 宽-1 在 +4（3 字节 LE），高-1 在 +7
///   VP8 : 起始码 9D 01 2A 在 +3，宽在 +6（LE16 低 14 位）、高在 +8
///   VP8L: 0x2F 签名在 +0，其后 14 位宽-1、再 14 位高-1
(int, int) _webpSize(Uint8List b) {
  var pos = 12;
  while (pos + 8 <= b.length) {
    final id = String.fromCharCodes(b.sublist(pos, pos + 4));
    final chunkLen = _le32(b, pos + 4);
    final data = pos + 8;
    final avail = b.length - data;
    if (id == 'VP8X') {
      if (avail < 10) return (0, 0);
      return (1 + _le24(b, data + 4), 1 + _le24(b, data + 7));
    }
    if (id == 'VP8 ') {
      if (avail < 10) return (0, 0);
      if (b[data + 3] != 0x9D || b[data + 4] != 0x01 || b[data + 5] != 0x2A) {
        return (0, 0);
      }
      final w = _le16(b, data + 6) & 0x3FFF;
      final h = _le16(b, data + 8) & 0x3FFF;
      return (w, h);
    }
    if (id == 'VP8L') {
      if (avail < 5) return (0, 0);
      if (b[data] != 0x2F) return (0, 0);
      final bits = _le32(b, data + 1);
      final w = 1 + (bits & 0x3FFF);
      final h = 1 + ((bits >> 14) & 0x3FFF);
      return (w, h);
    }
    if (chunkLen == 0) return (0, 0);
    pos += 8 + chunkLen + (chunkLen & 1);
  }
  return (0, 0);
}
