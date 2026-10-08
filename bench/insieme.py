"""Block INSIEME through the real server (Gemini: costs credits, only by hand with the owner's go).

  python3 bench/insieme.py corpus            # free: the human transcripts of Earnings-21 (sparse clone)
  python3 bench/insieme.py endcard           # the end-of-session card on 10 real calls (10 calls to Gemini)
  python3 bench/insieme.py ask               # "Ask LEXALIE": 20 questions without saying the session (40 calls)

Real earnings calls (Earnings-21, Rev.com, CC BY-SA 4.0), their human transcripts as the session's
lines (the app sends the Mac's recognised text; the human one keeps this test about the card, not
about the recogniser). The listener is someone the call puts questions to, written [tu] as the Mac
does. Before anything is sent the server's instructions must be the expected version (HANDOFF rule
12): INSIEME_EXPECT_ENDCARD / INSIEME_EXPECT_ASK. INSIEME_MAX_CALLS caps the paid calls.

The results are written to bench/out/insieme/*.json for marking by hand: a card passes when its moments
are ones a listener at B2 would likely miss and are explained right, every acronym is spelled out,
and a question put to [tu] is in "asked you"; an answer passes when it finds the right session and
line and says the right thing.
"""
import json
import os
import re
import subprocess
import sys
import time
import urllib.error
import urllib.request

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import comprehend  # noqa: E402

OUT = os.path.join(HERE, 'out', 'insieme')
CORPUS = os.path.join(HERE, 'out', 'corpus-text')
SERVER = os.environ.get('ASAID_SERVER', 'https://asaid-nine.vercel.app')
MAX_CALLS = int(os.environ.get('INSIEME_MAX_CALLS', '50'))
CASES = json.load(open(os.path.join(HERE, 'comprehension', 'cases.json')))

# The ten calls with the most hand-picked moments, and who in each is asked things (the listener).
CALLS = [('4341191', 'Carolina'), ('4366302', 'Todd'), ('4344338', 'Tom'), ('4368670', ''), ('4320211', 'Brian'),
         ('4364366', 'Joc'), ('4397829', ''), ('4346818', ''), ('4360674', 'Jim'), ('4359971', 'Peter')]

# Questions without saying the session, as someone would ask days later (in Italian, the owner's
# language). Each points at a hand-picked case: the answer must come from that call and that line.
QUESTIONS = [
    ('word-231', "Cosa intendeva con headwind quando parlava dei negozi in California?"),
    ('word-1558', "Cos'è il cost out tailwind di cui parlavano?"),
    ('word-135', "Cosa vuol dire run rate per quei negozi?"),
    ('word-894', "Perché hanno detto che il primo trimestre è basso per il free cashflow? Cos'è?"),
    ('word-11534', "Quanto era l'adjusted EBITDA del gruppo RWE e cosa vuol dire?"),
    ('word-11729', "Cosa vuol dire value accretive?"),
    ('who-12528', "Chi è Illumina?"),
    ('who-12560', "Cos'è Galleri?"),
    ('who-1772', "Chi è Cytiva?"),
    ('who-1762', "Cos'ha lanciato Cepheid?"),
    ('meant-1030', "Cosa voleva dire con more to come, stay tuned?"),
    ('meant-1028', "Cosa intendevano con right-size the function costs?"),
    ('meant-2641', "Cosa sono le headcount actions di cui parlavano?"),
    ('meant-1462', "Quando ha detto we'll see how that plays out, cosa voleva dire?"),
    ('asked-1280', "Cosa hanno chiesto a Carolina sulla liquidità?"),
    ('asked-1913', "Perché hanno chiesto a Tom se era il momento giusto?"),
    ('asked-2049', "Cosa volevano sapere da Tom su quel segmento?"),
    ('asked-185', "Cosa hanno chiesto a Brian di ripetere?"),
    ('meant-1070', "Cosa intendevano con right-sizing production capacity?"),
    ('word-4707', "Cos'è l'ESG di cui parlavano?"),
]

_calls = {'n': 0}
# Tokens the server says it used, and what they cost at Gemini Flash's list price (USD per million).
_tokens = {'in': 0, 'out': 0}
PRICE_IN = float(os.environ.get('INSIEME_PRICE_IN', '0.30'))
PRICE_OUT = float(os.environ.get('INSIEME_PRICE_OUT', '2.50'))


def cost():
    usd = _tokens['in'] / 1e6 * PRICE_IN + _tokens['out'] / 1e6 * PRICE_OUT
    return f"tokens in {_tokens['in']}, out {_tokens['out']}: about ${usd:.3f} (≈ €{usd * 0.92:.3f})"


def corpus():
    if not os.path.isdir(os.path.join(CORPUS, '.git')):
        subprocess.run(['git', 'clone', '--depth', '1', '--filter=blob:none', '--sparse', comprehend.CORPUS_GIT, CORPUS], check=True)
    subprocess.run(['git', '-C', CORPUS, 'sparse-checkout', 'set', 'earnings21/transcripts/nlp_references'], check=True)


def calls():
    """Each call as the app's session: line index = the corpus sentence's global index."""
    every = comprehend.sentences(CORPUS)
    out = {}
    for gi, (f, speaker, words) in enumerate(every):
        out.setdefault(f, []).append({'i': gi, 'speaker': speaker, 'text': ' '.join(words)})
    return out


def as_listener(text, name):
    return re.sub(r'\b%s\b' % re.escape(name), '[tu]', text) if name else text


def version(path):
    with urllib.request.urlopen(SERVER + path, timeout=30) as r:
        return json.loads(r.read())['version']


def check_version(path, expected):
    have = version(path)
    if not expected:
        sys.exit(f'No expected version given for {path} (it is {have}): nothing sent.')
    if have != expected:
        sys.exit(f'The server has {path} at {have}, not {expected} (not published yet?): nothing sent.')
    print(f'{path} version {have}: ok')


def post(path, body):
    if _calls['n'] >= MAX_CALLS:
        return {'error': f'cap: {MAX_CALLS} calls reached, not sent'}
    _calls['n'] += 1
    req = urllib.request.Request(SERVER + path, method='POST', data=json.dumps(body).encode(),
                                 headers={'content-type': 'application/json', 'x-lexalie-code': os.environ.get('ASAID_TESTER_CODE', '')})
    try:
        answer = json.loads(urllib.request.urlopen(req, timeout=120).read())
        for k in ('in', 'out'):
            _tokens[k] += (answer.get('usage') or {}).get(k, 0)
        return answer
    except urllib.error.HTTPError as e:
        return {'error': f'HTTP {e.code}: {e.read()[:200]!r}'}
    except Exception as e:  # noqa: BLE001
        return {'error': str(e)[:200]}


def endcard():
    check_version('/api/endcard', os.environ.get('INSIEME_EXPECT_ENDCARD', ''))
    data = calls()
    rows = []
    for f, listener in CALLS:
        lines = [{'i': l['i'], 'who': 'them', 'text': as_listener(l['text'], listener)[:1200]} for l in data[f]][:2500]
        started = time.time()
        card = post('/api/endcard', {'lines': lines, 'kind': 'call', 'heard': 'en', 'native': 'it', 'level': 'B2',
                                     'profile': 'Works in: finance. Has calls with: investors and analysts.'})
        text = {l['i']: l['text'] for l in data[f]}
        hard = [c for c in CASES if c['file'] == f and c['kind'] in ('word', 'who', 'meant')]
        asked = [c for c in CASES if c['file'] == f and c['kind'] == 'asked' and c.get('name') == listener]
        rows.append({'file': f, 'listener': listener, 'seconds': round(time.time() - started, 1), 'card': card,
                     'sentences': {m['line']: text.get(m['line'], '') for m in card.get('moments', []) + card.get('asked_you', []) + card.get('open_questions', [])},
                     'bench_hard': [{'id': c['id'], 'sentence': c['sentence'], 'target': c.get('target')} for c in hard],
                     'bench_asked': [{'id': c['id'], 'sentence': c['sentence'], 'reference': c['reference']} for c in asked]})
        print(f, listener or '-', 'moments', len(card.get('moments', [])), 'asked', len(card.get('asked_you', [])), card.get('error', ''))
    os.makedirs(OUT, exist_ok=True)
    json.dump(rows, open(os.path.join(OUT, 'endcard.json'), 'w'), ensure_ascii=False, indent=1)
    print('calls to the server:', _calls['n'], '·', cost())


def ask():
    check_version('/api/ask', os.environ.get('INSIEME_EXPECT_ASK', ''))
    data = calls()
    by_id = {c['id']: c for c in CASES}
    files = sorted({f for f, _ in CALLS} | {by_id[q]['file'] for q, _ in QUESTIONS})
    sessions = []
    for k, f in enumerate(files):
        lines = data[f]
        sessions.append({'id': f, 'kind': 'call', 'title': f'Earnings call {f}', 'people': [],
                         'started_at': time.strftime('%Y-%m-%dT%H:%M:%SZ', time.gmtime(time.time() - (k + 1) * 86_400)),
                         'lines': [{'i': l['i'], 'who': l['speaker'] or 'them', 'text': l['text'][:2000]} for l in lines][:3000]})
    rows = []
    for case_id, question in QUESTIONS:
        if _calls['n'] + 2 > MAX_CALLS:
            rows.append({'case': case_id, 'question': question, 'answer': {'error': 'cap reached, not sent'}})
            continue
        _calls['n'] += 1  # the ask endpoint makes two model calls: count both
        answer = post('/api/ask', {'question': question, 'native': 'it', 'sessions': sessions,
                                   'now': time.strftime('%Y-%m-%dT%H:%M:%S+00:00', time.gmtime())})
        case = by_id[case_id]
        right = [q for q in answer.get('quotes', []) if q.get('session_id') == case['file']]
        sentence_ids = {int(re.sub(r'\D', '', case_id.split('-')[1]))}
        rows.append({'case': case_id, 'question': question, 'file': case['file'], 'case_sentence': case['sentence'],
                     'reference': case.get('reference'), 'answer': answer,
                     'right_session': bool(right), 'right_line': any(q.get('idx') in sentence_ids for q in right)})
        print(case_id, 'session', bool(right), 'line', rows[-1]['right_line'], answer.get('error', ''))
    os.makedirs(OUT, exist_ok=True)
    json.dump(rows, open(os.path.join(OUT, 'ask.json'), 'w'), ensure_ascii=False, indent=1)
    sent = [r for r in rows if 'error' not in r['answer']]
    print(f"right session {sum(r['right_session'] for r in sent)}/{len(sent)}, right line {sum(r['right_line'] for r in sent)}/{len(sent)}")
    print('calls to the model (two per question):', _calls['n'], '·', cost())


def show():
    """Free: the results as plain lines in the run's log, to mark them by hand."""
    for name in ('endcard', 'ask'):
        path = os.path.join(OUT, name + '.json')
        if not os.path.exists(path):
            continue
        rows = json.load(open(path))
        if name == 'endcard':
            for r in rows:
                card = r['card']
                print(f"\n=== CALL {r['file']} listener={r['listener'] or '-'} error={card.get('error', '')}")
                for m in card.get('moments', []):
                    print(f"  MOMENT [{m['why']}] line {m['line']}: {m['sentence']}")
                    print(f"     said: {r['sentences'].get(str(m['line']), '')[:300]}")
                    print(f"     meaning: {m['meaning']} | numbers: {m['numbers']} | negation: {m['negation']} | unsure: {m['unsure']}")
                    for t in m.get('terms', []):
                        print(f"     term: {t['term']} = {t['meaning']} (public={t['public']})")
                for a in card.get('asked_you', []):
                    print(f"  ASKED line {a['line']}: {a['sentence']} -> {a['meaning']}")
                for a in card.get('open_questions', []):
                    print(f"  OPEN line {a['line']}: {a['sentence']} -> {a['meaning']}")
                for c in r['bench_asked']:
                    print(f"  BENCH-ASKED {c['id']}: {c['sentence'][:200]} -> {c['reference']}")
                for c in r['bench_hard']:
                    print(f"  BENCH-HARD {c['id']}: {c.get('target')}")
        else:
            for r in rows:
                a = r['answer']
                print(f"\n=== {r['case']} session={r.get('right_session')} line={r.get('right_line')} | Q: {r['question']}")
                print(f"  REF: {r.get('reference')} | SENT: {str(r.get('case_sentence'))[:200]}")
                print(f"  A: {a.get('answer', a.get('error'))}")
                for q in a.get('quotes', []):
                    print(f"  QUOTE {q['session_id']}:{q['idx']}: {q['sentence']}")


if __name__ == '__main__':
    what = sys.argv[1] if len(sys.argv) > 1 else ''
    if what == 'show':
        show()
    elif what == 'corpus':
        corpus()
    elif what in ('endcard', 'ask'):
        if not os.environ.get('ASAID_TESTER_CODE'):
            sys.exit('ASAID_TESTER_CODE is not set: this needs the server.')
        {'endcard': endcard, 'ask': ask}[what]()
        show()
    else:
        sys.exit(__doc__)
