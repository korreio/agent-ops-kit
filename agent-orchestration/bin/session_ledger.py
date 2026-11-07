#!/usr/bin/env python3
"""session-ledger: a ledger of agent sessions read from their own records, the Claude Code
transcripts under ~/.claude/projects and the Codex rollouts under ~/.codex/sessions. Nothing is
asked of a session. Installed on PATH by `install.sh --bin`.

Usage: session-ledger [-h|--help] [SINCE] [MARK]
  SINCE  UTC time, e.g. 2026-10-10T15:00:00; default seven days ago
  MARK   optional UTC time that splits sessions into before / mixed / after (a rule change)
  TOP    environment variable: how many Claude sessions to list (default 26)

Read-only and standard library only: it writes nothing and reads no credential file. It reads
usage numbers, agent types and the first words of each brief, and prints nothing else of a
session's content. Its output names projects and briefs: keep it out of any synced repository.
Control characters in a printed value become "?", so a transcript cannot drive the terminal.

Claude prices are list prices in dollars per million tokens (input, cache write, cache read,
output), read 2026-10-10; check them against the vendor's page when the roster is re-checked. A
record on a model that has no price here is not counted, and a line after the totals names it.
The $ column is the whole session; the four columns beside it leave out exploring, design and
other lanes. A lane counts by its transcript; without its meta file it counts as an other lane.

Codex prices are credits per million tokens at Standard speed (input, cached input, output), read
2026-11-01 from https://learn.chatgpt.com/docs/pricing. Credits are not dollars and are never added
to a dollar figure. A thread's tokens count on the model of the turn that spent them, cached input
at its own rate; a model with no price here is named on the same line as an unpriced Claude model.

Limits, known and not fixed: a lane started through claude-review or claude-write saves no
transcript, so it is missing from the Claude side, while Codex records its own runs; the declared
size is found by a pattern in a session's first replies and is "?" when it stated none; a Codex
thread whose parent was last active before SINCE is listed as its own job."""
import json, os, glob, collections, re, sys, statistics, datetime, calendar
USAGE = 'usage: session-ledger [-h|--help] [SINCE] [MARK]'
if '-h' in sys.argv[1:] or '--help' in sys.argv[1:]:
    print(__doc__); sys.exit(0)
SINCE = sys.argv[1] if len(sys.argv) > 1 else (datetime.datetime.now(datetime.timezone.utc) - datetime.timedelta(days=7)).strftime('%Y-%m-%dT%H:%M:%S')
MARK = sys.argv[2] if len(sys.argv) > 2 else '9999'
try: FLOOR = calendar.timegm(datetime.datetime.strptime(SINCE[:19], '%Y-%m-%dT%H:%M:%S').timetuple()) - 3600
except ValueError:
    print(f'session-ledger: invalid SINCE {SINCE!r}, expected a UTC time such as 2026-10-10T15:00:00\n{USAGE}', file=sys.stderr); sys.exit(2)
P = {'claude-fable-5-1': (10, 20, 0.25, 50), 'claude-opus-5-5': (4, 8, 0.20, 20), 'claude-sonnet-5-5': (2, 4, 0.10, 10), 'claude-haiku-5-5': (0.5, 1, 0.05, 2.5)}
GROUP = {'writer': 'write', 'reviewer-deep': 'review', 'reviewer-wide': 'review', 'rule-reviewer': 'review', 'opus-max': 'review', 'verifier': 'verify',
         'explorer-locate': 'explore', 'explorer-trace': 'explore', 'Explore': 'explore', 'designer': 'design', 'relay': 'other'}
# Credits per million tokens, Standard speed: input, cached input, output. Read 2026-11-01. Not dollars.
CREDITS = {'gpt-6-astra': (250, 25, 1250), 'gpt-6.1-sol': (50, 2.5, 250), 'gpt-6.1-terra': (25, 1.25, 125), 'gpt-6-sol': (50, 5, 250), 'gpt-6-luna': (2.5, 0.25, 12.5)}
UNPRICED = collections.Counter()
def cost(model, u):
    pi, pw, pr, po = P[model]
    return ((u.get('input_tokens', 0) or 0) * pi + (u.get('cache_creation_input_tokens', 0) or 0) * pw + (u.get('cache_read_input_tokens', 0) or 0) * pr + (u.get('output_tokens', 0) or 0) * po) / 1e6
CONTROL = re.compile('[\x00-\x1f\x7f-\x9f]')   # C0, DEL and C1
def clean(value):
    """A value from a transcript as printed: every printed row and name passes through here."""
    return CONTROL.sub('?', str(value))
def credits(model, inp, cached, out):
    pi, pc, po = CREDITS[model]
    return ((inp - cached) * pi + cached * pc + out * po) / 1e6
SKIP = ('<system-reminder', '<task-notification', 'Another Claude session', '[SYSTEM', '<cross-session', 'This session is being continued', '<local-command', '<command-name', 'Caveat', '[Cross-session', '<agent-message')
def scan(path, main):
    msgs = {}; ts = []; first = None; owner = 0; klass = None; peak = 0; atexts = 0
    for line in open(path, errors='replace'):
        try: d = json.loads(line)
        except Exception: continue
        t = d.get('timestamp') or ''
        m = d.get('message') or {}
        if d.get('type') == 'user' and main:
            c = m.get('content')
            text = c if isinstance(c, str) else ' '.join(x.get('text', '') for x in c if isinstance(x, dict) and x.get('type') == 'text')
            if text.strip() and not d.get('isMeta') and not text.lstrip().startswith(SKIP):
                if first is None: first = ' '.join(text.split())[:64]
                if t >= SINCE: owner += 1
        if d.get('type') == 'assistant' and main and klass is None and atexts < 12:
            for x in (m.get('content') or []):
                if isinstance(x, dict) and x.get('type') == 'text':
                    atexts += 1
                    r = re.search(r'\b[Cc]lass\w*\W{0,6}(small|ordinary|big)\b', x.get('text', ''))
                    if r: klass = r.group(1)
        u = m.get('usage')
        if u and t >= SINCE and m.get('model') not in P and m.get('model') not in (None, '<synthetic>'): UNPRICED[m['model']] += 1
        if u and m.get('model') in P and t >= SINCE:
            msgs[m.get('id') or d.get('uuid')] = (m['model'], u); ts.append(t)
            peak = max(peak, (u.get('input_tokens', 0) or 0) + (u.get('cache_read_input_tokens', 0) or 0) + (u.get('cache_creation_input_tokens', 0) or 0))
    return msgs, ts, first, owner, klass, peak
rows = []
base = os.path.expanduser('~/.claude/projects')
for main in glob.glob(base + '/*/*.jsonl'):
    lane_files = glob.glob(main[:-6] + '/subagents/*.jsonl')
    if max(os.path.getmtime(f) for f in [main] + lane_files) < FLOOR: continue   # a lane can outlive its coordinator's last write
    proj = re.sub(r'^-Users-[^-]+-(Development-)?', '', main[len(base) + 1:].split('/')[0])
    msgs, ts, first, owner, klass, peak = scan(main, True)
    c = collections.Counter(); lanes = collections.Counter()
    c['coord'] = sum(cost(m, u) for m, u in msgs.values())
    for lane in lane_files:
        try: at = json.load(open(lane[:-6] + '.meta.json')).get('agentType') or 'other'
        except Exception: at = 'other'
        lm, lts, *_ = scan(lane, False)
        if not lm: continue
        g = GROUP.get(at, 'other'); c[g] += sum(cost(m, u) for m, u in lm.values()); lanes[g] += 1; ts += lts
    if not ts: continue
    tot = sum(c.values()); start, end = min(ts), max(ts)
    era = 'after' if start >= MARK else ('before' if end < MARK else 'mixed')
    rows.append(dict(proj=proj, sid=os.path.basename(main)[:8], first=first or '', start=start, end=end, tot=tot, c=c, lanes=lanes, owner=owner, klass=klass or '?', peak=peak, era=era, turns=len(msgs)))
rows.sort(key=lambda r: -r['tot'])
tot = sum(r['tot'] for r in rows)
print(f'CLAUDE: {len(rows)} sessions with activity since {SINCE}Z, ${tot:,.0f} at list prices in saved transcripts (launcher-started reviews are not saved)')
print(f"{'project':18} {'id':8} {'class':8} {'era':6} {'$':>5} {'coord':>5} {'write':>5} {'review':>6} {'verify':>6} {'lanes':>5} {'own':>3} {'peak':>5}  brief")
for r in rows[:int(os.environ.get('TOP', '26'))]:
    c = r['c']; n = sum(r['lanes'].values())
    print(f"{clean(r['proj'])[:18]:18} {clean(r['sid'])} {r['klass']:8} {r['era']:6} {r['tot']:5.0f} {c['coord']:5.0f} {c['write']:5.0f} {c['review']:6.0f} {c['verify']:6.0f} {n:5d} {r['owner']:3d} {r['peak']//1000:4d}k  {clean(r['first'])[:46]}")
print('\nby declared class (sessions that stated one in their first replies):')
for k in ('small', 'ordinary', 'big', '?'):
    g = [r for r in rows if r['klass'] == k]
    if not g: continue
    costs = [r['tot'] for r in g]; ln = [sum(r['lanes'].values()) for r in g]
    rv = sum(r['c']['review'] + r['c']['verify'] for r in g); s = sum(costs)
    print(f"  {k:8} {len(g):3d} sessions | median ${statistics.median(costs):6.1f} | max ${max(costs):6.0f} | total ${s:7.0f} | median lanes {statistics.median(ln):4.1f} | review+verify {100*rv/s if s else 0:3.0f}% of spend")
print('\nby mark:')
for k in ('before', 'mixed', 'after'):
    g = [r for r in rows if r['era'] == k]
    if g: s = sum(r['tot'] for r in g); print(f"  {k:6} {len(g):3d} sessions | total ${s:7.0f} | review+verify {100*sum(r['c']['review']+r['c']['verify'] for r in g)/s:3.0f}% | coordinator {100*sum(r['c']['coord'] for r in g)/s:3.0f}% | writing {100*sum(r['c']['write'] for r in g)/s:3.0f}%")
# ---- Codex
cdx = {}; parent = {}
for f in glob.glob(os.path.expanduser('~/.codex/sessions/*/*/*/*.jsonl')):
    if os.path.getmtime(f) < FLOOR: continue
    meta = None; tok = None; first = None; t0 = t1 = None; model = ''; seen = [0, 0, 0]; spent = 0.0; unpriced = collections.Counter()
    for line in open(f, errors='replace'):
        try: d = json.loads(line)
        except Exception: continue
        t = d.get('timestamp'); p = d.get('payload') or {}
        if t: t0 = t0 or t; t1 = t
        if d.get('type') == 'session_meta': meta = p
        elif d.get('type') == 'turn_context': model = str(p.get('model') or model)
        elif p.get('type') == 'token_count' and p.get('info'):
            tok = p['info'].get('total_token_usage')
            now = [(tok or {}).get(k, 0) or 0 for k in ('input_tokens', 'cached_input_tokens', 'output_tokens')]
            step = [max(a - b, 0) for a, b in zip(now, seen)]; seen = now
            if any(step):
                if model in CREDITS: spent += credits(model, *step)
                else: unpriced[model or '(no model record)'] += 1
        elif first is None and d.get('type') == 'response_item' and p.get('type') == 'message' and p.get('role') == 'user':
            for x in p.get('content') or []:
                tx = x.get('text') or ''
                if tx and not tx.lstrip().startswith(('<', '#')): first = ' '.join(tx.split())[:60]; break
    if not meta or not tok or not t1 or t1 < SINCE: continue
    UNPRICED.update(unpriced)
    sid = meta.get('id'); src = meta.get('source')
    par = None
    if isinstance(src, dict):
        sub = src.get('subagent')
        if isinstance(sub, dict):
            ts_ = sub.get('thread_spawn')
            if isinstance(ts_, dict): par = ts_.get('parent_thread_id')
    cdx[sid] = dict(cwd=os.path.basename(meta.get('cwd') or '?'), tok=tok, first=first or '', t0=t0, t1=t1, origin=meta.get('originator'), spent=spent)
    parent[sid] = par
def root(s):
    seen = set()
    while parent.get(s) and parent[s] in cdx and s not in seen: seen.add(s); s = parent[s]
    return s
jobs = collections.defaultdict(lambda: dict(inp=0, cached=0, out=0, threads=0, credits=0.0))
for s, v in cdx.items():
    j = jobs[root(s)]; j['inp'] += v['tok'].get('input_tokens', 0); j['cached'] += v['tok'].get('cached_input_tokens', 0); j['out'] += v['tok'].get('output_tokens', 0); j['threads'] += 1; j['credits'] += v['spent']
top = sorted(jobs.items(), key=lambda kv: -kv[1]['inp'])
print(f"\nCODEX: {len(jobs)} jobs ({len(cdx)} threads) with activity since {SINCE}Z; tokens as Codex recorded them, priced in credits at Standard speed, not dollars")
print(f"{'repository':18} {'origin':14} {'era':6} {'input M':>8} {'cached':>7} {'out k':>6} {'threads':>7} {'credits':>9}  first words")
for sid, j in top[:14]:
    v = cdx[sid]; era = 'after' if v['t0'] >= MARK else ('before' if v['t1'] < MARK else 'mixed')
    print(f"{clean(v['cwd'])[:18]:18} {clean(v['origin'])[:14]:14} {era:6} {j['inp']/1e6:8.1f} {100*j['cached']/max(j['inp'],1):6.0f}% {j['out']/1e3:6.0f} {j['threads']:7d} {j['credits']:9,.1f}  {clean(v['first'])[:44]}")
print(f"  total: input {sum(j['inp'] for j in jobs.values())/1e6:,.0f}M, output {sum(j['out'] for j in jobs.values())/1e6:.1f}M, {sum(j['credits'] for j in jobs.values()):,.1f} credits, not dollars")
if UNPRICED: print('\nnot counted, no price here for: ' + ', '.join(f'{clean(k)} ({v} records)' for k, v in sorted(UNPRICED.items())))
