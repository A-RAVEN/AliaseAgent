## Context

`run.bat` 是 Windows 上一键构建并启动的入口。现状双击会随机 `[ERROR] Build failed`，逼用户手动 `flutter clean`。两个已实锤的病灶：

1. **失效的 native-assets 增量缓存**：`.dart_tool\flutter_build\<hash>\dart_build_result.json` 与 `install_code_assets.d` 仍引用一个**已不存在的 sqlite3 下载目录** `...\download-45ea5ea\sqlite3.dll`（磁盘上实际只有 `10a0a62c/1242ec33/666e495/13d022df/...` 等其它随机哈希目录）。Flutter 前端打包步骤来拷贝这份库时找不到源文件，翻车。而 CMake 把它包成 `MSB8066` 外壳，真实原因（`install_code_assets` 的 `PathNotFoundException`）被 `>nul`/嵌套 MSBuild 聚合吞掉——这就是"只有壳、看不到真因"。
2. **跨配置 sidecar 覆盖**：`windows/CMakeLists.txt` 已经 `add_dependencies(flutter_assemble sidecar_build)` + `add_custom_target(sidecar_build ALL)` + `install(FILES .../sidecar.dll)`，即第 1 步 `flutter build --debug` 就自动以 **Debug** 配置构建并安装 sidecar 及 `libcurl*/zlib*`（本机已检测到 vcpkg）。但 run.bat 第 2 步又独立跑一次 `cmake --build ... --config Release` 并 `copy` 进去，把 **Release** 版库覆盖到 **Debug** 运行目录——已实测体积差约 4 倍（540KB vs 2.2MB），属跨配置混用；且所有 `copy` 都 `> nul 2>&1`，失败静默。此外 `start` 前不校验 exe 存在、vcpkg 缺失时只 WARNING 不报错（app 启动但缺库）。

## Goals / Non-Goals

**Goals:**
- 双击 `run.bat` 稳定"自动构建→启动"，失败能**自动清缓存重试**，重试后仍失败才把真实原因归类给用户，不再逼手工 `flutter clean`。
- 去掉跨配置 sidecar 覆盖，让第 1 步产出的 Debug 库与运行目录完全一致。
- 启动前校验 `alias_agent.exe` 与 sidecar 库存在，缺库时明确提示（含 vcpkg 未找到）。

**Non-Goals:**
- 解决 sqlite3 "每次构建联网重下 + 下载目录名随机"的**根因**（那是独立改动：改 sqlite3 的 source、需要跑真实读写测出库不回归、且属依赖变更需授权）。本 change 只做 run.bat 侧自愈兜底；离线确定性根除见设计末尾"建议的后续"。
- 重构 Flutter/CMake 的 sidecar 集成方式。
- 改动任何产品能力 spec 或 Dart/C++ 源码行为。

## Decisions

### D1：删除 run.bat 第 2 步的 sidecar Release 重建 + 4 条 `copy`
- **做**：删 `cmake --build sidecar\build\windows --config Release > nul 2>&1` 及 4 条 `copy /Y ... > nul 2>&1`。
- **为何**：第 1 步已通过 `windows/CMakeLists.txt`（`add_dependencies(flutter_assemble sidecar_build)`）用 `$<CONFIG>`（此处 Debug）构建并 `install(FILES sidecar.dll ...)` 进运行目录。单独再 Release 重建只会覆盖成跨配置、且拷贝失败静默。删掉后第 1 步产出的库与运行目录**同构**。
- **替代**：保留但改成 Debug、去掉 `>nul`、加守卫。否——与第 1 步重复，跨配置隐患仍在；真实错误可见性改由 D3 的 `-v` 归类承担。

### D2：构建失败时"定点清 `.dart_tool\flutter_build` + `.dart_tool\hooks_runner`"→ 重试，而非全量 `flutter clean`
- **做**：`flutter build --debug` 失败 → 清 `.dart_tool\flutter_build` **与** `.dart_tool\hooks_runner`（native-assets 钩子缓存）→ `flutter pub get`（`if errorlevel 1` 门禁）→ 重试一次。清缓存用带界的 `rd /s /q` + 短延时重试（刚失败的 flutter 构建可能短暂持缓存句柄，纯一次性 `rd` 会误报失败——实测首轮自愈的 `rd` 在构建失败后立即执行时返回非零）。
- **为何**：失效引用**同时**持久化在两处——`.dart_tool\flutter_build\<hash>\...`（原生资产索引）**与** `.dart_tool\hooks_runner\<hook>\<hash>\output.json`（native-assets 钩子自己落盘的清单，flutter_build 清不掉它）。只清 flutter_build 时，钩子清单仍指向已删除的 `download-<hash>\sqlite3.dll`，且钩子认为"已构建"不再重下 → 重试照样 `install_code_assets` PathNotFound（实测一轮 run.bat 证实：首次失败→只清 flutter_build→重试仍失败，`output.json` 仍指向 `download-39b7d46`）。必须清钩子缓存，才迫使钩子重跑并联网重下 sqlite3 到**新** hash（实测：清两处后重试成功，hash 从 `39b7d46` 变为 `1552c0a2`，跨进程随机 hash 属实）。**差异**：清钩子缓存会连带删掉已下载的 native assets（sqlite3 等），但 D2 已承认这些**每次构建都会联网重下**、属固有损耗；真正保留的是 `build\` 下的 MSBuild/cl.exe 中间产物与已 Debug 构建好的 sidecar.dll → 失败后重试是增量重建，远比全量 `flutter clean`（连 `build\` + `.dart_tool\` 一起删、需全量重编译）破坏面小。故清这两处、仍非全量 clean。
- **替代**：全量 clean（否，破坏性+需联网）；只清 flutter_build（**否——已实测无法自愈**，钩子清单的死引用还在）；只重跑 native-assets 索引（太脆弱，跨 Flutter 版本）；只删钩子的 `output.json` 主清单（更精细但依赖钩子哈希子目录命名、脆弱）。
- **注意**：因 sqlite3 下载目录名是**跨进程随机**哈希，重试必然重新联网下载；**自愈（重试）结果依赖网络**——这决定了自愈只能"联网时把失败缓过来"，真正的离线确定性靠末尾"建议的后续"。

### D3：仍失败 → `flutter build --debug -v > %TEMP%\aliasagent_build.log` + findstr 归类"网络/代码/unknown"
- **做**：落盘后按特征归类，**先判代码类、再判网络类、否则 unknown**；两类同时命中以代码为准（避免偶发网络词掩盖真实 bug）。特征：网络类（`Could not download`/`Trying to retrieve`/`HandshakeException`/`timed out`/`network is unreachable`/`resolve host`/`pub get` 下载失败）、代码类（`fatal error C`/`error C`/`error LNK`/`unresolved external`）；**去掉**裸 `download`（会命中 `download-<hash>` 缓存路径）、裸 `Could not find`（会命中路径缺失）、裸 `Error:`（网络失败也打）；分别给出指引。
- **为何**：`MSB8066` 只是 CMake 外壳，普通输出看不到 cl.exe/Flutter 逐行报错；`-v` 落盘 + findstr 让用户/agent 能穿透外壳定位真因，符合"失败要见真因"。
- **替代**：仅打印日志路径（否，把"手动找错"推回用户）；裸 `MSB8066`（现状，不可接受）。

### D4：把原第 2 步改造成"验证产物 + 刷新根目录 Debug 库"
- **做**：校验产物并把运行目录里的 `sidecar.dll` 与 `libcurl*.dll`/`zlib*.dll` 拷到**项目根目录**（注意：运行目录经 `windows/CMakeLists.txt` 的 `FILES_MATCHING libcurl*.dll zlib*.dll` 通配，**同时**含 release 风味 `libcurl.dll`/`zlib1.dll` 与 debug 风味 `libcurl-d.dll`/`zlibd1.dll`；通配拷贝会把两者都带到根目录，而 Debug `sidecar.dll` 只导入 `-d` 风味，故 release 命名文件属无害冗余——**保留通配、不做窄化**）。其中 `sidecar.dll` 与 `-d` 风味依赖为 Debug→Debug（非跨配置）；"跨配置混用已消除"严格指 `sidecar.dll`（不再有 Release sidecar 覆盖 Debug 运行目录），**不宣称** libcurl/zlib 层面"彻底无混用"。每条 `copy` 后 `if errorlevel 1` 报明确错误并 `exit /b 1`（**不用** `> nul 2>&1` 吞错），使冒烟测试（`flutter test` 从项目根运行、经 cwd=根目录解析 `sidecar.dll` 及其 `-d` 依赖）测到当前构建。`if not exist ...\alias_agent.exe` / `if not exist ...\sidecar.dll` → 明确报错（含"sidecar 未构建 / 很可能是 vcpkg 未找到"）。
- **为何**：app FFI bridge 用裸名 `sidecar.dll`（Windows 从 exe 目录解析 → 加载 runner Debug 这份，已核对 `lib/services/sidecar_bridge.dart:658`）；冒烟测试却从项目根运行、优先加载**根目录**那份 `sidecar.dll`，其 libcurl/zlib 依赖也从 cwd=根目录解析。原 run.bat 第 2 步是根目录 `sidecar.dll`/`libcurl.dll`/`zlib1.dll` 的唯一来源，删除后根目录会陈旧/缺依赖。故 D4 把 sidecar 与其运行时依赖**一并**以 Debug→Debug 刷到根目录；同配置、非旧 Release→Debug，两者一致。
- **替代**：改冒烟测试的加载优先级（否，动测试文件，且不必要）；不刷新（否，冒烟测试失真）。

### D5：保留冒烟测试（第 3 步）与启动（第 4 步），补失败出口与校验
- **做**：第 3 步照旧 `flutter test test\unit\sidecar_bridge_test.dart`（`if errorlevel 1` 报错）；第 4 步 `if not exist ...alias_agent.exe` 前置校验后 `start`，并在每一步关键命令后加 `if errorlevel 1` 出口（**但 Flutter build 不走裸 abort**：其首次失败按 D2 自愈、重试仍失败按 D3 归类，见任务 2.1/2.2）。
- **为何**：避免"失败却静默继续"；与 D4 的产物校验配合保证"缺了就明说"。

## Risks / Trade-offs

- **[自愈重试成功可能掩盖真实代码 bug]** → 重试成功分支不静默放行：打印"首次失败已自动重试"提示（**run.bat 必须纯 ASCII 无法印中文——Windows 控制台 OEM 码页兼容需要——故用 ASCII 标记 `[INFO] FIRST_BUILD_FAILED_BUT_RETRY_RECOVERED` 呈现，该 token 在 tasks 3.1 被断言为可观测**，作为"确有一次真实失败并触发自愈"的证据）；若重试又失败则进入 D3 归类并展示真因。
- **[自愈需联网（sqlite3 重下）]** → 若离线，重试会在下载处失败并被归为"network"。真正的离线确定性不在本 change 范围，见"建议的后续"。
- **[删除第 2 步后根目录 sidecar.dll 与 libcurl/zlib 变陈旧/缺依赖]** → 原第 2 步是根目录 `sidecar.dll`/`libcurl.dll`/`zlib1.dll` 的唯一来源；删除后 D4 把 sidecar 与其运行时依赖一并 Debug→Debug 刷到根目录（每条拷贝带 `if errorlevel 1` 门禁、不吞错），保冒烟测试测到当前构建。
- **[自愈只"联网时"成立；定点清并未规避联网重下 sqlite3]** → 定点清与全量 clean 都会因 sqlite3 随机 hash 联网重下、离线都失败；定点清的真正优势只在"保留 build\ 增量、破坏面小"。真正离线确定性靠末尾/建议的后续（改 sqlite3 source）。
- **[vcpkg 缺失时 app 启动但缺库]** → D4 校验 sidecar.dll 存在并点名 vcpkg/WARNING，把 `windows/CMakeLists.txt` 的静默警告变成可见错误。
- **[findstr 分类误判]** → 分类是"辅助定位"；用收窄签名 + 代码优先，仍可能误判时 unknown 兜底，提示用户打开日志读首条 `Error:`/fatal error。

## Migration Plan

- 替换 `run.bat` 为自愈版本（保留 4 步骨架、重构第 1/2 步、加校验与归类）。
- 验证步骤（见 tasks 第 3 节，与 spec 场景一一对应）：A 病态存在+预验证（构建报 download-45ea5ea/假hash 缺失）→ B "定点清 flutter_build+hooks_runner"后自愈成功、产物为 Debug 同构（runner sidecar.dll ≈ 2.2MB 且非 540KB 的 Release）+ 重试成功不静默提示可观测（ASCII 标记 `FIRST_BUILD_FAILED_BUT_RETRY_RECOVERED`，见 D3/tasks 2.1 注记） → C 临时引入 C++ 编译错误，证明归为 code（代码优先）、不误吞、不改坏正常路径 → D 断开/坏代理，证明归为 network → E 干净/重注入病态两态各跑 `cmd /c run.bat` 无批处理陷阱 → F unknown 归类兜底 → G exe 缺失报错不启动 → H sidecar 缺失报错（含 vcpkg）不启动 → I 依赖刷新失败即 exit /b 1 → J 关键命令失败即中止。
- 回滚：还原 `run.bat` 即可；无 spec/数据库迁移。

## Open Questions

- findstr 分类的分隔精确度（网络/代码/unknown）是否覆盖实际错误形态，需在 B/C/D 验证实测后微调。
- （已决，关闭本问）根目录 `sidecar.dll` 刷新无需写入 `.gitignore`：现有 `.gitignore` 的 `*.dll` 及显式 `sidecar.dll`/`libcurl.dll`/`zlib1.dll` 已覆盖，`git check-ignore sidecar.dll` 确认被忽略、`git ls-files` 确认未被跟踪——D4 的 Debug→Debug 根目录拷贝不产生任何 git 噪声。

## 建议的后续（本 change 不包含）

把 sqlite3 从"每次联网下载"改为本地/系统 source（如 `source: system` + `name_windows: winsqlite3`、或仓库 vendored `sqlite3.c` 本地编译），从根上消除"每构建联网 + 目录名随机"导致的缓存漂移与离线必败。属于依赖/配置变更，需用户授权、且必须先跑真实读写测出库不回归（确认没有 FTS5/RTREE 等特性回归）再合并；届时 run.bat 自愈可降级为纯兜底。
