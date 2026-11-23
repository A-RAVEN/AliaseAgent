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
  | { code: 'no_trigger'; message: string }
  | { code: 'empty_view'; message: string }
  | { code: 'prefill'; message: string };

/**
 * 发送前校验（与核心的前置门同一口径，界面先给出可归因提示）：
 *
 * **开关开启**（`reactionsEnabled: true`，change `group-reactive-mode` D10）：
 *   - 发言人**可选**：空 + 有文本 = 纯触发（放行）；空 + 空文本 ⇒ `no_trigger`；
 *   - 选了发言人时的两个退化前置门照旧（不带文本 + 空视图 / 本人 assistant 结尾）。
 *
 * **开关关闭**：
 *   - 空 speaker + 文本含 `@` ⇒ 放行（`@` 的有效性由**核心**裁决，前端不复制
 *     mention 解析规则 —— 两份规则必然漂移）；
 *   - 空 speaker + 文本不含 `@` ⇒ `no_speaker`（旧本地校验）。
 *
 * `reactionsEnabled` 缺省 `false`：既有调用方与既有用例保持旧口径。
 */
export function validateSpeaker(args: {
  speaker: string | null;
  text: string;
  viewMessages: Message[];
  reactionsEnabled?: boolean;
}): SpeakerError | null {
  const speaker = args.speaker?.trim() ?? '';
  const reactionsEnabled = args.reactionsEnabled ?? false;
  const hasText = args.text.trim().length > 0;
  if (speaker.length === 0) {
    if (reactionsEnabled) {
      if (hasText) return null;
      return {
        code: 'no_trigger',
        message: '开启自发反应时必须输入一条消息（没有文本就没有可触发的公开消息）',
      };
    }
    if (hasText && args.text.includes('@')) return null;
    return { code: 'no_speaker', message: '请先选择一个发言人（群发送必须点名一个成员）' };
  }
  if (hasText) return null;
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

// ---------------------------------------------------------------------------
// 每组反应轮数上限（change `group-reactive-mode` R.4 / design D13）
// ---------------------------------------------------------------------------

/**
 * 产品默认上限。出处：design D13（`kDefaultMaxReactionRounds = 8`）——典型 3 人群聊
 * 的 2–3 个来回约 4–6 个反应轮，再加 2 轮评价/回应余量。**不是** `config.json` 键。
 */
export const kDefaultMaxReactionRounds = 8;

/** 上限的合法下界（design D13：范围 1..50；0 / 负数被拒绝，不静默截断）。 */
export const kMinMaxReactionRounds = 1;

/** 上限的合法上界（design D13）。 */
export const kMaxMaxReactionRounds = 50;

/** 「反应轮数上限」输入框的解析结果：值 / 恢复默认 / 可归因错误。 */
export type MaxRoundsParse =
  | { value: number | null }
  | { error: string };

/**
 * 解析输入框原文：留空 ⇒ `{value: null}`（`group.update {maxRounds: null}` = 恢复默认）；
 * 1..50 的整数 ⇒ `{value: N}`；其它（0 / 负数 / 越界 / 小数 / 非数字）⇒ 可归因错误。
 *
 * 越界**不静默改正**（design D10 / D13）：界面把核心的拒绝如实显示出来。
 */
export function parseMaxRoundsInput(raw: string): MaxRoundsParse {
  const trimmed = raw.trim();
  if (trimmed.length === 0) return { value: null };
  if (!/^\d+$/.test(trimmed)) {
    return {
      error: `反应轮数上限必须是 ${kMinMaxReactionRounds}..${kMaxMaxReactionRounds} 的整数，或留空恢复默认`,
    };
  }
  const value = Number(trimmed);
  if (value < kMinMaxReactionRounds || value > kMaxMaxReactionRounds) {
    return {
      error: `反应轮数上限必须在 ${kMinMaxReactionRounds}..${kMaxMaxReactionRounds} 之间（收到 ${value}）`,
    };
  }
  return { value };
}

/**
 * 链是否正在跑（界面据此禁用设置、显示活动指示、启用取消）。
 *
 * 三个来源任一成立即算在跑：核心的只读 `busy`、`group.chain` 的 `running`、本页
 * 观察到的流式成员。断线重连后前两个仍在，所以取消按钮不依赖本地发送状态
 * （design D10 / spec「断线重连后仍能取消」）。
 */
export function chainIsRunning(args: {
  busy: boolean;
  chainStatus: string | null;
  streamingMembers: number;
  sending?: boolean;
}): boolean {
  return (
    args.busy ||
    args.chainStatus === 'running' ||
    args.streamingMembers > 0 ||
    args.sending === true
  );
}
