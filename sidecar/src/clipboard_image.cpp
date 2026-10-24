#include "clipboard_image.h"

#include <cstdint>
#include <utility>

#include "image_probe.h"

// stb_image_write 的实现只允许出现在一个翻译单元里，就放在这里。
#define STB_IMAGE_WRITE_IMPLEMENTATION
#include <stb_image_write.h>

#ifdef _WIN32
#include <windows.h>
#endif

namespace clipboard_image {

namespace {

Reader& reader_slot() {
  static Reader reader = &read_from_system_clipboard;
  return reader;
}

bool& system_reader_flag() {
  static bool is_system = true;
  return is_system;
}

uint32_t le32(const unsigned char* p) {
  return static_cast<uint32_t>(p[0]) | (static_cast<uint32_t>(p[1]) << 8) |
         (static_cast<uint32_t>(p[2]) << 16) | (static_cast<uint32_t>(p[3]) << 24);
}

/// stb_image_write 的回调：把编码结果追加到 std::string。
void png_write_callback(void* context, void* data, int size) {
  auto* out = static_cast<std::string*>(context);
  out->append(static_cast<const char*>(data), static_cast<size_t>(size));
}

}  // namespace

bool read_from_system_clipboard(RawClipboard& out) {
  out = RawClipboard{};
#ifdef _WIN32
  if (!OpenClipboard(nullptr)) {
    // 剪贴板是独占资源：别的程序（剪贴板管理器、Office、浏览器）可能正占着它。
    // 这时**不是**"里面没有图"，要如实区分，否则用户会以为白复制了。
    out.kind = Kind::kBusy;
    return false;
  }
  struct ClipboardCloser {
    ~ClipboardCloser() { CloseClipboard(); }
  } closer;

  // 1) PNG：浏览器复制图片时通常同时给这一种，直接落盘不用重编码
  const UINT png_format = RegisterClipboardFormatW(L"PNG");
  if (png_format != 0 && IsClipboardFormatAvailable(png_format)) {
    if (HANDLE handle = GetClipboardData(png_format)) {
      if (void* locked = GlobalLock(handle)) {
        out.kind = Kind::kPng;
        out.bytes.assign(static_cast<const char*>(locked), GlobalSize(handle));
        GlobalUnlock(handle);
        if (!out.bytes.empty()) return true;
        out = RawClipboard{};
      }
    }
  }

  // 2) DIBV5 / DIB：截图工具（Snipping Tool 等）只给这一种，要自己转 PNG
  const UINT dib_formats[2] = {static_cast<UINT>(CF_DIBV5), static_cast<UINT>(CF_DIB)};
  for (UINT format : dib_formats) {
    if (!IsClipboardFormatAvailable(format)) continue;
    HANDLE handle = GetClipboardData(format);
    if (handle == nullptr) continue;
    void* locked = GlobalLock(handle);
    if (locked == nullptr) continue;
    out.kind = Kind::kDib;
    out.bytes.assign(static_cast<const char*>(locked), GlobalSize(handle));
    GlobalUnlock(handle);
    if (!out.bytes.empty()) return true;
    out = RawClipboard{};
  }
  return false;
#else
  return false;
#endif
}

void set_reader(Reader reader) {
  system_reader_flag() = !reader;
  reader_slot() = reader ? std::move(reader) : Reader(&read_from_system_clipboard);
}

const Reader& current_reader() { return reader_slot(); }

bool uses_system_reader() { return system_reader_flag(); }

bool parse_dib_header(const std::string& dib, int& width, int& height, int& bit_count,
                      size_t& header_size) {
  // BITMAPINFOHEADER 起头的最短形态是 40 字节；BITMAPCOREHEADER(12) 不支持
  // （剪贴板上的图不会是这个形态：它没有位深以外的有用字段）。
  if (dib.size() < 40) return false;
  const unsigned char* p = reinterpret_cast<const unsigned char*>(dib.data());
  const uint32_t bi_size = le32(p);
  if (bi_size < 40) return false;
  if (dib.size() < static_cast<size_t>(bi_size)) return false;
  const int32_t w = static_cast<int32_t>(le32(p + 4));
  const int32_t h = static_cast<int32_t>(le32(p + 8));
  const uint32_t bpp =
      static_cast<uint32_t>(p[14]) | (static_cast<uint32_t>(p[15]) << 8);
  if (w <= 0 || h == 0) return false;
  width = static_cast<int>(w);
  height = static_cast<int>(h);
  bit_count = static_cast<int>(bpp);
  header_size = static_cast<size_t>(bi_size);
  return true;
}

std::string dib_to_png_bytes(const unsigned char* bits, size_t len, int width, int height,
                             int bit_count) {
  if (bits == nullptr || width <= 0 || height == 0) return std::string();
  if (bit_count != 24 && bit_count != 32) return std::string();

  const bool bottom_up = height > 0;
  const int rows = bottom_up ? height : -height;
  const size_t bytes_per_pixel = static_cast<size_t>(bit_count) / 8;
  const size_t src_stride = ((static_cast<size_t>(width) * bytes_per_pixel + 3) / 4) * 4;
  if (len < src_stride * static_cast<size_t>(rows)) return std::string();

  const size_t dst_stride = static_cast<size_t>(width) * 4;
  std::string rgba(dst_stride * static_cast<size_t>(rows), '\0');
  for (int y = 0; y < rows; ++y) {
    const int src_row = bottom_up ? (rows - 1 - y) : y;
    const unsigned char* src = bits + static_cast<size_t>(src_row) * src_stride;
    unsigned char* dst = reinterpret_cast<unsigned char*>(&rgba[static_cast<size_t>(y) * dst_stride]);
    for (int x = 0; x < width; ++x) {
      dst[0] = src[2];   // R
      dst[1] = src[1];   // G
      dst[2] = src[0];   // B
      dst[3] = 0xFF;     // DIB 的 alpha 常是 0/垃圾值，统一按不透明
      src += bytes_per_pixel;
      dst += 4;
    }
  }

  std::string png;
  if (stbi_write_png_to_func(png_write_callback, &png, width, rows, 4, rgba.data(),
                             static_cast<int>(dst_stride)) == 0) {
    return std::string();
  }
  return png;
}

std::string raw_to_png_bytes(const RawClipboard& raw) {
  if (raw.kind == Kind::kNone || raw.bytes.empty()) return std::string();
  if (raw.kind == Kind::kPng) {
    // 原样透传，但先确认它真的是一张能读的图（剪贴板上的"PNG"也可能是坏字节）
    return image_probe::dimensions(raw.bytes).ok() ? raw.bytes : std::string();
  }
  int width = 0;
  int height = 0;
  int bit_count = 0;
  size_t header_size = 0;
  if (!parse_dib_header(raw.bytes, width, height, bit_count, header_size)) return std::string();
  const unsigned char* bits =
      reinterpret_cast<const unsigned char*>(raw.bytes.data()) + header_size;
  return dib_to_png_bytes(bits, raw.bytes.size() - header_size, width, height, bit_count);
}

}  // namespace clipboard_image
