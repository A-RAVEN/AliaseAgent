// 图片格式与尺寸判定的 C++ 单测（tasks.md 3.2 / 3.3）。
//
// 覆盖：四种格式（PNG / JPEG / GIF / WebP）各取到正确宽高；扩展名判定表；
// 魔数判定表；三条反例（扩展名撒谎、不是图片的扩展名、被截断的 PNG 头）。
//
// 夹具：sidecar/test/fixtures/images/ 下三张 4×3 的真图（PNG / JPEG / GIF）。
// WebP 不在仓库里放二进制，用一段 base64 常量在用例里解出字节 —— 那是个 48 字节的
// 无损 webp，VP8L 头 `2F 03 80 00 00` 编码的正是 4×3（生成方式见 tasks.md 3.1）。
#include <catch2/catch_all.hpp>

#include <cstring>
#include <fstream>
#include <string>

#include "image_probe.h"

namespace {

// 4×3 无损 WebP（VP8L），左上红 / 右上绿 / 下半蓝，与三张夹具同图。
const char* kWebpBase64 =
    "UklGRigAAABXRUJQVlA4TBwAAAAvA4AAABcwgAKCIv9HExAU+T/a/Ad3BqY0ov8x";

std::string base64_decode(const std::string& in) {
  auto value_of = [](char c) -> int {
    if (c >= 'A' && c <= 'Z') return c - 'A';
    if (c >= 'a' && c <= 'z') return c - 'a' + 26;
    if (c >= '0' && c <= '9') return c - '0' + 52;
    if (c == '+') return 62;
    if (c == '/') return 63;
    return -1;
  };
  std::string out;
  int buf = 0;
  int bits = 0;
  for (char c : in) {
    if (c == '=' || c == '\n' || c == '\r') continue;
    int v = value_of(c);
    if (v < 0) continue;
    buf = (buf << 6) | v;
    bits += 6;
    if (bits >= 8) {
      bits -= 8;
      out.push_back(static_cast<char>((buf >> bits) & 0xFF));
    }
  }
  return out;
}

std::string read_bytes(const std::string& path) {
  std::ifstream f(path, std::ios::binary);
  if (!f) return std::string();
  return std::string(std::istreambuf_iterator<char>(f), std::istreambuf_iterator<char>());
}

std::string fixture(const char* name) {
  return read_bytes(std::string(IMAGE_FIXTURE_DIR) + "/" + name);
}

}  // namespace

// ---------------------------------------------------------------------------
// 3.2 四种格式各取到 4×3
// ---------------------------------------------------------------------------

TEST_CASE("image_probe reads PNG dimensions from the fixture", "[image-probe]") {
  std::string bytes = fixture("tiny.png");
  REQUIRE(bytes.size() > 0);
  REQUIRE(image_probe::format_for_magic(
              reinterpret_cast<const unsigned char*>(bytes.data()), bytes.size()) ==
          image_probe::Format::kPng);
  auto size = image_probe::dimensions(bytes);
  CHECK(size.width == 4);
  CHECK(size.height == 3);
}

TEST_CASE("image_probe reads JPEG dimensions from the fixture", "[image-probe]") {
  std::string bytes = fixture("tiny.jpg");
  REQUIRE(bytes.size() > 0);
  REQUIRE(image_probe::format_for_magic(
              reinterpret_cast<const unsigned char*>(bytes.data()), bytes.size()) ==
          image_probe::Format::kJpeg);
  auto size = image_probe::dimensions(bytes);
  CHECK(size.width == 4);
  CHECK(size.height == 3);
}

TEST_CASE("image_probe reads GIF dimensions from the fixture", "[image-probe]") {
  std::string bytes = fixture("tiny.gif");
  REQUIRE(bytes.size() > 0);
  REQUIRE(image_probe::format_for_magic(
              reinterpret_cast<const unsigned char*>(bytes.data()), bytes.size()) ==
          image_probe::Format::kGif);
  auto size = image_probe::dimensions(bytes);
  CHECK(size.width == 4);
  CHECK(size.height == 3);
}

TEST_CASE("image_probe reads WebP dimensions by parsing the RIFF header", "[image-probe]") {
  std::string bytes = base64_decode(kWebpBase64);
  REQUIRE(bytes.size() == 48);
  REQUIRE(image_probe::format_for_magic(
              reinterpret_cast<const unsigned char*>(bytes.data()), bytes.size()) ==
          image_probe::Format::kWebp);
  auto size = image_probe::dimensions(bytes);
  CHECK(size.width == 4);
  CHECK(size.height == 3);
}

// ---------------------------------------------------------------------------
// 扩展名与魔数两张判定表
// ---------------------------------------------------------------------------

TEST_CASE("image_probe maps the supported extensions and nothing else", "[image-probe]") {
  using image_probe::Format;
  CHECK(image_probe::format_for_extension("a.png") == Format::kPng);
  CHECK(image_probe::format_for_extension("a.PNG") == Format::kPng);
  CHECK(image_probe::format_for_extension("dir/a.jpg") == Format::kJpeg);
  CHECK(image_probe::format_for_extension("a.jpeg") == Format::kJpeg);
  CHECK(image_probe::format_for_extension("a.gif") == Format::kGif);
  CHECK(image_probe::format_for_extension("a.webp") == Format::kWebp);
  CHECK(image_probe::format_for_extension("a.txt") == Format::kUnknown);
  CHECK(image_probe::format_for_extension("a") == Format::kUnknown);
  CHECK(image_probe::format_for_extension("a.png.txt") == Format::kUnknown);
}

TEST_CASE("image_probe names the media types", "[image-probe]") {
  CHECK(image_probe::media_type(image_probe::Format::kPng) == "image/png");
  CHECK(image_probe::media_type(image_probe::Format::kJpeg) == "image/jpeg");
  CHECK(image_probe::media_type(image_probe::Format::kGif) == "image/gif");
  CHECK(image_probe::media_type(image_probe::Format::kWebp) == "image/webp");
  CHECK(image_probe::media_type(image_probe::Format::kUnknown).empty());
}

// ---------------------------------------------------------------------------
// 3.3 三条反例
// ---------------------------------------------------------------------------

TEST_CASE("image_probe catches an extension that lies about the bytes", "[image-probe]") {
  // 真实字节是 JPEG，路径却叫 .png：扩展名声明的与字节实际的对不上，
  // 调用方必须能看出这个矛盾（两个函数给出不同的 Format）。
  std::string jpeg = fixture("tiny.jpg");
  REQUIRE(jpeg.size() > 0);
  CHECK(image_probe::format_for_extension("lying.png") == image_probe::Format::kPng);
  CHECK(image_probe::format_for_magic(
            reinterpret_cast<const unsigned char*>(jpeg.data()), jpeg.size()) ==
        image_probe::Format::kJpeg);
}

TEST_CASE("image_probe treats a non-image extension as unknown", "[image-probe]") {
  std::string png = fixture("tiny.png");
  REQUIRE(png.size() > 0);
  CHECK(image_probe::format_for_extension("notes.txt") == image_probe::Format::kUnknown);
  // 扩展名不在表里时调用方应当直接拒绝，哪怕字节其实是张图。
}

TEST_CASE("image_probe survives truncated image headers", "[image-probe]") {
  std::string png = fixture("tiny.png");
  REQUIRE(png.size() > 8);

  // 只留 5 字节：连 PNG 的 8 字节签名都不完整 ⇒ 认不出格式。
  std::string five = png.substr(0, 5);
  CHECK(image_probe::format_for_magic(
            reinterpret_cast<const unsigned char*>(five.data()), five.size()) ==
        image_probe::Format::kUnknown);
  CHECK_FALSE(image_probe::dimensions(five).ok());

  // 留完整的 8 字节签名：格式认得，但后面没有 IHDR ⇒ 尺寸取不到，不能崩。
  std::string signature_only = png.substr(0, 8);
  CHECK(image_probe::format_for_magic(
            reinterpret_cast<const unsigned char*>(signature_only.data()),
            signature_only.size()) == image_probe::Format::kPng);
  auto size = image_probe::dimensions(signature_only);
  CHECK(size.width == 0);
  CHECK(size.height == 0);

  // 空字节串与 nullptr 都不能崩。
  CHECK_FALSE(image_probe::dimensions(std::string()).ok());
  CHECK(image_probe::format_for_magic(nullptr, 0) == image_probe::Format::kUnknown);
}
