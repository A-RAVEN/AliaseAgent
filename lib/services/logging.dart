/// 纯 Dart 日志门面（foundation 解耦，change `web-ui-core-shim` D8）。
///
/// 无头 Dart 核心（`dart run`）里没有 `package:flutter`，但核心 services 与
/// models 仍然需要 `debugPrint`。这里用条件导出两套实现：
///
/// - **Flutter / flutter test 环境**（`dart:ui` 存在）：直接导出
///   `package:flutter/foundation.dart` 的 `debugPrint` 全局变量。这样既有 9 处
///   `debugPrint = (String?, {int? wrapWidth}) {...}` 日志捕获测试**赋值的是同一个
///   变量**，一行测试都不用改。
/// - **纯 Dart VM 环境**（`dart run` / `dart test`）：导出一个与 foundation 同签名
///   的可重赋值全局函数变量，默认写 stdout。
///
/// 两套实现的名字与签名一致：`(String?, {int? wrapWidth})`，可重赋值。
library;

export 'logging_stub.dart' if (dart.library.ui) 'logging_flutter.dart';
