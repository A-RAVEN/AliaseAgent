@Tags(['live'])
library;

// 自发反应的真实模型 live 入口（change `group-reactive-mode` 任务 7.1）。
//
// 规范入口：`flutter test --tags live --run-skipped integration_test/group_reaction_live_test.dart -d windows`
//
// 测试本体只有一份：`integration_test/group_reaction_live_support.dart`（suite）。
// 无窗口镜像入口：`test/live/group_reaction_live_test.dart`（同一个 suite）。
//
// 跑完必须用 `read_image` 读 `test/live_visual/group_reactions_live.png` 做视觉验收；
// 「实质评价」由人读打印出的 finalText / 时间线判断（结构断言只覆盖可失败的部分）。
import 'package:flutter_test/flutter_test.dart';

import 'group_reaction_live_support.dart';

void main() => runGroupReactionLiveSuite();
