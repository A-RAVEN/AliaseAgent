@Tags(['live'])
library;

// 任务 4.2 的规范 live 入口（`integration_test/` 下的真模型用例）。
//
// 注意：`flutter test` 会把 `integration_test/` 下的一切当**设备测试**（要求 `-d`，
// 会起应用窗口）。本机无窗口运行请用镜像入口（同一个 suite）：
//   flutter test --tags live --run-skipped test/live/web_core_shim_live_test.dart
import 'package:flutter_test/flutter_test.dart';

import 'web_core_shim_live_support.dart';

void main() => runWebCoreShimLiveSuite();