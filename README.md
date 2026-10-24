# AliasAgent

Flutter 桌面 AI 对话应用，通过 dart:ffi 调用 C++ Sidecar 动态库。

## 环境要求

- Flutter 3.x+
- Visual Studio 2022（Windows 桌面开发）
- [vcpkg](https://github.com/microsoft/vcpkg)（C++ 依赖管理）
  - 安装后设置环境变量 `VCPKG_ROOT`
  - 已安装包：`curl`、`nlohmann-json`

## 构建 & 运行

Sidecar C++ 动态库需要单独编译，构建后 DLL 会自动部署到 Flutter runner 目录。

### 快速开始

```bash
# 1. 编译 sidecar DLL（clean rebuild）
bash scripts/rebuild_sidecar.sh

# 2. 运行应用
flutter run -d windows
```

### Rebuild 脚本

脚本执行：检测 vcpkg → clean → configure → build → 部署 DLL。

| 终端 | 命令 |
|------|------|
| Bash | `bash scripts/rebuild_sidecar.sh` |
| PowerShell | `.\scripts\rebuild_sidecar.ps1` |
| CMD | `scripts\rebuild_sidecar.bat` |

**参数：**

| 脚本 | Debug 构建 | Release 构建 | 构建后 run |
|------|-----------|-------------|-----------|
| `.sh` | `bash scripts/rebuild_sidecar.sh` | `bash scripts/rebuild_sidecar.sh Release` | `bash scripts/rebuild_sidecar.sh Debug false true` |
| `.ps1` | `.\scripts\rebuild_sidecar.ps1` | `.\scripts\rebuild_sidecar.ps1 -BuildType Release` | `.\scripts\rebuild_sidecar.ps1 -Run` |
| `.bat` | `scripts\rebuild_sidecar.bat` | `scripts\rebuild_sidecar.bat Release` | `scripts\rebuild_sidecar.bat Debug run` |

Windows 上还有仓库根的 `run.bat`：一键 `flutter build windows --debug` → 构建 Release sidecar 并拷 DLL → 跑单元冒烟 `flutter test test\unit\sidecar_bridge_test.dart` → 启动 app。要完整测试层次（含窗口 live、视觉回归、C++ 测试）见 [Docs/TESTING.md](Docs/TESTING.md)。

**部署目标目录：**
- `build/windows/x64/runner/Debug/sidecar.dll` — `flutter run` 加载
- `windows/sidecar.dll` — `flutter build` 打包
- `sidecar.dll` — 项目根目录

## 配置

首次启动应用会弹出设置对话框，引导输入 Anthropic API key。配置文件保存在 `~/.aliasagent/config.json`。

## 功能文档索引

每个功能一份使用说明（面向使用者，不假设你读过代码）：

| 功能 | 一句话说明 |
|------|-----------|
| [配置](Docs/user-guide/configuration.md) | 配置文件在哪、每个键什么意思、缺 key 或写错 JSON 会看到什么；`input_modalities` 决定模型能不能收图 |
| [对话](Docs/user-guide/chat.md) | 新建/删除会话、发消息、**贴图片给模型看**、工具卡片与思考卡片、会话标题 |
| [真实上下文视图](Docs/user-guide/real-context-view.md) | 看模型这一步**实际**收到了什么（系统提示词、工具、每条消息） |
| [上下文压缩](Docs/user-guide/context-compaction.md) | 对话变长后什么时候压、怎么认出来、阈值怎么调 |
| [文件工具](Docs/user-guide/tools-file.md) | 读写/编辑/查找文件这七个工具（含 `read_image` 让模型看图）、工作区边界、各类拒绝 |
| [联网工具](Docs/user-guide/tools-web.md) | 搜索、抓网页、当前时间；搜索可以走 DeepSeek 自己的（不用另买 key），也可以配付费服务 |
| [浏览器工具](Docs/user-guide/tools-browser.md) | 开真实浏览器窗口操作网页；下载与权限请求会被拦 |
| [命令行工具](Docs/user-guide/tools-command.md) | 在你自己的电脑上真的执行 PowerShell 命令；没有沙箱、不能事后撤销 |
| [常见现象与排查](Docs/user-guide/troubleshooting.md) | 看到某个报错是什么意思、下一步做什么、日志在哪 |

**两条最容易踩的前提：**

- **文件类工具只能碰工作区里的路径**，而工作区就是**你的用户主目录** —— 越界的路径会被直接拒绝（不会悄悄放行）。
- **`web_search` 需要付费搜索服务的 key**（`zhipuai` 或 `kimi`）；没配的话模型根本没有搜索工具。

## 测试

完整的测试流程、各层写法、实现规范和调试数据读取方式，见 **[Docs/TESTING.md](Docs/TESTING.md)**（测试分层、单元/widget/集成/live/侧车 C++/冒烟测试、报错处理、log/dmp/截屏输出、如何读 sidecar.log 与 crash 数据）。

| 层 | 命令 |
|----|------|
| Dart 单元 + widget | `flutter test test/unit/ test/widget/` |
| 集成（headless） | `flutter test test/integration/` |
| 窗口 live（真模型） | `flutter test --tags live --run-skipped integration_test/live_file_tools_test.dart -d windows` |
| C++ sidecar | `cmake -B sidecar/build/windows -S sidecar && cmake --build sidecar/build/windows --target sidecar_tests && ctest --test-dir sidecar/build/windows -C Debug` |
| 冒烟 + 视觉回归 | `bash test/smoke/run_all.sh` |
| 静态分析 | `flutter analyze` |

## 项目结构

```
├── lib/                    # Flutter 应用代码
│   ├── main.dart           # 入口 + ChatPage
│   ├── models/             # 数据模型
│   ├── services/           # Config、Repository、SidecarBridge
│   └── ui/                 # 界面组件
├── sidecar/                # C++ 动态库
│   ├── include/            # 头文件 (sidecar_api.h)
│   └── src/                # 实现 (model_gateway, tools)
├── test/                   # Flutter 单元/widget/集成/冒烟 + checkpoint 验证
├── integration_test/       # 窗口 live（真模型）测试套件
├── windows/                # Flutter Windows runner + DLL
├── scripts/                # 构建脚本
├── Docs/                   # 文档（TESTING.md 测试指南等）
├── DEBUGGING.md            # C++ sidecar 调试指南
└── openspec/               # 变更规格说明
```