import 'package:flutter/material.dart';

import '../models/compaction_status.dart';

/// 界面上那条"正在压缩"的提示。两个视图共用这一份实现：对话视图把它放在输入框
/// 上方，真实上下文视图把它固定在本屏顶部（那时要加 [forContextView] 的那句附注）。
///
/// 空闲时（[CompactionStatus.isIdle]）它渲染 [SizedBox.shrink] —— 不留高度、不加
/// 分隔线，所以没有压缩在进行时既有布局与截图一模一样。
class CompactionStatusBanner extends StatelessWidget {
  /// 两个视图与测试统一用这个 key 找它。
  static const Key bannerKey = Key('compaction-status-banner');

  /// 真实上下文视图额外显示的一句：这一屏按定义只显示真正发出去的那一份，压缩期间
  /// 它不会变，不写这句用户会以为它在刷新。
  static const String contextViewNote = '下面是上一次实际发出的内容，压缩结果下次发送时才出现';

  final CompactionStatus status;

  /// 真实上下文视图那份要多一句 [contextViewNote]。
  final bool forContextView;

  const CompactionStatusBanner({
    super.key,
    required this.status,
    this.forContextView = false,
  });

  @override
  Widget build(BuildContext context) {
    final label = status.label;
    if (label == null) {
      // 空闲：什么都不占。
      return const SizedBox.shrink();
    }
    final theme = Theme.of(context);
    final onContainer = theme.colorScheme.onSecondaryContainer;
    return Container(
      key: bannerKey,
      width: double.infinity,
      color: theme.colorScheme.secondaryContainer,
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Padding(
            padding: EdgeInsets.only(top: 1),
            child: SizedBox(
              width: 13,
              height: 13,
              child: CircularProgressIndicator(strokeWidth: 2),
            ),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  label,
                  style: TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.w600,
                    color: onContainer,
                  ),
                ),
                if (status.note != null)
                  Text(
                    status.note!,
                    style: TextStyle(
                      fontSize: 11,
                      color: onContainer.withValues(alpha: 0.85),
                    ),
                  ),
                if (forContextView)
                  Text(
                    contextViewNote,
                    style: TextStyle(
                      fontSize: 11,
                      color: onContainer.withValues(alpha: 0.85),
                    ),
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
