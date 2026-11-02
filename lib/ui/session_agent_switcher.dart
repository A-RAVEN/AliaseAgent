import 'package:flutter/material.dart';

/// 当前会话工具栏上的 Agent 模板选择控件。
///
/// 它只负责**显示与选择**：当前 `Session.agentType`、可选模板名、是否可用与回调。
/// 真正的切换（候选预检 → 退役旧 Agent 对象 → 持久化并重读 Session → 创建新实例）
/// 由 `AgentSessionController` 做，界面不在这里直接改数据库或创建实例。
///
/// 禁用规则只有三种（对应规范「没有当前会话时只禁用模板选择控件」）：
/// 工具目录未就绪、没有当前会话、该 Session 正在切换或删除。**发送不因没有会话而
/// 被切断** —— 那条路径仍会自动创建 `general` Session，所以这里只禁用选择控件。
class SessionAgentSwitcher extends StatelessWidget {
  /// 模板注册表里的全部模板名（顺序即展示顺序）。
  final List<String> templateNames;

  /// 该会话当前保存的 `agent_type`。
  final String? current;

  /// 是否可用（工具未就绪 / 无当前会话 / 切换或删除中时为 false）。
  final bool enabled;

  /// 用户选中另一个模板时调用。
  final ValueChanged<String>? onChanged;

  const SessionAgentSwitcher({
    super.key,
    required this.templateNames,
    required this.current,
    this.enabled = true,
    this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final names = List<String>.from(templateNames);
    // 当前值不在模板列表里（例如数据库引用了一个已不存在的模板）时，不能把它塞给
    // DropdownButton（那会断言失败）；改成空值 + 提示文字，同时让错误继续由
    // `_agentError` 红条显示，不静默替换成别的模板名。
    final value = current != null && names.contains(current) ? current : null;
    final interactive = enabled && onChanged != null;
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(Icons.smart_toy_outlined,
            size: 18, color: theme.colorScheme.onSurfaceVariant),
        const SizedBox(width: 6),
        DropdownButtonHideUnderline(
          child: DropdownButton<String>(
            key: const ValueKey('session-agent-switcher'),
            value: value,
            hint: Text(current ?? '无模板'),
            isDense: true,
            focusColor: Colors.transparent,
            onChanged: interactive
                ? (selected) {
                    if (selected != null && selected != current) {
                      onChanged!(selected);
                    }
                  }
                : null,
            items: [
              for (final name in names)
                DropdownMenuItem<String>(
                  value: name,
                  child: Text(name, style: const TextStyle(fontSize: 13)),
                ),
            ],
          ),
        ),
      ],
    );
  }
}
