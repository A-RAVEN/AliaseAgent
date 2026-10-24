// 剪贴板取图与 DIB → PNG 转换的 C++ 单测（tasks.md 5.1）。
//
// **这条测试不碰真实剪贴板。** 需要"剪贴板里有东西"的地方一律用
// `clipboard_image::set_reader()` 注入假数据；真实剪贴板（含 Windows 上
// `Clipboard::SetImage` 放图、再点界面按钮）只由 tasks.md 13.4 的 live 用例覆盖。
// 理由：单测里读写系统剪贴板会改掉用户正在复制的东西，跑一次测试就丢一次内容。
//
// 覆盖：32 位自下而上 DIB 转出来能被解码且**朝向正确**（底行变顶行的反面）、
// 24 位 DIB、自上而下（负高度）DIB、四种非法输入、`raw_to_png_bytes` 的两条分支、
// 以及"注入了假取数函数之后系统实现不再被调用"。
#include <catch2/catch_all.hpp>

#include <cstring>
#include <filesystem>
#include <fstream>
#include <string>
#include <vector>

#include <nlohmann/json.hpp>
#include <stb_image.h>  // 只取声明：实现宏在 src/image_probe.cpp 里

#include "clipboard_image.h"
#include "image_probe.h"
#include "temp_dir.h"
#include "tools.h"

using json = nlohmann::json;

static json parse_result(const std::string& raw) { return json::parse(raw); }

namespace {

// 4×3、32 位 BGRA、自下而上：内存第 0 行 = 图的最下面一行。
// 底 red、中 green、顶 blue —— 朝向错了颜色就会对上位置。
constexpr int kWidth = 4;
constexpr int kHeight = 3;
constexpr size_t kStride32 = kWidth * 4;  // 4 字节对齐后正好 16

void put_bgra(unsigned char* row, int x, unsigned char b, unsigned char g, unsigned char r) {
  row[x * 4 + 0] = b;
  row[x * 4 + 1] = g;
  row[x * 4 + 2] = r;
  row[x * 4 + 3] = 0;  // 剪贴板位图的 alpha 常是 0，转换时必须按不透明处理
}

std::vector<unsigned char> make_bottom_up_dib32() {
  std::vector<unsigned char> dib(kStride32 * kHeight, 0);
  for (int x = 0; x < kWidth; ++x) {
    put_bgra(dib.data() + 0 * kStride32, x, 0, 0, 255);    // 内存第 0 行 = 底部 = 红
    put_bgra(dib.data() + 1 * kStride32, x, 0, 128, 0);    // 中间 = 绿
    put_bgra(dib.data() + 2 * kStride32, x, 255, 0, 0);    // 内存最后一行 = 顶部 = 蓝
  }
  return dib;
}

std::vector<unsigned char> make_dib24(int width, int height) {
  const size_t stride = ((static_cast<size_t>(width) * 24 + 31) / 32) * 4;
  std::vector<unsigned char> dib(stride * static_cast<size_t>(height), 0x7F);
  return dib;
}

/// 完整的 CF_DIB 形态：40 字节 BITMAPINFOHEADER + 像素行（自下而上）。
std::string make_dib_with_header32() {
  auto pixels = make_bottom_up_dib32();
  std::string out;
  auto le32 = [&out](uint32_t v) {
    out.push_back(static_cast<char>(v & 0xFF));
    out.push_back(static_cast<char>((v >> 8) & 0xFF));
    out.push_back(static_cast<char>((v >> 16) & 0xFF));
    out.push_back(static_cast<char>((v >> 24) & 0xFF));
  };
  auto le16 = [&out](uint16_t v) {
    out.push_back(static_cast<char>(v & 0xFF));
    out.push_back(static_cast<char>((v >> 8) & 0xFF));
  };
  le32(40);                                   // biSize
  le32(static_cast<uint32_t>(kWidth));        // biWidth
  le32(static_cast<uint32_t>(kHeight));       // biHeight（正 = 自下而上）
  le16(1);                                    // biPlanes
  le16(32);                                   // biBitCount
  le32(0);                                    // biCompression = BI_RGB
  le32(static_cast<uint32_t>(kStride32 * kHeight));  // biSizeImage
  le32(0);                                    // biXPelsPerMeter
  le32(0);                                    // biYPelsPerMeter
  le32(0);                                    // biClrUsed
  le32(0);                                    // biClrImportant
  out.append(reinterpret_cast<const char*>(pixels.data()), pixels.size());
  return out;
}

struct Decoded {
  int w = 0;
  int h = 0;
  std::vector<unsigned char> rgba;
  bool ok() const { return w > 0 && h > 0; }
};

Decoded decode(const std::string& png) {
  Decoded out;
  int comp = 0;
  unsigned char* pixels = stbi_load_from_memory(
      reinterpret_cast<const unsigned char*>(png.data()), static_cast<int>(png.size()), &out.w,
      &out.h, &comp, 4);
  if (pixels == nullptr) return out;
  out.rgba.assign(pixels, pixels + static_cast<size_t>(out.w) * out.h * 4);
  stbi_image_free(pixels);
  return out;
}

}  // namespace

TEST_CASE("clipboard_image: bottom-up 32-bit DIB becomes an upright PNG", "[clipboard]") {
  auto dib = make_bottom_up_dib32();
  std::string png = clipboard_image::dib_to_png_bytes(dib.data(), dib.size(), kWidth, kHeight, 32);
  REQUIRE(!png.empty());

  // 尺寸能被既有的图片判定读到
  auto size = image_probe::dimensions(png);
  CHECK(size.width == kWidth);
  CHECK(size.height == kHeight);

  // 朝向：内存第 0 行（红，底部）必须落在 PNG 的最后一行
  Decoded d = decode(png);
  REQUIRE(d.ok());
  REQUIRE(d.w == kWidth);
  REQUIRE(d.h == kHeight);
  const unsigned char* top = d.rgba.data();
  const unsigned char* bottom = d.rgba.data() + static_cast<size_t>(d.w) * (d.h - 1) * 4;
  CHECK(top[0] == 0);
  CHECK(top[1] == 0);
  CHECK(top[2] == 255);      // 顶部应是蓝
  CHECK(top[3] == 255);      // alpha 被强制为不透明
  CHECK(bottom[0] == 255);   // 底部应是红
  CHECK(bottom[1] == 0);
  CHECK(bottom[2] == 0);
  CHECK(bottom[3] == 255);
}

TEST_CASE("clipboard_image: 24-bit DIB converts too", "[clipboard]") {
  auto dib = make_dib24(kWidth, kHeight);
  std::string png = clipboard_image::dib_to_png_bytes(dib.data(), dib.size(), kWidth, kHeight, 24);
  REQUIRE(!png.empty());
  auto size = image_probe::dimensions(png);
  CHECK(size.width == kWidth);
  CHECK(size.height == kHeight);
}

TEST_CASE("clipboard_image: a top-down DIB (negative height) keeps its order", "[clipboard]") {
  auto dib = make_bottom_up_dib32();
  // 同一份字节按"负高度 = 自上而下"解释：内存第 0 行（红）就是图的最上面一行，
  // 因此转出来之后顶部应当是红、底部应当是蓝 —— 与自下而上那一组正好相反。
  std::string png = clipboard_image::dib_to_png_bytes(dib.data(), dib.size(), kWidth, -kHeight, 32);
  REQUIRE(!png.empty());
  Decoded d = decode(png);
  REQUIRE(d.ok());
  const unsigned char* top = d.rgba.data();
  const unsigned char* bottom = d.rgba.data() + static_cast<size_t>(d.w) * (d.h - 1) * 4;
  CHECK(top[0] == 255);   // 顶 = 红
  CHECK(top[1] == 0);
  CHECK(top[2] == 0);
  CHECK(bottom[0] == 0);  // 底 = 蓝
  CHECK(bottom[1] == 0);
  CHECK(bottom[2] == 255);
}

TEST_CASE("clipboard_image: parse_dib_header reads a real BITMAPINFOHEADER", "[clipboard]") {
  std::string dib = make_dib_with_header32();
  REQUIRE(!dib.empty());
  int width = 0;
  int height = 0;
  int bit_count = 0;
  size_t header_size = 0;
  REQUIRE(clipboard_image::parse_dib_header(dib, width, height, bit_count, header_size));
  CHECK(width == kWidth);
  CHECK(height == kHeight);      // 正数 = 自下而上
  CHECK(bit_count == 32);
  CHECK(header_size == 40);
}

TEST_CASE("clipboard_image: rejects malformed DIB input", "[clipboard]") {
  auto dib = make_bottom_up_dib32();
  // 数据不够一整帧
  CHECK(clipboard_image::dib_to_png_bytes(dib.data(), dib.size() - 1, kWidth, kHeight, 32).empty());
  // 不支持的位深
  CHECK(clipboard_image::dib_to_png_bytes(dib.data(), dib.size(), kWidth, kHeight, 16).empty());
  // 宽度非法
  CHECK(clipboard_image::dib_to_png_bytes(dib.data(), dib.size(), 0, kHeight, 32).empty());
  // 高度为 0
  CHECK(clipboard_image::dib_to_png_bytes(dib.data(), dib.size(), kWidth, 0, 32).empty());
  // 空指针
  CHECK(clipboard_image::dib_to_png_bytes(nullptr, 0, kWidth, kHeight, 32).empty());
}

TEST_CASE("clipboard_image: raw_to_png_bytes handles both representations", "[clipboard]") {
  clipboard_image::RawClipboard none;
  CHECK(clipboard_image::raw_to_png_bytes(none).empty());

  // kPng：原样透传
  auto dib = make_bottom_up_dib32();
  std::string png = clipboard_image::dib_to_png_bytes(dib.data(), dib.size(), kWidth, kHeight, 32);
  REQUIRE(!png.empty());
  clipboard_image::RawClipboard as_png;
  as_png.kind = clipboard_image::Kind::kPng;
  as_png.bytes = png;
  CHECK(clipboard_image::raw_to_png_bytes(as_png) == png);

  // kDib：走转换（这里要给**带 BITMAPINFOHEADER 的完整 DIB**，
  // 因为 raw_to_png_bytes 会先解析头再取像素）
  clipboard_image::RawClipboard as_dib;
  as_dib.kind = clipboard_image::Kind::kDib;
  as_dib.bytes = make_dib_with_header32();
  CHECK(!clipboard_image::raw_to_png_bytes(as_dib).empty());
}

TEST_CASE("clipboard_image: the injected reader replaces the system one", "[clipboard]") {
  bool injected_called = false;
  clipboard_image::set_reader([&injected_called](clipboard_image::RawClipboard& out) {
    injected_called = true;
    out.kind = clipboard_image::Kind::kNone;
    return false;
  });
  CHECK_FALSE(clipboard_image::uses_system_reader());

  clipboard_image::RawClipboard raw;
  const bool got = clipboard_image::current_reader()(raw);
  CHECK_FALSE(got);
  CHECK(injected_called);

  // 复位之后回到系统实现。这里只看标志位、**不去调它** —— 调默认实现就真的
  // 读了一次系统剪贴板，而这条测试承诺不碰真实剪贴板。
  clipboard_image::set_reader(nullptr);
  CHECK(clipboard_image::uses_system_reader());
}

// ============================================================================
// tools::read_clipboard_image（tasks.md 5.2）
//
// 四种假剪贴板：有 PNG 数据 / 有 DIB 数据 / 什么都没有 / 目标目录不存在。
// 全程注入假数据，**不碰真实剪贴板**（见本文件顶部说明）。
// ============================================================================

namespace {

/// 用例结束时把取数函数复位，避免污染后面的用例。
struct ReaderReset {
  ~ReaderReset() { clipboard_image::set_reader(nullptr); }
};

json call_read_clipboard_image(const std::string& dest_dir) {
  json request;
  request["dest_dir"] = dest_dir;
  return parse_result(tools::read_clipboard_image(request.dump()));
}

}  // namespace

TEST_CASE("read_clipboard_image: PNG on the clipboard is written verbatim", "[clipboard]") {
  TempDir tmp;
  auto dib = make_bottom_up_dib32();
  std::string png = clipboard_image::dib_to_png_bytes(dib.data(), dib.size(), kWidth, kHeight, 32);
  REQUIRE(!png.empty());

  clipboard_image::set_reader([png](clipboard_image::RawClipboard& out) {
    out.kind = clipboard_image::Kind::kPng;
    out.bytes = png;
    return true;
  });
  ReaderReset reset;

  auto j = call_read_clipboard_image(tmp.path());
  REQUIRE(j["ok"] == true);
  CHECK(j["media_type"] == "image/png");
  CHECK(j["width"] == kWidth);
  CHECK(j["height"] == kHeight);
  CHECK(j["bytes"] == static_cast<int>(png.size()));
  std::string written_path = j["path"];
  CHECK(written_path.rfind(tmp.path()) == 0);
  CHECK(written_path.find("paste-") != std::string::npos);

  // 落盘内容与剪贴板里的 PNG 逐字节相同
  std::ifstream f(written_path, std::ios::binary);
  REQUIRE(f.good());
  std::string on_disk((std::istreambuf_iterator<char>(f)), std::istreambuf_iterator<char>());
  CHECK(on_disk == png);
}

TEST_CASE("read_clipboard_image: a DIB on the clipboard is converted and written", "[clipboard]") {
  TempDir tmp;
  clipboard_image::set_reader([](clipboard_image::RawClipboard& out) {
    out.kind = clipboard_image::Kind::kDib;
    out.bytes = make_dib_with_header32();
    return true;
  });
  ReaderReset reset;

  auto j = call_read_clipboard_image(tmp.path());
  REQUIRE(j["ok"] == true);
  CHECK(j["width"] == kWidth);
  CHECK(j["height"] == kHeight);
  std::ifstream f(j["path"].get<std::string>(), std::ios::binary);
  REQUIRE(f.good());
  std::string on_disk((std::istreambuf_iterator<char>(f)), std::istreambuf_iterator<char>());
  auto size = image_probe::dimensions(on_disk);
  CHECK(size.width == kWidth);
  CHECK(size.height == kHeight);
}

TEST_CASE("read_clipboard_image: an empty clipboard reports it plainly", "[clipboard]") {
  TempDir tmp;
  clipboard_image::set_reader([](clipboard_image::RawClipboard& out) {
    out.kind = clipboard_image::Kind::kNone;
    return false;
  });
  ReaderReset reset;

  auto j = call_read_clipboard_image(tmp.path());
  REQUIRE(j["ok"] == false);
  CHECK(j["error"] == "clipboard has no image");
  // 一个文件都不该留下
  size_t png_count = 0;
  for (const auto& entry : std::filesystem::directory_iterator(tmp.path())) {
    if (entry.path().extension() == ".png") ++png_count;
  }
  CHECK(png_count == 0);
}

TEST_CASE("read_clipboard_image: a missing destination directory is created", "[clipboard]") {
  TempDir tmp;
  const std::string nested = tmp.path() + "/nested/deeper";
  auto dib = make_bottom_up_dib32();
  std::string png = clipboard_image::dib_to_png_bytes(dib.data(), dib.size(), kWidth, kHeight, 32);
  clipboard_image::set_reader([png](clipboard_image::RawClipboard& out) {
    out.kind = clipboard_image::Kind::kPng;
    out.bytes = png;
    return true;
  });
  ReaderReset reset;

  auto j = call_read_clipboard_image(nested);
  REQUIRE(j["ok"] == true);
  std::string written_path = j["path"];
  CHECK(written_path.rfind(nested) == 0);
  CHECK(std::filesystem::exists(nested));
  CHECK(std::filesystem::exists(written_path));
}

TEST_CASE("read_clipboard_image: 剪贴板被占时说 busy，不谎称没有图", "[clipboard]") {
  // Windows 的剪贴板是独占资源：`OpenClipboard` 失败时把它报成"里面没有图"
  // 会让用户以为自己白复制了。`Kind::kBusy` 就是为这条区分存在的。
  TempDir tmp;
  clipboard_image::set_reader([](clipboard_image::RawClipboard& out) {
    out.kind = clipboard_image::Kind::kBusy;
    return false;
  });
  ReaderReset reset;

  auto j = call_read_clipboard_image(tmp.path());
  REQUIRE(j["ok"] == false);
  std::string err = j["error"];
  CHECK(err.find("busy") != std::string::npos);
  CHECK(err.find("no image") == std::string::npos);

  // 对照：注入一个"真的没有图"的读取器，文案必须是另一句
  clipboard_image::set_reader([](clipboard_image::RawClipboard& out) {
    out.kind = clipboard_image::Kind::kNone;
    return false;
  });
  auto j2 = call_read_clipboard_image(tmp.path());
  REQUIRE(j2["ok"] == false);
  CHECK(std::string(j2["error"]) == "clipboard has no image");
}
