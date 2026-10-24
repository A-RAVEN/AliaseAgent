#include "image_probe.h"

#include <cstdint>
#include <cstring>

// stb_image 的实现只允许出现在一个翻译单元里，就放在这里。
#define STB_IMAGE_IMPLEMENTATION
// 只要头信息与解码能力（测试里回读自己写的 PNG 用到解码）；JPEG/GIF 的解码器
// 留着不裁，免得以后要读整张图时再改宏。
#include <stb_image.h>

namespace image_probe {

namespace {

bool iequals_suffix(const std::string& s, const char* suffix) {
  size_t n = std::strlen(suffix);
  if (s.size() < n) return false;
  for (size_t i = 0; i < n; ++i) {
    char a = s[s.size() - n + i];
    char b = suffix[i];
    if (a >= 'A' && a <= 'Z') a = static_cast<char>(a - 'A' + 'a');
    if (a != b) return false;
  }
  return true;
}

uint32_t le32(const unsigned char* p) {
  return static_cast<uint32_t>(p[0]) | (static_cast<uint32_t>(p[1]) << 8) |
         (static_cast<uint32_t>(p[2]) << 16) | (static_cast<uint32_t>(p[3]) << 24);
}

uint32_t le24(const unsigned char* p) {
  return static_cast<uint32_t>(p[0]) | (static_cast<uint32_t>(p[1]) << 8) |
         (static_cast<uint32_t>(p[2]) << 16);
}

// WebP：RIFF 容器，载荷为 "WEBP"，之后是一串 chunk（4 字节 id + 4 字节 LE 长度 +
// 数据，长度奇数时补 1 字节）。三种承载尺寸的头：
//   VP8X  data[4..6] = 宽-1（LE24），data[7..9] = 高-1（LE24）
//   VP8   data[3..5] = 0x9D 0x01 0x2A，data[6..7] = 宽（LE16，低 14 位有效），
//         data[8..9] = 高（同上）
//   VP8L  data[0] = 0x2F 签名，其后 14 位宽-1、再 14 位高-1（LSB 先）
Size webp_dimensions(const std::string& bytes) {
  Size size;
  if (bytes.size() < 16) return size;
  const unsigned char* base = reinterpret_cast<const unsigned char*>(bytes.data());
  if (std::memcmp(base, "RIFF", 4) != 0 || std::memcmp(base + 8, "WEBP", 4) != 0) {
    return size;
  }
  size_t pos = 12;
  while (pos + 8 <= bytes.size()) {
    const unsigned char* id = base + pos;
    uint32_t chunk_len = le32(base + pos + 4);
    const unsigned char* data = id + 8;
    size_t avail = bytes.size() - pos - 8;
    if (std::memcmp(id, "VP8X", 4) == 0) {
      if (avail < 10) return Size{};
      size.width = 1 + static_cast<int>(le24(data + 4));
      size.height = 1 + static_cast<int>(le24(data + 7));
      return size;
    }
    if (std::memcmp(id, "VP8 ", 4) == 0) {
      if (avail < 10) return Size{};
      if (!(data[3] == 0x9D && data[4] == 0x01 && data[5] == 0x2A)) return Size{};
      size.width = static_cast<int>(data[6] | (data[7] << 8)) & 0x3FFF;
      size.height = static_cast<int>(data[8] | (data[9] << 8)) & 0x3FFF;
      return size;
    }
    if (std::memcmp(id, "VP8L", 4) == 0) {
      if (avail < 5) return Size{};
      if (data[0] != 0x2F) return Size{};
      uint32_t bits = le32(data + 1);
      size.width = 1 + static_cast<int>(bits & 0x3FFF);
      size.height = 1 + static_cast<int>((bits >> 14) & 0x3FFF);
      return size;
    }
    if (chunk_len == 0) return Size{};
    pos += 8 + chunk_len + (chunk_len & 1u);
  }
  return size;
}

}  // namespace

Format format_for_extension(const std::string& path) {
  if (iequals_suffix(path, ".png")) return Format::kPng;
  if (iequals_suffix(path, ".jpg") || iequals_suffix(path, ".jpeg")) return Format::kJpeg;
  if (iequals_suffix(path, ".gif")) return Format::kGif;
  if (iequals_suffix(path, ".webp")) return Format::kWebp;
  return Format::kUnknown;
}

Format format_for_magic(const unsigned char* data, size_t len) {
  if (data == nullptr || len < 4) return Format::kUnknown;
  static const unsigned char kPng[8] = {0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A};
  if (len >= 8 && std::memcmp(data, kPng, 8) == 0) return Format::kPng;
  if (len >= 3 && data[0] == 0xFF && data[1] == 0xD8 && data[2] == 0xFF) return Format::kJpeg;
  if (len >= 6 && (std::memcmp(data, "GIF87a", 6) == 0 || std::memcmp(data, "GIF89a", 6) == 0)) {
    return Format::kGif;
  }
  if (len >= 12 && std::memcmp(data, "RIFF", 4) == 0 && std::memcmp(data + 8, "WEBP", 4) == 0) {
    return Format::kWebp;
  }
  return Format::kUnknown;
}

std::string media_type(Format format) {
  switch (format) {
    case Format::kPng: return "image/png";
    case Format::kJpeg: return "image/jpeg";
    case Format::kGif: return "image/gif";
    case Format::kWebp: return "image/webp";
    case Format::kUnknown: break;
  }
  return std::string();
}

Size dimensions(const std::string& bytes) {
  if (bytes.empty()) return Size{};
  const unsigned char* data = reinterpret_cast<const unsigned char*>(bytes.data());
  Format actual = format_for_magic(data, bytes.size());
  if (actual == Format::kUnknown) return Size{};
  if (actual == Format::kWebp) return webp_dimensions(bytes);
  int w = 0;
  int h = 0;
  int comp = 0;
  if (stbi_info_from_memory(data, static_cast<int>(bytes.size()), &w, &h, &comp) == 0) {
    return Size{};
  }
  return Size{w, h};
}

}  // namespace image_probe
