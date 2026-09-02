## Why

用户双击 `run.bat` 期望一键构建并启动，但会随机弹 `[ERROR] Build failed` 逼他手动 `flutter clean`。根因是 Flutter 的 native-assets 增量缓存会指向一个已被顶掉的 sqlite3 库文件位置，导致 Dart 前端打包那一步在拷贝库文件时找不到源文件、翻车；而 Flutter 将它包成 `MSB8066` 这种外壳，用户看不到真实原因。此外 run.bat 还有一处潜在的配置错乱：它第 2 步会单独再 `Release` 构建一次 sidecar 并把库覆盖进 **Debug** 运行目录，造成跨配置混用。

## What Changes

- **自愈重试**：`flutter build windows --debug` 首次失败时，自动定点清理失效的构建缓存（**清 `.dart_tool\flutter_build` + `.dart_tool\hooks_runner`（native-assets 钩子缓存，含持久化的 output.json 死引用清单；只清 flutter_build 已实测无法自愈），保留 `build\` 增量产物**），然后重试一次；仍失败才落盘完整日志并**自动归类**真实原因是"网络/下载环境"还是"你自己的代码"（归类不了则提示查日志首条 `Error:`），而不是甩一个 MSB8066 外壳。因为 sqlite3 的下载目录名是跨进程随机哈希，**重试会重新联网下载 sqlite3，故自愈依赖网络**；离线时重试会在下载处失败并被归为 network。（清这两处与全量 clean 都会联网重下 sqlite3，定点清只在"保留 `build\` 增量、破坏面小"上更优。）
- **删除有害的第 2 步 sidecar 重建与覆盖**：第 1 步 `flutter build` 已经通过 `windows/CMakeLists.txt` 自动以 Debug 配置构建并安装 sidecar 及其依赖库。现有的"另跑一次 `cmake --build ... --config Release` + 4 条 `copy /Y ... > nul`"不仅多余，还会把 Release 版库覆盖进 Debug 运行目录（跨配置混用），且拷贝失败被静默吞掉。删除它；并把原第 2 步改造成"启动前校验产物 + 把运行目录里的 `sidecar.dll`（Debug）及 `libcurl*.dll`/`zlib*.dll` 刷到项目根目录（`sidecar.dll` 与 `-d` 依赖为 Debug→Debug；`libcurl*`/`zlib*` 通配会同时带上 release 命名 `libcurl.dll`/`zlib1.dll` 与 debug 命名 `libcurl-d.dll`/`zlibd1.dll`，release 命名属无害冗余、不宣称 libcurl/zlib 层面"彻底无混用"——见 line 27/design D4；每条拷贝带失败出口）"，使冒烟测试测到当前构建（见 design D4）。
- **启动前校验产物**：校验 `alias_agent.exe` 与 sidecar 库存在，缺失时明确提示（如"sidecar 没构建 / 很可能是 vcpkg 未找到"），而不是 app 开了却缺库。
- **每步失败出口**：给清理/下载命令加 `ERRORLEVEL` 门禁，避免"失败却静默继续"。

## Capabilities

### New Capabilities

- `desktop-build`: Windows 桌面端通过 `run.bat` 一键构建与启动的健壮性契约——构建失败能自动清缓存重试、失败时归类真实原因、sidecar 以与 app 一致的 Debug 配置构建、启动前校验产物、冒烟测试针对当前构建。

### Modified Capabilities

（无——不影响 `ffi-bridge`、`model-gateway`、`session-persistence`、`context-compaction` 等任何现有能力的需求/行为。）

## Impact

- **代码/文件**：`run.bat`（重构启动流程）；不改任何 Dart/C++ 源码。
- **构建产物**：不再把 Release 版 sidecar 覆盖进 Debug 运行目录；构建失败时自动清缓存重试，失败信息落盘到 `%TEMP%\aliasagent_build.log`。
- **依赖**：无新增。
- **副作用说明**：去除第 2 步的 Release 重建与跨配置覆盖后，`run.bat` 不再把 Release 版 `sidecar.dll` 覆盖进 Debug 运行目录（"跨配置混用已消除"严格指 `sidecar.dll`）；但会把运行目录里的 `sidecar.dll` 与 `libcurl*.dll`/`zlib*.dll` 拷到项目根目录——注意运行目录经 CMake 通配**同时**含 release 风味（`libcurl.dll`/`zlib1.dll`）与 debug 风味（`libcurl-d.dll`/`zlibd1.dll`），通配拷贝两者都会带到根目录，而 Debug `sidecar.dll` 只导入 `-d` 风味、release 命名文件属无害冗余（**不作"彻底无混用"宣称**）。`sidecar.dll` 与 `-d` 依赖为 Debug→Debug（非跨配置），每条拷贝带失败出口。原第 2 步曾是根目录这些库文件的唯一来源，故 D4 需一并刷新；供冒烟测试（从项目根运行、经 cwd=根目录解析 `sidecar.dll` 及其 `-d` 依赖）测到当前构建。
