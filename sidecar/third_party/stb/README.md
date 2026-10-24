# stb 单头文件（vendored）

本目录只放两个 Sean Barrett 的 public domain 单头文件，供 C++ sidecar 读写 PNG 与读图片头。

## 来源与版本

| 文件 | 上游 URL | 版本（文件头自述） | 抓取日期 | 字节数 | SHA-256 |
| --- | --- | --- | --- | --- | --- |
| `stb_image.h` | `https://raw.githubusercontent.com/nothings/stb/master/stb_image.h` | v2.30 | 2026-10-24 | 283010 | `594C2FE35D49488B4382DBFAEC8F98366DEFCA819D916AC95BECF3E75F4200B3` |
| `stb_image_write.h` | `https://raw.githubusercontent.com/nothings/stb/master/stb_image_write.h` | v1.16 | 2026-10-24 | 71221 | `CBD5F0AD7A9CF4468AFFB36354A1D2338034F2C12473CF1A8E32053CB6914A05` |

上游仓库：`https://github.com/nothings/stb`（master 分支没有 release tag，所以版本以**文件头自述的版本号 + SHA-256** 为准，不用 git 提交号）。

复核算法（Windows PowerShell）：

```powershell
(Get-FileHash sidecar\third_party\stb\stb_image.h -Algorithm SHA256).Hash
(Get-FileHash sidecar\third_party\stb\stb_image_write.h -Algorithm SHA256).Hash
```

## 用在哪

- `stb_image.h`：只用来**读图片头拿宽高**（`stbi_info` 系列，不解像素）与测试里回读刚写出的 PNG；实现宏 `STB_IMAGE_IMPLEMENTATION` 只放在 `sidecar/src/image_probe.cpp` 一个文件里。
- `stb_image_write.h`：只用来把剪贴板位图编码成 PNG（`stbi_write_png_to_func` 写进内存缓冲）；实现宏 `STB_IMAGE_WRITE_IMPLEMENTATION` 只放在 `sidecar/src/clipboard_image.cpp` 一个文件里。

两个实现宏各只能出现一次，否则链接期会撞重复符号。

## 许可

public domain（或 MIT，二选一，见文件头原文）。上游原文：

> stb_image - v2.30 - public domain image loader
> stb_image_write - v1.16 - public domain
