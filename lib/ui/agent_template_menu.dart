import 'package:flutter/material.dart';

import '../models/agent_type_config.dart';

/// Agent 模板列表（change `add-agent-object-and-templates` 任务 3.1）。
///
/// 只展示**模板**（名字、模型、推理强度）与添加 / 修改入口；运行实例不在这里。
/// **不显示 provider 密钥**：模板对象本身就没有这个字段，界面也没有任何读取密钥的路径。
class AgentTemplateMenu extends StatelessWidget {
  final List<AgentTypeConfig> templates;

  /// 修改某个模板（模板名只读，编辑器负责）。
  final ValueChanged<AgentTypeConfig>? onEdit;

  /// 添加新模板。
  final VoidCallback? onAdd;

  const AgentTemplateMenu({
    super.key,
    required this.templates,
    this.onEdit,
    this.onAdd,
  });

  /// 推理强度的界面文案：关闭时写"关闭"，否则写档位本身。
  static String thinkingLabel(AgentTypeConfig template) {
    final effort = template.thinkingEffort;
    return (effort == null || effort.isEmpty) ? '关闭' : effort;
  }

  /// 列表里那一行副标题：模型 + 推理强度（不含 provider 与密钥）。
  static String subtitleOf(AgentTypeConfig template) =>
      '模型：${template.model} · 推理：${thinkingLabel(template)}';

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return AlertDialog(
      title: const Row(
        children: [
          Icon(Icons.smart_toy_outlined, size: 20),
          SizedBox(width: 8),
          Text('Agents'),
        ],
      ),
      content: SizedBox(
        width: 420,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (templates.isEmpty)
              const Text('还没有任何 Agent 模板')
            else
              Flexible(
                child: ListView.separated(
                  shrinkWrap: true,
                  itemCount: templates.length,
                  separatorBuilder: (context, index) => const Divider(height: 1),
                  itemBuilder: (context, i) {
                    final template = templates[i];
                    return ListTile(
                      key: ValueKey('agent-template-${template.name}'),
                      dense: true,
                      title: Text(template.name),
                      subtitle: Text(
                        subtitleOf(template),
                        style: TextStyle(
                          fontSize: 12,
                          color: theme.colorScheme.onSurfaceVariant,
                        ),
                      ),
                      trailing: onEdit == null
                          ? null
                          : IconButton(
                              key: ValueKey('edit-template-${template.name}'),
                              icon: const Icon(Icons.edit_outlined, size: 18),
                              tooltip: '修改模板',
                              onPressed: () => onEdit!(template),
                            ),
                    );
                  },
                ),
              ),
            const SizedBox(height: 12),
            Text(
              kAgentTemplateEffectiveNote,
              key: const ValueKey('agent-template-effective-note'),
              style: TextStyle(
                fontSize: 12,
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ],
        ),
      ),
      actions: [
        if (onAdd != null)
          TextButton.icon(
            key: const ValueKey('add-template'),
            onPressed: onAdd,
            icon: const Icon(Icons.add, size: 18),
            label: const Text('添加模板'),
          ),
        TextButton(
          onPressed: () => Navigator.of(context).maybePop(),
          child: const Text('关闭'),
        ),
      ],
      actionsPadding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
    );
  }
}

/// 菜单底部的生效时机说明（界面与用户文档说同一句话）。
///
/// 抽成常量是为了让"界面文案"与"文档验收"能对上同一个字符串：改一处，两边一起变。
///
/// 口径（change `model-truth-from-gateway` D7）：**推理强度**每轮装配重解析，所以
/// 改它对已经跑着的对话从**下一条消息**起就生效；其余字段（窗口、工具、模型、系统
/// 提示词）仍是实例创建时冻结，只对新会话（之后创建或恢复的实例）生效。
const String kAgentTemplateEffectiveNote =
    '只有推理强度从下一条消息起对运行中对话生效，其余字段对新会话生效。';
