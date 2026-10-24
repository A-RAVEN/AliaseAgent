#ifndef CLIPBOARD_IMAGE_H
#define CLIPBOARD_IMAGE_H

#include <cstddef>
#include <functional>
#include <string>

// 从系统剪贴板取图片，落成一个 PNG 文件。
//
// 两条设计约束来自 tasks.md 5.1 / 5.3：
//   1. "取剪贴板原始数据"抽成一个可注入的函数指针 —— 单元测试注入假数据，
//      测试进程永远不碰真实剪贴板（碰了会改掉用户正在复制的东西）；
//   2. DIB → PNG 的转换做成纯函数，喂字节进、拿字节出，不依赖剪贴板。
namespace clipboard_image {

/// 剪贴板里取到的是哪种表示。`kPng` 直接就是 PNG 字节，不用重编码。
enum class Kind {
  kNone = 0,
  kPng,  // Windows 上 `RegisterClipboardFormatW(L"PNG")` 注册的格式
  kDib,  // CF_DIB / CF_DIBV5：BITMAPINFOHEADER 起头的设备无关位图
  /// 剪贴板被别的程序占着，`OpenClipboard` 失败 —— 与"里面没有图"是两件事。
  /// 分开是为了**说得清**：Windows 的剪贴板是独占资源，任何程序（剪贴板管理器、
  /// Office、浏览器）都可能短暂占着它，那时报"里面没有图"就是撒谎。
  kBusy,
};

/// 一次剪贴板读取的结果。
struct RawClipboard {
  Kind kind = Kind::kNone;
  std::string bytes;
};

/// 取数函数。返回 true 表示 out 里拿到了东西；false 表示剪贴板里没有图片。
using Reader = std::function<bool(RawClipboard& out)>;

/// 从真实剪贴板取（Win32）。非 Windows 平台恒返回 false。
/// 不开任何窗口，也不同步等用户操作。
bool read_from_system_clipboard(RawClipboard& out);

/// 设置取数函数。传一个空函数对象恢复默认的系统实现。
void set_reader(Reader reader);

/// 当前生效的取数函数（测试里用来确认注入生效）。
const Reader& current_reader();

/// 现在用的是不是默认的系统实现（即没被注入过）。
/// 测试用它确认"复位成功"而不必调用取数函数 —— 调用默认实现就会真的去读一次
/// 系统剪贴板，而单测不该碰真实剪贴板。
bool uses_system_reader();

/// 解析 DIB 头（BITMAPINFOHEADER 或更大的同类头）里的宽、高、位深。
/// `height > 0` 是自下而上（DIB 的常规形态），`< 0` 是自上而下。
/// `header_size` 是 biSize；像素数据的起点就是它（24/32 位没有调色板）。
/// 头部不足 40 字节、或是 BITMAPCOREHEADER，返回 false。
bool parse_dib_header(const std::string& dib, int& width, int& height, int& bit_count,
                      size_t& header_size);

/// DIB 像素数据 → 自上而下的 PNG 字节。
/// @param bits      像素数据（不含头部），每行按 4 字节对齐
/// @param len       `bits` 的可用字节数
/// @param width     像素宽
/// @param height    带符号高度：> 0 自下而上，< 0 自上而下
/// @param bit_count 24（BGR）或 32（BGRA）
/// @returns PNG 字节；参数非法、数据不足或编码失败时返回空串
///
/// 32 位 DIB 的 alpha 通道在剪贴板里常常是 0 或垃圾值（截图工具就那样），
/// 这里一律输出不透明像素 —— 否则贴出来的截图会是全透明的。
std::string dib_to_png_bytes(const unsigned char* bits, size_t len, int width, int height,
                             int bit_count);

/// 把一次剪贴板读取的结果变成 PNG 字节：`kPng` 直接原样返回（顺带验一次尺寸），
/// `kDib` 走 `dib_to_png_bytes`。返回空串表示这次没拿到能用的图片。
std::string raw_to_png_bytes(const RawClipboard& raw);

}  // namespace clipboard_image

#endif  // CLIPBOARD_IMAGE_H
