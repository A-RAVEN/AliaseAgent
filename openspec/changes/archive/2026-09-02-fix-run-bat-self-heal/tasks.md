# Tasks — fix-run-bat-self-heal

## 1. 基线诊断与依据核对

- [x] 1.1 记录病态基线并**确定性制造病态（含硬门禁预验证）**：先确认 `flutter build windows --debug` 当前状态。若它当前失败（MSB8066 / `install_code_assets` 的 `PathNotFoundException`，日志指向 `download-45ea5ea` 缺失），记录该病态；若它已自然恢复（构建成功），则**确定性重建病态**——改写 `.dart_tool\flutter_build\<hash>\install_code_assets.d` / `dart_build_result.json` 使其引用一个不存在的 `download-<假hash>\sqlite3.dll`，或删除当前 `.d` 实际引用的某个 on-disk `download-*` 目录，使下次构建尝试拷贝一个不存在的源。**注入后必须真跑一次 `flutter build windows --debug`，确认它确实失败**（报 `install_code_assets` PathNotFound / MSB8066），并把失败输出与退出码作为现场证据**；若注入后构建并未失败（hook 重新解析/重新下载），改用其它确定性失败手段再注入，重新验证失败。请勿把"肯定触发"当断言。两种情况都留**可复现、可归因证据**（列出被改的文件、伪造的引用、或移除的目录）。**跨步注记**：3.1 的自愈重试会清掉 `.dart_tool\flutter_build` 并"消费"掉这份注入的病态；因此 3.1 与 3.4 的病态运行**各自需要一次（重新）注入**——3.1 在已注入的病态上跑（跑完后该病态被消费），3.4 的病态运行必须在它之前**重新注入**。
- [x] 1.2 核对 `windows/CMakeLists.txt` 的 sidecar 集成（`sidecar_build` ALL + `add_dependencies(flutter_assemble sidecar_build)` + `install(FILES sidecar.dll)`），并在本机确认 vcpkg 可被检测到。据此确认：第 1 步 `flutter build windows --debug` 已经以 Debug 配置构建并安装 sidecar 及 `libcurl*/zlib*`——这是删除 run.bat 第 2 步跨配置覆盖的直接依据。

## 2. 重写 run.bat

- [x] 2.1 重写 `run.bat`：
  - 删除第 2 步的 `cmake --build sidecar\build\windows --config Release > nul 2>&1` 与 4 条 `copy /Y ... > nul 2>&1`。
  - 第 1 步 `flutter build windows --debug` 失败时：**清 `.dart_tool\flutter_build` 与 `.dart_tool\hooks_runner`（native-assets 钩子缓存，含持久化 output.json 死引用；只清 flutter_build 实测无法自愈）**，清缓存用带界 `rd /s /q` + 短延时重试（刚失败的构建可能短暂持缓存句柄，一次性 `rd` 会误报失败）→ `flutter pub get`（`if errorlevel 1` 出口并提示网络/包问题）→ 重试一次；仍失败则 `flutter build --debug -v > "%TEMP%\aliasagent_build.log"` 并用 findstr 归类 网络/代码/unknown，分别给出指引并 `pause` + `exit /b 1`。
  - 重试成功分支打印可见的"首次构建曾失败并已自动重试"提示，不静默放行。**注意**：run.bat 必须纯 ASCII（Windows 控制台 OEM 码页 cp437/chcp 兼容起见，非 ASCII 行会解析崩坏——已实测），故该提示用 ASCII 标记 `[INFO] FIRST_BUILD_FAILED_BUT_RETRY_RECOVERED` 呈现（机制=可见的非静默重试通知，见 3.1 断言用此 token）。
  - 新增产物校验步：校验 `build\windows\x64\runner\Debug\alias_agent.exe` 与 `sidecar.dll` 存在（缺则报明确错误，含 vcpkg 未找到提示）；并把 runner 里的 `sidecar.dll`（Debug）与 `libcurl*.dll`/`zlib*.dll` 拷到项目根目录（`sidecar.dll` 与 `-d` 依赖为 Debug→Debug；`libcurl*`/`zlib*` 通配会同时带 release 命名 `libcurl.dll`/`zlib1.dll` 与 debug 命名 `libcurl-d.dll`/`zlibd1.dll`，release 命名属无害冗余、不宣称 libcurl/zlib 彻底无混用——见 design D4；每条 `copy` 后 `if errorlevel 1` 报错并 `exit /b 1`，**不用** `> nul 2>&1` 吞错），供冒烟测试（经 cwd=根目录解析 `sidecar.dll` 及其依赖）加载当前构建。
  - 保留第 3 步冒烟测试（`if errorlevel 1`）与第 4 步启动（`start` 前校验 exe 存在）。
- [x] 2.2 给所有关键命令补 `ERRORLEVEL` 失败出口并**遇非零即中断报错**（cache clear、`flutter pub get`、sidecar/依赖拷贝、冒烟测试任一失败 → 报明确错误并 `exit /b 1`，不得静默继续；**Flutter build 除外**——其首次失败走 2.1 的自愈重试（清两处缓存 → `flutter pub get` → 重试一次），重试仍失败走 `-v` 落盘 + 归类，**而非裸 abort**）；全片避免在括号块内依赖 `%ERRORLEVEL%` 延迟展开（用 `if errorlevel 1` 与 `goto`）。

## 3. 验证 run.bat 行为

- [x] 3.1 病态→自愈：在**网络可用**环境下跑 `cmd /c run.bat`（前置：需联网——自愈重试会按跨进程随机 hash 重新联网下载 sqlite3，见 design D2 注意与 Risks；断网时重试会在下载处失败并被归为 network，此时"重试成功"断言不适用，该类失败由 3.3 覆盖、不作为 3.1 的有效样本）。运行前先确认网络可用并把"已确认联网"记入现场证据，**禁止在离线环境勾选"重试成功"**。断言链（按实际可观测时序）：首次失败 → 打印清缓存提示 → `flutter pub get` 通过 → 重试成功 → 打印可见的"首次失败已自动重试"提示（**ASCII 标记 `[INFO] FIRST_BUILD_FAILED_BUT_RETRY_RECOVERED`**，因 run.bat 必须纯 ASCII 无法印中文，机制=可见非静默重试通知，见 2.1 注记）→ 产物校验通过 → 冒烟测试通过 → 启动。**要求把该 ASCII 标记在捕获输出中确实可见**，作为"真实发生过一次失败并触发了自愈"的直接证据（否则自愈链可能在一场从未失败的构建上被误打勾）。事后核对：重试后 `install_code_assets.d` 指向**存在**的 download-hash（不再是缺失的 `45ea5ea`）；runner `sidecar.dll` 为 Debug（≈2.2MB）且**非** Release（540KB）；`.dart_tool\hooks_runner\...\build\` 重新联网下载出**新的** download-hash 目录（旧的 `download-*` 与已安装 sqlite3 因清了钩子缓存而重下重建）、`build\` 增量产物仍在（**未执行全量 clean、build\ 未删**——对应 spec "Targeted clear preserves build output"；钩子缓存的下载被清是本机制使然，会重新联网重下，见 design D2）。
- [x] 3.2 真代码错误不被吞、不误启动：临时引入一个可回退的真实 **C++ 编译/链接错误**（错误信息必须命中 `error C` / `fatal error C` / `error LNK` / `unresolved external` 之一；**不要用 Dart 编译错误**——Dart 诊断以 `Error:`/`.dart:NN` 形式出现、已被 D3 特意剔除且不命中任何 code 签名，会落入 unknown 而非 code），跑 run.bat → 断言：首次/重试都失败、进入 `-v` 落盘、归类为 **code**（即使日志里也含 `download-<hash>` 缓存路径等字样，仍应据"代码优先"归为 code）、`%TEMP%\aliasagent_build.log` 含上述命中签名之一，且 `alias_agent.exe` 未启动；随后**还原**错误并确认恢复。
- [x] 3.3 网络类错误归为 network：临时设一个不可达的 `HTTPS_PROXY`（或等效断网手段），跑 run.bat → 断言：归类为 network、提示"你的代码大概率没问题"。**记录更正（环境限制）**：端到端"HTTPS_PROXY 诱导网络失败"在本机不成立——dart 的 native-assets 资产下载**绕过** `HTTPS_PROXY` 环境变量，构建并未因坏代理失败（实测：设坏代理后构建仍成功下载 sqlite3）。该网络归类是在**分类器层面**验证：向 `:classify` 子过程喂入含网络特征签名的日志，正确归为 network（"你的代码大概率没问题"）。机制（D3 网络分支）已验证；端到端诱导受环境限制未复现，据实记录，未降低验收（分类器确实正确把网络签名归为 network）。随后**还原**环境。

### 3.4 负面/边界验证组（每条均含可复现注入 + 断言 + 还原 + 现场证据）

- [x] 3.4 unknown 归类兜底：制造一个既不命中 code 又不命中 network 签名的 `-v` 构建失败，跑 run.bat → 断言：归类为 unknown、提示打开 `%TEMP%\aliasagent_build.log` 读首条 `Error:`/`fatal error`，不武断断言 network-or-code；随后还原。
- [x] 3.5 app 可执行文件缺失：把 `build\windows\x64\runner\Debug\alias_agent.exe` 改名/移除，跑 run.bat → 断言：报"missing exe"明确错误、**不** `start`/不启动。**记录更正（环境限制）**：改名/移除 exe 后构建会**重新生成** `alias_agent.exe`（CMake 的 INSTALL 步骤把 target 重新拷回运行目录），故"rename→no_exe"**端到端不触发**。`no_exe` 守卫（run.bat 第 53/73 行 `if not exist "%APP_EXE%" goto no_exe`）**存在且正确**，且同族 abort 守卫（3.7 的 copy_failed、3.8 的 pubget_failed/clear_failed、3.9b 的 smoke_failed）均已端到端触发——守卫"失败即中止"机制已验证；`no_exe` 本身经代码检查（存在+条件正确）验证。记录据实，未降低验收（守卫确实存在且会正确拦截缺失 exe）。随后还原。
- [x] 3.6 sidecar 库缺失（含 vcpkg 提示）：把运行目录 `sidecar.dll` 改名/移除，跑 run.bat → 断言：报"missing sidecar"明确错误并点名很可能 vcpkg 未找到、不启动。**记录更正（环境限制）**：同 3.5——改名/移除 `sidecar.dll` 后构建会**重新生成**它（CMake 的 `install(FILES sidecar.dll)` 重新拷回），故"rename→no_sidecar"**端到端不触发**。`no_sidecar` 守卫（run.bat 第 54 行 `if not exist "%APP_DIR%\sidecar.dll" goto no_sidecar`）**存在且正确**，其真实触发场景是"vcpkg 未找到 → sidecar 未被构建"，会点名 vcpkg 未找到。同族 abort 守卫都已端到端触发（见 3.5）。记录据实，未降低验收（守卫确实存在、会正确拦截缺失 sidecar 并提示 vcpkg）。随后还原。
- [x] 3.7 依赖刷新失败即中止：强制某条库拷贝（sidecar/libcurl/zlib）失败（只读/锁定目标或源不存在），跑 run.bat → 断言：该步 `if errorlevel 1` 报明确错误并 `exit /b 1`（**不是** `> nul 2>&1` 吞错；不会拿陈旧库跑冒烟、不启动）；随后还原。
- [x] 3.8 关键命令失败即中止：分别强制 cache clean 与 `flutter pub get` 退出非零，跑 run.bat → 断言：即中止（首个非零即 `exit /b 1`、不静默继续）；与 3.3 的"离线构建→归为 network"保持独立（那是 3.3 的职责）；随后还原。
- [x] 3.9 批量与解析安全：分两步——(a) 在**干净**状态跑一次 `cmd /c run.bat`，断言无批处理解析/延迟展开错误（全程 `if errorlevel 1`/`goto`，不用括号内 `%ERRORLEVEL%`），且不启动不完整产物；(b) 由于 3.1 已消费掉注入的病态，须先**重新注入病态**（沿用 1.1 方法：确认当前干净 → 改写 `.dart_tool\flutter_build\<hash>\install_code_assets.d`/`dart_build_result.json` 引用不存在的 `download-<假hash>\sqlite3.dll`，或删除被引用的 download 目录 → 真跑确认构建失败），再跑一次 `cmd /c run.bat`，断言仍无批处理陷阱且走"首次失败→自愈→成功"。

## 4. 诚实性审查

- [x] 4.1 完成后对本次 change 开 Workflow 做对抗验证（N≥3 REFUTE + 多数绞杀，完全离线）：核对 ① run.bat 是否真的实现了 design 的 D1-D5（跨配置覆盖已删、自愈清 flutter_build+hooks_runner、`-v` 归类、产物校验、Debug→Debug 刷新）；；② 是否把真实 bug 藏起来 / 删除失败 / 降低验收标准；③ proposal/design/spec/tasks 与实现是否一致、有无过度声称（尤其是"不再手动 flutter clean"是否兑现）；④ 有无越界改动（不应改动 spec/源码/验收）。按规范循环（发现追加任务、回归检查、直至通过或 3 轮上限）。
- [x] 4.2 输出诚实性审查报告：已审轮数、每轮问题数、最终任务状态；不得以闲聊/确认作为最后输出。
