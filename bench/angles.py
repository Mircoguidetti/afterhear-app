"""The new angles (owner, 09/10): does LEXALIE hold on what people listen to beyond work calls?

Public content only, so nobody is exposed:
  - developer podcasts (The Changelog's shows: Go Time, JS Party, Practical AI, Ship It; human
    transcripts, CC BY-SA 4.0) heard by an Italian listener, as kind "podcast";
  - question time in the Italian Chamber of Deputies (public stenographic record), heard by an
    Italian in Italian, as kind "video": the language of offices and ministries, your own language.

  python3 bench/angles.py corpus      # free: fetch, print what was found
  python3 bench/angles.py text        # free: print the Italian sessions line by line (to write questions)
  python3 bench/angles.py card        # the end card on every session (one call to Gemini each)
  python3 bench/angles.py ask         # "Ask LEXALIE" over all of them (two calls each)
  python3 bench/angles.py show        # free: the results as lines in the log, to mark by hand

Nobody in these sessions talks to the listener, so "asked you" must stay empty: every item there is
a false alarm. A card is marked moment by moment (missed / important but easy / already known /
recognition error), an answer by whether it finds the right session and line and says the right thing.
"""
import html
import json
import os
import re
import subprocess
import sys
import time
import urllib.request

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import insieme  # noqa: E402

OUT = os.path.join(HERE, 'out', 'angles')
CHANGELOG = os.path.join(HERE, 'out', 'changelog')
CHANGELOG_GIT = 'https://github.com/thechangelog/transcripts.git'
EPISODES = ['gotime/go-time-300.md', 'gotime/go-time-280.md', 'gotime/go-time-260.md',
            'jsparty/js-party-300.md', 'jsparty/js-party-320.md', 'jsparty/js-party-340.md',
            'practicalai/practical-ai-250.md', 'practicalai/practical-ai-270.md', 'practicalai/practical-ai-290.md',
            'shipit/ship-it-90.md', 'shipit/ship-it-110.md', 'shipit/ship-it-130.md']
CAMERA = 'https://documenti.camera.it/leg19/resoconti/assemblea/html/sed{:04d}/stenografico.htm'
# Sittings to look through for question time ("interrogazioni a risposta immediata"), newest first.
SITTINGS = range(420, 300, -1)
ITALIAN = 4

# Questions as someone would ask days later, in Italian, without saying the session: the session
# and the line the answer must come from. Filled once the texts are printed (python3 bench/angles.py text).
QUESTIONS = json.load(open(os.path.join(HERE, 'angles-questions.json'))) if os.path.exists(os.path.join(HERE, 'angles-questions.json')) else []


def changelog():
    if not os.path.isdir(os.path.join(CHANGELOG, '.git')):
        subprocess.run(['git', 'clone', '--depth', '1', '--filter=blob:none', '--sparse', CHANGELOG_GIT, CHANGELOG], check=True)
    subprocess.run(['git', '-C', CHANGELOG, 'sparse-checkout', 'set', *sorted({e.split('/')[0] for e in EPISODES})], check=True)
    out = []
    for e in EPISODES:
        path = os.path.join(CHANGELOG, e)
        if not os.path.exists(path):
            print('missing', e)
            continue
        lines, who = [], 'them'
        for para in open(path, encoding='utf-8').read().split('\n\n'):
            para = para.strip()
            m = re.match(r'\*\*([^*]{1,60}):\*\*\s*(.*)', para, re.S)
            if m:
                who, para = m.group(1).strip(), m.group(2)
            para = re.sub(r'\\?\[[^\]]{0,40}\\?\]', '', para.replace('\\', '')).strip()
            if not para or who in ('Break',) or para.startswith('#'):
                continue
            for sentence in re.split(r'(?<=[.?!])\s+(?=[A-Z"])', para):
                if sentence.strip():
                    lines.append({'i': len(lines), 'who': who, 'text': sentence.strip()[:1200]})
        out.append({'id': e.split('/')[1][:-3], 'kind': 'podcast', 'heard': 'en', 'title': e.split('/')[1][:-3].replace('-', ' '),
                    'people': sorted({l['who'] for l in lines}), 'lines': lines[:2500]})
    return out


def fetch(url):
    req = urllib.request.Request(url, headers={'user-agent': 'Mozilla/5.0 (LEXALIE bench)'})
    raw = urllib.request.urlopen(req, timeout=30).read()
    for enc in ('utf-8', 'windows-1252'):
        try:
            return raw.decode(enc)
        except UnicodeDecodeError:
            continue
    return raw.decode('utf-8', 'replace')


SPEAKER = re.compile(r"^((?:PRESIDENTE|[A-ZÀ-ÖØ-Þ][A-ZÀ-ÖØ-Þ'’ -]{3,60}))(?:\s*\([^)]{0,40}\))?(?:,\s*[^.]{0,160})?\.\s+(.*)$", re.S)


def camera(n):
    page = fetch(CAMERA.format(n))
    text = re.sub(r'(?is)<(script|style).*?</\1>', '', page)
    paras = [html.unescape(re.sub(r'<[^>]+>', ' ', p)) for p in re.split(r'(?i)</p>|<br\s*/?>', text)]
    paras = [re.sub(r'\s+', ' ', p).strip() for p in paras]
    start = next((k for k, p in enumerate(paras) if re.search(r'(?i)interrogazioni a risposta immediata', p) and len(p) < 200), None)
    if start is None:
        return None
    lines, who = [], None
    for p in paras[start + 1:]:
        if re.match(r'(?i)^(sospendo la seduta|la seduta, sospesa|seguito della discussione|ordine del giorno della seduta)', p):
            break
        m = SPEAKER.match(p)
        if m:
            who, p = m.group(1).strip().title(), m.group(2)
        if not who or len(p) < 2:
            continue
        for sentence in re.split(r'(?<=[.?!])\s+(?=[A-ZÀ-Ü])', p):
            if sentence.strip():
                lines.append({'i': len(lines), 'who': who, 'text': sentence.strip()[:1200]})
    if len(lines) < 40:
        return None
    return {'id': f'camera-{n}', 'kind': 'video', 'heard': 'it', 'title': f'Question time alla Camera, seduta {n}',
            'people': sorted({l['who'] for l in lines})[:40], 'lines': lines[:2500]}


def italian():
    out = []
    for n in SITTINGS:
        if len(out) >= ITALIAN:
            break
        try:
            s = camera(n)
        except Exception as e:  # noqa: BLE001
            print('sitting', n, 'not read:', str(e)[:80])
            continue
        if s:
            out.append(s)
            print('sitting', n, 'question time:', len(s['lines']), 'lines')
    return out


def sessions():
    path = os.path.join(OUT, 'sessions.json')
    if os.path.exists(path):
        return json.load(open(path))
    got = changelog() + italian()
    os.makedirs(OUT, exist_ok=True)
    json.dump(got, open(path, 'w'), ensure_ascii=False)
    return got


def corpus():
    got = sessions()
    for s in got:
        words = sum(len(l['text'].split()) for l in s['lines'])
        print(f"{s['id']}: {s['kind']} {s['heard']} · {len(s['lines'])} lines · {words} words · {len(s['people'])} people")
        for l in s['lines'][:3]:
            print('   ', l['who'], '|', l['text'][:160])
    print(len(got), 'sessions')


def text():
    """The Italian lines worth a question (acronyms, numbers, long answers), to write the questions."""
    for s in sessions():
        if s['heard'] != 'it':
            continue
        print(f"\n=== {s['id']}")
        picked = [l for l in s['lines'] if re.search(r'\b[A-Z]{2,}\b|\d', l['text']) and len(l['text']) > 60]
        for l in picked[:70]:
            print(f"{l['i']} {l['who']}: {l['text'][:220]}")


def card():
    insieme.check_version('/api/endcard', os.environ.get('INSIEME_EXPECT_ENDCARD', ''))
    rows = []
    for s in sessions():
        lines = [{'i': l['i'], 'who': 'them', 'text': l['text']} for l in s['lines']]
        started = time.time()
        answer = insieme.post('/api/endcard', {'lines': lines, 'kind': s['kind'], 'heard': s['heard'], 'native': 'it', 'level': 'B2',
                                               'profile': 'Works in: software.' if s['heard'] == 'en' else ''})
        text = {l['i']: f"{l['who']}: {l['text']}" for l in s['lines']}
        used = [m['line'] for m in answer.get('moments', []) + answer.get('asked_you', []) + answer.get('open_questions', [])]
        rows.append({'session': s['id'], 'heard': s['heard'], 'seconds': round(time.time() - started, 1), 'card': answer,
                     'sentences': {str(i): text.get(i, '') for i in used}})
        print(s['id'], 'moments', len(answer.get('moments', [])), 'asked', len(answer.get('asked_you', [])), answer.get('error', ''))
    os.makedirs(OUT, exist_ok=True)
    json.dump(rows, open(os.path.join(OUT, 'card.json'), 'w'), ensure_ascii=False, indent=1)
    print('calls to the server:', insieme._calls['n'], '·', insieme.cost())


def ask():
    insieme.check_version('/api/ask', os.environ.get('INSIEME_EXPECT_ASK', ''))
    got = sessions()
    inline = [{'id': s['id'], 'kind': s['kind'], 'title': s['title'], 'people': s['people'],
               'started_at': time.strftime('%Y-%m-%dT%H:%M:%SZ', time.gmtime(time.time() - (k + 1) * 86_400)),
               'lines': [{'i': l['i'], 'who': l['who'], 'text': l['text'][:2000]} for l in s['lines']][:3000]} for k, s in enumerate(got)]
    rows = []
    for q in QUESTIONS:
        if insieme._calls['n'] + 2 > insieme.MAX_CALLS:
            rows.append({**q, 'answer': {'error': 'cap reached, not sent'}})
            continue
        insieme._calls['n'] += 1  # two model calls per question
        answer = insieme.post('/api/ask', {'question': q['question'], 'native': 'it', 'sessions': inline,
                                           'now': time.strftime('%Y-%m-%dT%H:%M:%S+00:00', time.gmtime())})
        right = [x for x in answer.get('quotes', []) if x.get('session_id') == q['session']]
        rows.append({**q, 'answer': answer, 'right_session': bool(right),
                     'right_line': any(abs(x.get('idx', -99) - q['line']) <= 1 for x in right)})
        print(q['question'][:60], 'session', bool(right), 'line', rows[-1]['right_line'], answer.get('error', ''))
    os.makedirs(OUT, exist_ok=True)
    json.dump(rows, open(os.path.join(OUT, 'ask.json'), 'w'), ensure_ascii=False, indent=1)
    sent = [r for r in rows if 'error' not in r['answer']]
    print(f"right session {sum(r['right_session'] for r in sent)}/{len(sent)}, right line {sum(r['right_line'] for r in sent)}/{len(sent)}")
    print('calls to the model (two per question):', insieme._calls['n'], '·', insieme.cost())


def show():
    path = os.path.join(OUT, 'card.json')
    if os.path.exists(path):
        for r in json.load(open(path)):
            c = r['card']
            print(f"\n=== {r['session']} ({r['heard']}) {r['seconds']} s {c.get('error', '')}")
            for m in c.get('moments', []):
                print(f"  MOMENT [{m['why']}] {m['line']}: {r['sentences'].get(str(m['line']), '')[:300]}")
                print(f"     meaning: {m['meaning']} | numbers: {m['numbers']} | negation: {m['negation']} | unsure: {m['unsure']}")
                for t in m.get('terms', []):
                    print(f"     term: {t['term']} = {t['meaning']} (public={t['public']})")
            for a in c.get('asked_you', []):
                print(f"  ASKED (false alarm) {a['line']}: {r['sentences'].get(str(a['line']), '')[:200]} -> {a['meaning']}")
            for a in c.get('open_questions', []):
                print(f"  OPEN {a['line']}: {r['sentences'].get(str(a['line']), '')[:200]} -> {a['meaning']}")
    path = os.path.join(OUT, 'ask.json')
    if os.path.exists(path):
        for r in json.load(open(path)):
            a = r['answer']
            print(f"\n=== {r['session']}:{r['line']} session={r.get('right_session')} line={r.get('right_line')} | Q: {r['question']}")
            print(f"  REF: {r.get('reference')}")
            print(f"  A: {a.get('answer', a.get('error'))}")
            for x in a.get('quotes', []):
                print(f"  QUOTE {x['session_id']}:{x['idx']}: {x['sentence']}")


if __name__ == '__main__':
    what = sys.argv[1] if len(sys.argv) > 1 else ''
    free = {'corpus': corpus, 'text': text, 'show': show}
    paid = {'card': card, 'ask': ask}
    if what in free:
        free[what]()
    elif what in paid:
        if not os.environ.get('ASAID_TESTER_CODE'):
            sys.exit('ASAID_TESTER_CODE is not set: this needs the server.')
        paid[what]()
        show()
    else:
        sys.exit(__doc__)
