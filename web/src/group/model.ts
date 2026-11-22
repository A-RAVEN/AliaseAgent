// 组视图的纯逻辑（change `agent-group-chat` 任务 8.2 / design D11）。
//
// 抽成纯函数是为了让分组规则、发言人校验与占用环分母都能用 vitest 证明，不必起浏览器：
//   - `splitGroupMessages`：一份原文 → 公开时间线 + 每成员私有分栏（含「已移除」栏）；
//   - `validateSpeaker`：空视图 / 本人 assistant 结尾两种退化发送的前置拒绝；
//   - `ringDenominator`：占用环分母 = **该成员自己**实例的窗口。
import type { ContextBreakdown, GroupMemberSummary, Message } from '../protocol';

export interface GroupLane {
  memberId: string;
  name: string;
  removed: boolean;
  messages: Message[];
}

export interface GroupTimelineItem {
  seq: number | null;
  author: string | null;
  authorName: string | null;
  content: string;
  role: 'user' | 'assistant';
}

export interface GroupSplit {
  timeline: GroupTimelineItem[];
  lanes: GroupLane[];
}

/** 成员 id → 显示名（含已移除成员：历史行一直要有归属）。 */
export function memberNames(members: GroupMemberSummary[]): Map<string, string> {
  return new Map(members.map((member) => [member.id, member.name]));
}

/**
 * 把一页（或多页）消息拆成公开时间线 + 成员私有分栏。
 *
 * 规则（spec「加载页内的行都有归属去处」）：
 *   - `public` 行 → 时间线（用户消息与成员公开回复都带作者归属）；
 *   - `private-to-author` 行 → 该作者的私有分栏（分栏头标"仅该成员可见"）；
 *   - 已移除成员也有一栏（标「已移除」），历史私有行有去处；
 *   - 同一行不丢、不重复显示。
 */
export function splitGroupMessages(
  messages: Message[],
  members: GroupMemberSummary[],
): GroupSplit {
  const names = memberNames(members);
  const laneMap = new Map<string, GroupLane>();
  for (const member of members) {
    laneMap.set(member.id, {
      memberId: member.id,
      name: member.name,
      removed: member.removedAt !== null,
      messages: [],
    });
  }

  const timeline: GroupTimelineItem[] = [];
  for (const message of messages) {
    if (message.visibility === 'private-to-author' && message.author !== null) {
      const lane = laneMap.get(message.author);
      // 作者不在成员表里（脏数据）：不静默丢行，落到一个显式的"未知作者"栏。
      if (lane) {
        lane.messages.push(message);
      } else {
        laneMap.set(message.author, {
          memberId: message.author,
          name: message.author,
          removed: true,
          messages: [message],
        });
      }
      continue;
    }
    timeline.push({
      seq: message.seq,
      author: message.author,
      authorName: message.author === null ? null : names.get(message.author) ?? message.author,
      content: message.content,
      role: message.role,
    });
  }

  return { timeline, lanes: [...laneMap.values()] };
}

/** 发言人校验的结果：`null` = 可以发送；否则是可归因的拒绝文案。 */
export type SpeakerError =
  | { code: 'no_speaker'; message: string }
  | { code: 'empty_view'; message: string }
  | { code: 'prefill'; message: string };

/**
 * 发送前校验（与核心的前置门同一口径，界面先给出可归因提示）：
 *   - 没选发言人 ⇒ no_speaker；
 *   - 不带文本且视图为空 ⇒ empty_view（绝不发空 messages）；
 *   - 不带文本且最后一条可见项是本人 assistant ⇒ prefill。
 */
export function validateSpeaker(args: {
  speaker: string | null;
  text: string;
  viewMessages: Message[];
}): SpeakerError | null {
  const speaker = args.speaker?.trim() ?? '';
  if (speaker.length === 0) {
    return { code: 'no_speaker', message: '请先选择一个发言人（群发送必须点名一个成员）' };
  }
  if (args.text.trim().length > 0) return null;
  if (args.viewMessages.length === 0) {
    return {
      code: 'empty_view',
      message: '该成员的视图为空：不带文本点名会发出空 messages，已被拒绝；请带一条用户消息',
    };
  }
  const last = args.viewMessages[args.viewMessages.length - 1];
  if (last.role === 'assistant' && last.author === speaker) {
    return {
      code: 'prefill',
      message: '该成员视图的最后一条可见项是它自己的回复：不带文本会退化成续写，已被拒绝；请带用户文本',
    };
  }
  return null;
}

/**
 * 占用环的分母 = **该成员自己实例的窗口**（不是共享分母）。
 *
 * 快照里的 `breakdown.windowTokens` 由核心按该成员实例的生效窗口给出；这里只在
 * breakdown 缺失时退回快照窗口，绝不回落到别的成员的窗口。
 */
export function ringDenominator(snapshot: {
  windowTokens: number;
  breakdown: ContextBreakdown | null;
}): number {
  if (snapshot.breakdown && snapshot.breakdown.windowTokens > 0) {
    return snapshot.breakdown.windowTokens;
  }
  return snapshot.windowTokens;
}
