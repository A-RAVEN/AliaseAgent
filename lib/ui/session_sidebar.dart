import 'package:flutter/material.dart';

import '../models/session.dart';

class SessionSidebar extends StatelessWidget {
  final List<Session> sessions;
  final String? currentId;
  final VoidCallback onNewChat;
  final ValueChanged<Session> onSelect;
  final ValueChanged<Session> onDelete;

  /// 打开 Agent 模板菜单（change `add-agent-object-and-templates` 任务 3.1）。
  /// 为 null 时不显示入口（既有只读用例不需要它）。
  final VoidCallback? onAgents;

  /// 打开 Provider 管理页（change `add-provider-model-discovery` 任务 4.1）。
  /// 为 null 时不显示入口。
  final VoidCallback? onProviders;

  const SessionSidebar({
    super.key,
    required this.sessions,
    required this.currentId,
    required this.onNewChat,
    required this.onSelect,
    required this.onDelete,
    this.onAgents,
    this.onProviders,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      width: 250,
      color: theme.colorScheme.surfaceContainerLowest,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 12, 12, 8),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                FilledButton.icon(
                  onPressed: onNewChat,
                  icon: const Icon(Icons.add, size: 18),
                  label: const Text('New Chat'),
                ),
                if (onAgents != null) ...[
                  const SizedBox(height: 6),
                  OutlinedButton.icon(
                    key: const ValueKey('agents-entry'),
                    onPressed: onAgents,
                    icon: const Icon(Icons.smart_toy_outlined, size: 18),
                    label: const Text('Agents'),
                  ),
                ],
                if (onProviders != null) ...[
                  const SizedBox(height: 6),
                  OutlinedButton.icon(
                    key: const ValueKey('providers-entry'),
                    onPressed: onProviders,
                    icon: const Icon(Icons.hub_outlined, size: 18),
                    label: const Text('Providers'),
                  ),
                ],
              ],
            ),
          ),
          const Divider(height: 1),
          Expanded(
            child: sessions.isEmpty
                ? Center(
                    child: Padding(
                      padding: const EdgeInsets.all(24),
                      child: Text(
                        'No conversations yet',
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: theme.colorScheme.onSurfaceVariant,
                        ),
                      ),
                    ),
                  )
                : ListView.builder(
                    itemCount: sessions.length,
                    itemBuilder: (_, i) => _SessionTile(
                      session: sessions[i],
                      isSelected: sessions[i].id == currentId,
                      onTap: () => onSelect(sessions[i]),
                      onDelete: () => onDelete(sessions[i]),
                    ),
                  ),
          ),
        ],
      ),
    );
  }
}

class _SessionTile extends StatelessWidget {
  final Session session;
  final bool isSelected;
  final VoidCallback onTap;
  final VoidCallback onDelete;

  const _SessionTile({
    required this.session,
    required this.isSelected,
    required this.onTap,
    required this.onDelete,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final bgColor = isSelected
        ? theme.colorScheme.secondaryContainer
        : Colors.transparent;

    return Container(
      color: bgColor,
      child: ListTile(
        dense: true,
        title: Text(
          session.title,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(
            fontSize: 13,
            fontWeight: isSelected ? FontWeight.w600 : FontWeight.normal,
          ),
        ),
        subtitle: Text(
          _formatTime(session.updatedAt),
          style: TextStyle(fontSize: 11, color: theme.colorScheme.onSurfaceVariant),
        ),
        onTap: onTap,
        trailing: IconButton(
          icon: Icon(Icons.close, size: 16, color: theme.colorScheme.onSurfaceVariant),
          onPressed: onDelete,
          tooltip: 'Delete session',
        ),
      ),
    );
  }

  String _formatTime(int ms) {
    final dt = DateTime.fromMillisecondsSinceEpoch(ms);
    final now = DateTime.now();
    if (dt.year == now.year && dt.month == now.month && dt.day == now.day) {
      return '${dt.hour.toString().padLeft(2, '0')}:${dt.minute.toString().padLeft(2, '0')}';
    }
    return '${dt.month}/${dt.day} ${dt.hour.toString().padLeft(2, '0')}:${dt.minute.toString().padLeft(2, '0')}';
  }
}