// 组视图的纯逻辑测试（change `agent-group-chat` 任务 8.2）。
import { describe, expect, it } from 'vitest';

import type { GroupMemberSummary, Message } from '../protocol';
import {
  ringDenominator,
  splitGroupMessages,
  validateSpeaker,
} from './model';

function message(
  seq: number,
  overrides: Partial<Message> = {},
): Message {
  return {
    id: `m${seq}`,
    seq,
    sessionId: 'g1',
    role: 'user',
    content: `第 ${seq} 条`,
    toolCalls: null,
    thinking: null,
    tokenCount: null,
    outputTokenCount: null,
    createdAt: seq,
    attachments: [],
    author: null,
    visibility: 'public',
    ...overrides,
  };
}

const members: GroupMemberSummary[] = [
  {
    id: 'a',
    name: '甲',
    template: 'general',
    removedAt: null,
    overrides: null,
    effective: { tools: ['read_file'] },
  },
  {
    id: 'b',
    name: '乙',
    template: 'general',
    removedAt: null,
    overrides: null,
    effective: { tools: ['list_dir'] },
  },
  {
    id: 'c',
    name: '丙',
    template: 'general',
    removedAt: 100,
    overrides: null,
    effective: null,
  },
];

describe('splitGroupMessages', () => {
  it('公开行走时间线；私有行走各自分栏；已移除成员仍有栏', () => {
    const split = splitGroupMessages(
      [
        message(1, { content: '用户说的' }),
        message(2, {
          role: 'assistant',
          author: 'a',
          content: '甲的公开回复',
        }),
        message(3, {
          role: 'assistant',
          author: 'a',
          visibility: 'private-to-author',
          content: '',
        }),
        message(4, {
          role: 'assistant',
          author: 'c',
          visibility: 'private-to-author',
          content: '',
        }),
      ],
      members,
    );

    expect(split.timeline.map((item) => item.content)).toEqual([
      '用户说的',
      '甲的公开回复',
    ]);
    expect(split.timeline[0].authorName).toBeNull();
    expect(split.timeline[1].authorName).toBe('甲');

    const laneA = split.lanes.find((lane) => lane.memberId === 'a')!;
    const laneB = split.lanes.find((lane) => lane.memberId === 'b')!;
    const laneC = split.lanes.find((lane) => lane.memberId === 'c')!;
    expect(laneA.messages.length).toBe(1);
    expect(laneB.messages.length).toBe(0);
    expect(laneC.removed).toBe(true);
    expect(laneC.messages.length).toBe(1);
    expect(laneC.name).toBe('丙');
  });

  it('不丢行、不重复：时间线条目 + 各分栏条目 = 原文条数', () => {
    const messages = [
      message(1),
      message(2, { role: 'assistant', author: 'a' }),
      message(3, { author: 'b', visibility: 'private-to-author' }),
      message(4, { role: 'assistant', author: 'b' }),
    ];
    const split = splitGroupMessages(messages, members);
    const laneTotal = split.lanes.reduce((sum, lane) => sum + lane.messages.length, 0);
    expect(split.timeline.length + laneTotal).toBe(messages.length);
  });
});

describe('validateSpeaker', () => {
  it('没选发言人 ⇒ no_speaker', () => {
    expect(
      validateSpeaker({ speaker: null, text: '说话', viewMessages: [] })?.code,
    ).toBe('no_speaker');
  });

  it('不带文本且视图为空 ⇒ empty_view', () => {
    expect(
      validateSpeaker({ speaker: 'a', text: '', viewMessages: [] })?.code,
    ).toBe('empty_view');
  });

  it('不带文本且最后是本人 assistant ⇒ prefill', () => {
    const view = [message(1), message(2, { role: 'assistant', author: 'a' })];
    expect(
      validateSpeaker({ speaker: 'a', text: '  ', viewMessages: view })?.code,
    ).toBe('prefill');
  });

  it('不带文本且最后是用户消息 ⇒ 允许', () => {
    const view = [message(1, { role: 'assistant', author: 'a' }), message(2)];
    expect(validateSpeaker({ speaker: 'a', text: '', viewMessages: view })).toBeNull();
  });

  it('带文本总是允许（由核心决定后续）', () => {
    expect(
      validateSpeaker({ speaker: 'a', text: '说一句', viewMessages: [] }),
    ).toBeNull();
  });
});

describe('ringDenominator', () => {
  it('分母是该成员自己实例的窗口，不是共享分母', () => {
    const a = {
      windowTokens: 1_000_000,
      breakdown: {
        level2Tokens: 1,
        level1Tokens: 2,
        rawTokens: 3,
        fixedOverheadTokens: 4,
        windowTokens: 1_000_000,
        usedTokens: 10,
        conversationTokens: 6,
      },
    };
    const b = {
      windowTokens: 200_000,
      breakdown: {
        level2Tokens: 0,
        level1Tokens: 0,
        rawTokens: 5,
        fixedOverheadTokens: 1,
        windowTokens: 200_000,
        usedTokens: 6,
        conversationTokens: 5,
      },
    };
    expect(ringDenominator(a)).toBe(1_000_000);
    expect(ringDenominator(b)).toBe(200_000);
    expect(ringDenominator(a)).not.toBe(ringDenominator(b));
  });

  it('没有 breakdown 时退回快照窗口（不借用别人的窗口）', () => {
    expect(ringDenominator({ windowTokens: 32000, breakdown: null })).toBe(32000);
  });
});
