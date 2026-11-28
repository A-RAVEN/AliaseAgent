@Tags(['live'])
library;

// 任务 10.1 的**无窗口** live 入口（change `custom-workspace`）。
//
// 为什么需要镜像入口：`flutter test` 只要测试文件位于 `integration_test/` 下就按设备
// 测试处理（要求 `-d <device>`，会拉起应用窗口）。本 change 的 live 走无头 Edge 通道，
// 所以把同一个 suite 从 `test/` 下跑：
//   flutter test --tags live --run-skipped test/live/web_workspace_live_test.dart
//
// 测试本体只有一份：`integration_test/web_workspace_live_support.dart`。设备态入口
// `integration_test/web_workspace_live_test.dart` 也调用同一个 suite。
import 'package:flutter_test/flutter_test.dart';

import '../../integration_test/web_workspace_live_support.dart';

void main() => runWebWorkspaceLiveSuite();
