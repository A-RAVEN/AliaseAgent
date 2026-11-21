/// Flutter 环境下的日志门面实现：把 `debugPrint` 原样接到 foundation 的全局变量上。
///
/// 必须是**同一个变量**（re-export，而不是转发函数），否则既有测试
/// `debugPrint = ...` 赋值的是 foundation 那份，核心代码读到的却是另一份。
library;

export 'package:flutter/foundation.dart' show debugPrint;

/// 当前实现标识（Flutter 环境）。诊断用。
const String kLoggingSink = 'flutter';

