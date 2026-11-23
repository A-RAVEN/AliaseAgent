@Tags(['live'])
library;

// 自发反应的**无窗口** live 入口（change `group-reactive-mode` 任务 7.1）。
//
// 为什么需要镜像入口：`flutter test` 只要文件在 `integration_test/` 下就按设备测试处理
// （要求 `-d <device>`，会拉起应用窗口）。无窗口跑法：
//   flutter test --tags live --run-skipped test/live/group_reaction_live_test.dart
//
// 测试本体只有一份：`integration_test/group_reaction_live_support.dart`。
import 'package:flutter_test/flutter_test.dart';

import '../../integration_test/group_reaction_live_support.dart';

void main() => runGroupReactionLiveSuite();
