@Tags(['live'])
library;

// 任务 4.2 的**无窗口** live 入口。
//
// 为什么需要这个镜像入口：`flutter test` 只要测试文件位于 `integration_test/` 下就
// 按设备测试处理（要求 `-d <device>`，会拉起应用窗口）。任务 4.2 明确要求走无头
// 浏览器通道、不准擅自开窗，所以把同一个 suite 从 `test/` 下跑：
//   flutter test --tags live --run-skipped test/live/web_core_shim_live_test.dart
//
// 测试本体只有一份：`integration_test/web_core_shim_live_support.dart`。设备态入口
// `integration_test/web_core_shim_live_test.dart` 也调用同一个 suite。
import 'package:flutter_test/flutter_test.dart';

import '../../integration_test/web_core_shim_live_support.dart';

void main() => runWebCoreShimLiveSuite();
