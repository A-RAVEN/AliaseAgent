## MODIFIED Requirements

### Requirement: 无头核心进程独立启动并回显访问地址
系统 SHALL 提供一个不依赖 Flutter 渲染的无头 Dart 核心入口，复用现有业务 services 与 dart:ffi 加载的 C++ sidecar。核心 SHALL 仅绑定回环地址，监听端口由 OS 分配（port 0），并在启动输出中回显实际可访问的 `http://127.0.0.1:<port>` 地址。系统 MUST NOT 写死固定端口魔数。**配置文件不存在时 SHALL 以空配置启动并 serve 首启向导**（web-management-ui 引入，修改原 notFound 拒启动门），使 web 端能独立完成首启；配置 malformed 仍 SHALL 可归因失败。

#### Scenario: 启动无头核心
- **WHEN** 以无头入口启动核心进程
- **THEN** 进程不依赖 Flutter 引擎即可运行，加载 sidecar 成功，并在输出中回显一个 OS 实际分配的回环 URL

#### Scenario: 端口由 OS 分配
- **WHEN** 核心启动时请求监听端口
- **THEN** 使用 port 0 让 OS 分配可用端口，回显的端口与实际监听端口一致，而非任何写死的常量

#### Scenario: 空配置启动供向导
- **WHEN** 配置文件不存在时启动无头核心
- **THEN** 核心以空配置启动并 serve 首启向导（而非拒启动退出），web 可打开完成首启配置

#### Scenario: 坏配置仍可归因失败
- **WHEN** 配置文件存在但 malformed
- **THEN** 核心可归因失败（指明配置损坏），不静默以空配置覆盖