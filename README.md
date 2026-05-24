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

**部署目标目录：**
- `build/windows/x64/runner/Debug/sidecar.dll` — `flutter run` 加载
- `windows/sidecar.dll` — `flutter build` 打包
- `sidecar.dll` — 项目根目录

## 配置

首次启动应用会弹出设置对话框，引导输入 Anthropic API key。配置文件保存在 `~/.aliasagent/config.json`。

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
├── windows/                # Flutter Windows runner + DLL
├── scripts/                # 构建脚本
└── openspec/               # 变更规格说明
```