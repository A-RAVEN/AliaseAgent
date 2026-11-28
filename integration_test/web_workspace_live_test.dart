@Tags(['live'])
library;

// 工作路径的规范 live 入口（change `custom-workspace` 任务 10.1）。
//
// 注意：`flutter test` 会把 `integration_test/` 下的一切当**设备测试**（要求 `-d`，
// 会起应用窗口）。本机无窗口运行请用镜像入口（同一个 suite）：
//   flutter test --tags live --run-skipped test/live/web_workspace_live_test.dart
import 'package:flutter_test/flutter_test.dart';

import 'web_workspace_live_support.dart';

void main() => runWebWorkspaceLiveSuite();
