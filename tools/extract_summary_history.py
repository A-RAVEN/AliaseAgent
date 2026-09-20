"""把上下文压缩后的「模型实际看到的投影」抽成一份聊天窗口样式的文档。

顺序与产品一致：**L2 → L1 → 原文**（原文 = 最后一条摘要覆盖范围之后的近端消息）。
排序规则照抄 `lib/main.dart` 的投影组装：按 (covered_min_seq 升序, covered_max_seq 降序,
level 降序) —— L2 覆盖同一段时排在其 L1 之前，从而**取代**它们。

字段/常量全部取自产品代码，不凭印象：
  - 表结构：`lib/services/database_service.dart`（messages / summary_nodes）
  - 摘要文本的 JSON 形状：role blocks，`content[].type == 'text'`
  - 注入前缀：`lib/services/compaction/summary_provider.dart`
      kSummaryMarker      = '## 更早上下文(压缩xN,非用户发言)'      （L1）
      kLevel2SummaryMarker= '## 更早上下文(压缩xN,层级2,非用户发言)' （L2）

两种数据源，可单用也可合用：
  --db PATH --session ID|latest   产品库：摘要 + 完整原文（推荐，原文只能从这里拿到）
  --run-output FILE               live 测试的控制台输出：至少能拿到摘要全文（[OBS] dump 未截断）

用法：
  python tools/extract_summary_history.py --db "%TEMP%\\aliasagent_compact_xxx\\aliasagent.db" --out Docs/context-history.md
  python tools/extract_summary_history.py --run-output "%TEMP%\\compact_live.txt" --out /tmp/ctx.md
"""

from __future__ import annotations

import argparse
import json
import os
import re
import sqlite3
import sys

L1_MARKER = '## 更早上下文(压缩xN,非用户发言)'
L2_MARKER = '## 更早上下文(压缩xN,层级2,非用户发言)'


# ---------------------------------------------------------------- 数据源：产品库

def read_db(db_path: str, session: str):
    """返回 (session_row, summaries, messages)。只读打开，绝不写库。"""
    uri = 'file:%s?mode=ro' % db_path.replace('\\', '/').replace('?', '%3f')
    con = sqlite3.connect(uri, uri=True)
    con.row_factory = sqlite3.Row
    try:
        cur = con.cursor()
        if session in ('latest', '', None):
            row = cur.execute(
                'SELECT * FROM sessions ORDER BY updated_at DESC LIMIT 1').fetchone()
        else:
            row = cur.execute(
                'SELECT * FROM sessions WHERE id = ? OR id LIKE ? LIMIT 1',
                (session, session + '%')).fetchone()
        if row is None:
            raise SystemExit('找不到会话：%s' % session)
        sid = row['id']
        summaries = [dict(r) for r in cur.execute(
            """SELECT id, level, node_type, covered_min_seq, covered_max_seq,
                      token_cost, summary_json, model
               FROM summary_nodes WHERE session_id = ?""", (sid,))]
        messages = [dict(r) for r in cur.execute(
            """SELECT id, seq, role, content, tool_calls, thinking_json, created_at
               FROM messages WHERE session_id = ? ORDER BY seq ASC""", (sid,))]
        return dict(row), summaries, messages
    finally:
        con.close()


# ------------------------------------------------------- 数据源：live 测试输出

_NODE_RE = re.compile(
    r'\[OBS\] summary node level=(\d+) nodeType=(\w+) covered=\[(\d+),(\d+)\] token_cost=(\d+)')


def read_run_output(path: str):
    """从控制台输出里抽摘要节点（含全文）。摘要是未截断的 [OBS] dump。"""
    text = open(path, 'r', encoding='utf-8', errors='replace').read()
    lines = text.splitlines()
    out = []
    for i, line in enumerate(lines):
        m = _NODE_RE.search(line)
        if not m:
            continue
        body = []
        j = i + 1
        if j < len(lines) and lines[j].strip() == '[OBS] summary node text:'.strip():
            j += 1
        while j < len(lines) and not lines[j].startswith('[OBS]') and not lines[j].startswith('00:'):
            body.append(lines[j])
            j += 1
        out.append({
            'level': int(m.group(1)),
            'node_type': m.group(2),
            'covered_min_seq': int(m.group(3)),
            'covered_max_seq': int(m.group(4)),
            'token_cost': int(m.group(5)),
            'summary_json': None,
            'text': '\n'.join(body).strip(),
        })
    return out


# ------------------------------------------------------------------- 渲染

def summary_text(node) -> str:
    """摘要正文。有 summary_json 就走产品那种 role-block 解析，否则用 dump 的文本。"""
    if node.get('text'):
        return node['text']
    raw = node.get('summary_json')
    if not raw:
        return ''
    try:
        decoded = json.loads(raw)
        buf = []
        for block in decoded.get('content', []):
            if isinstance(block, dict) and block.get('type') == 'text':
                buf.append(block.get('text', ''))
        return ''.join(buf)
    except Exception:
        return raw


def sort_summaries(nodes):
    """与产品投影一致的顺序：covered_min 升序 → covered_max 降序 → level 降序。"""
    return sorted(nodes, key=lambda n: (n['covered_min_seq'],
                                        -n['covered_max_seq'],
                                        -n['level']))


def render(session_title, session_id, summaries, messages, source_note):
    L = []
    L.append('# %s —— 模型实际看到的上下文（压缩后）' % (session_title or session_id or '会话'))
    L.append('')
    L.append('<!-- 由 tools/extract_summary_history.py 生成；顺序 L2 → L1 → 原文，'
             '与产品投影一致。数据源：%s -->' % source_note)
    L.append('')

    sums = sort_summaries(summaries)
    if sums:
        highest = max(s['level'] for s in sums)
        L.append('### user — 更早上下文（压缩 ×%d，非用户发言）' % len(sums))
        L.append('')
        for s in sums:
            marker = L2_MARKER if s['level'] >= 2 else L1_MARKER
            L.append('<!-- L%d · 覆盖 seq %d-%d · %s tokens -->' % (
                s['level'], s['covered_min_seq'], s['covered_max_seq'],
                s.get('token_cost')))
            L.append(marker)
            L.append('')
            L.append(summary_text(s).strip())
            L.append('')
        del highest
    else:
        L.append('<!-- 本次运行没有摘要节点：未触发折叠（预算没超） -->')
        L.append('')

    # 原文：最后一条摘要覆盖范围之后的近端消息
    last_max = max([s['covered_max_seq'] for s in sums], default=0)
    verbatim = [m for m in messages if (m.get('seq') or 0) > last_max]
    if verbatim:
        L.append('---')
        L.append('')
        for m in verbatim:
            L.append('### %s — 原文 · seq %s' % (m['role'], m.get('seq')))
            L.append('')
            if m.get('content'):
                L.append(str(m['content']).strip())
                L.append('')
            if m.get('tool_calls'):
                L.append('```json')
                L.append(str(m['tool_calls']).strip())
                L.append('```')
                L.append('')
    else:
        L.append('<!-- 原文缺失：数据源里没有消息（只给了 --run-output；'
                 'dumpContext 的 messages 被截断到 2000 字符）。'
                 '要完整原文请用 --db 指向该次运行的库。 -->')
        L.append('')
    return '\n'.join(L).rstrip() + '\n'


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument('--db')
    ap.add_argument('--session', default='latest')
    ap.add_argument('--run-output')
    ap.add_argument('--out', default='')
    ap.add_argument('--title', default='')
    a = ap.parse_args()

    if not a.db and not a.run_output:
        ap.error('至少给一个数据源：--db 或 --run-output')

    session_title, session_id, messages, notes = a.title, '', [], []
    summaries = []
    if a.db:
        row, db_sums, messages = read_db(a.db, a.session)
        session_id = row['id']
        session_title = session_title or row.get('title')
        summaries = db_sums
        notes.append('库 %s（会话 %s）' % (os.path.basename(a.db), session_id[:8]))
    if a.run_output and not a.db:
        summaries = read_run_output(a.run_output)
        notes.append('测试输出 %s' % os.path.basename(a.run_output))
    if not summaries:
        print('警告：没有拿到任何摘要节点（库/输出里都没有）', file=sys.stderr)

    doc = render(session_title, session_id, summaries, messages, '；'.join(notes) or '未知')
    if a.out:
        os.makedirs(os.path.dirname(os.path.abspath(a.out)), exist_ok=True)
        open(a.out, 'w', encoding='utf-8', newline='\n').write(doc)
        print('写出 %s（%d 行，%d 个摘要节点，%d 条原文消息）' % (
            a.out, doc.count('\n'), len(summaries),
            len([m for m in messages if (m.get('seq') or 0) >
                 max([s['covered_max_seq'] for s in summaries], default=0)])))
    else:
        sys.stdout.write(doc)
    return 0


if __name__ == '__main__':
    sys.exit(main())
