#ifndef IMAGE_PROBE_H
#define IMAGE_PROBE_H

#include <cstddef>
#include <string>

// 图片格式与尺寸判定。
//
// 判定一律看**字节**：官方原话是「格式由文件实际内容判断，而非文件名或声明的
// MIME 类型」（Docs/DeepSeekAPIDoc.md §6.4）。扩展名只用于两件事：先把明显不是
// 图片的路径挡掉，以及跟实际格式对账（扩展名声明的和字节实际的对不上就报错）。
namespace image_probe {

/// 受支持的四种格式。取值顺序不重要，kUnknown 表示"不是这四种之一"。
enum class Format {
  kUnknown = 0,
  kPng,
  kJpeg,
  kGif,
  kWebp,
};

/// 扩展名声明的格式；表外（`.txt`、无扩展名）返回 kUnknown。
/// 只认 `.png` / `.jpg` / `.jpeg` / `.webp` / `.gif`，大小写不敏感。
Format format_for_extension(const std::string& path);

/// 字节前缀实际是哪种格式；认不出返回 kUnknown。`len` 小于 12 也照样安全。
Format format_for_magic(const unsigned char* data, size_t len);

/// 媒体类型字符串（`image/png` / `image/jpeg` / `image/gif` / `image/webp`）；
/// kUnknown 返回空串。
std::string media_type(Format format);

/// 图片的像素尺寸。取不到时 width / height 都保持 0。
struct Size {
  int width = 0;
  int height = 0;
  bool ok() const { return width > 0 && height > 0; }
};

/// 从**整个文件的字节**里取宽高（只读头部，不解像素）。
/// PNG / JPEG / GIF 走 stb_image 的 `stbi_info_from_memory`；
/// WebP 不用 stb（它不支持 WebP），改为手写解析 RIFF 容器里的
/// VP8X / VP8 / VP8L 三种块头。
Size dimensions(const std::string& bytes);

}  // namespace image_probe

#endif  // IMAGE_PROBE_H
