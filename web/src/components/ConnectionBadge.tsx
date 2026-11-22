// 连接状态徽标（design D6：断线/重连中要有明确态）。
import type { ConnectionStatus } from '../protocol';

const labels: Record<ConnectionStatus, string> = {
  connecting: '连接中…',
  open: '已连接',
  reconnecting: '重连中…',
  closed: '已断开',
};

const classes: Record<ConnectionStatus, string> = {
  connecting: 'bg-warn/15 text-warn',
  open: 'bg-ok/15 text-ok',
  reconnecting: 'bg-warn/15 text-warn',
  closed: 'bg-danger/15 text-danger',
};

export function ConnectionBadge({ status }: { status: ConnectionStatus }) {
  return (
    <span
      data-testid="connection-status"
      className={`rounded-card px-2 py-1 text-xs ${classes[status]}`}
    >
      {labels[status]}
    </span>
  );
}
