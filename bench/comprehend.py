"""The comprehension bench (docs/PIANO.md, block P1): when you tap because you got lost, does the
card tell you what you missed?

Real earnings calls (Earnings-21, Rev.com, CC BY-SA 4.0), the tap simulated 0.5 s after the
sentence, then the same path as the Mac app in a call: the last 190 s of sound through Parakeet
(sherpa-onnx, as ParakeetCPU), the words through Conversation.swift and Ranking.swift, the sentence
and the lines around it through Redactor.swift, then the real /api/explain. The cases and the
references are written by hand in bench/comprehension/picks.py.

    python3 bench/comprehend.py align CORPUS     # by hand, once: human sentences on the audio's clock
    python3 bench/comprehend.py cases CORPUS     # by hand, once: bench/comprehension/cases.json
    python3 bench/comprehend.py audio            # the calls the cases need (git, no LFS)
    python3 bench/comprehend.py hear             # the clip before every tap, through Parakeet
    python3 bench/comprehend.py cards            # Swift tool, /api/explain, /api/judgecard
    python3 bench/comprehend.py report           # one table per way of getting lost

Marks: 2 = the first card answers it; 1 = one touch away (the card answers it in part, or tapping
the word, or the second sentence offered, does); 0 = not there.
- heard: the first sentence offered is the one said (2), the second one is (1). No server call.
- asked: the card says the question was for you and what it was; for a listener who wasn't named
  (the same card: no name goes to the server) and for a name only mentioned, it must not say so.
- word, who, meant: the card against the reference, for an Italian listener (B2).
The cards come from the real server (Gemini: it costs, so only with the owner's go, and never more
than COMPREHEND_MAX_CALLS calls); the marks are given afterwards by hand in marks.json, no paid judge.
COMPREHEND_SAMPLE=n takes n cases per kind (a small run, to measure the cost first).
"""
import concurrent.futures
import difflib
import glob
import hashlib
import json
import os
import re
import subprocess
import sys
import threading
import time
import urllib.error
import urllib.request

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
sys.path.insert(0, os.path.join(HERE, 'comprehension'))
import picks  # noqa: E402
import tap  # noqa: E402  Parakeet as the app runs it, WAV helpers

OUT = os.path.join(HERE, 'out', 'comprehend')
CASES = os.path.join(HERE, 'comprehension', 'cases.json')
ALIGNED = os.path.join(OUT, 'aligned')
BIN = os.environ.get('COMPREHEND_BIN', './comprehend')
SERVER = os.environ.get('ASAID_SERVER', 'https://asaid-nine.vercel.app')
CORPUS_GIT = 'https://github.com/revdotcom/speech-datasets.git'
RATE = 16000
# As AppModel in a call: LiveTranscriber.memorySeconds back, 1 s after the tap.
WINDOW, AFTER, TAP_AFTER = 190, 1, 0.5


# ---------------------------------------------------------------- the corpus (by hand, once)

def sentences(corpus):
    """Earnings-21's human transcripts cut into sentences: (file, speaker, words), in corpus order."""
    out = []
    for path in sorted(glob.glob(os.path.join(corpus, 'earnings21', 'transcripts', 'nlp_references', '*.nlp'))):
        rows = [line.rstrip('\n').split('|') for line in open(path, encoding='utf-8')][1:]
        cur, speaker, found = [], None, []
        for r in rows:
            token, sp, punctuation = r[0], r[1], r[4]
            if speaker is not None and sp != speaker and cur:
                found.append((speaker, cur))
                cur = []
            speaker = sp
            cur.append(token + punctuation)
            if punctuation and punctuation in '.?!':
                found.append((speaker, cur))
                cur = []
        out += [(os.path.basename(path)[:-4], sp, words) for sp, words in found]
    return out


def norm(word):
    return re.sub(r"[^a-z0-9']", '', word.lower())


def align(corpus):
    """Parakeet over each whole call (30 s pieces), then the human words matched to its timed words:
    every sentence gets the time it was said, when most of its words are found."""
    rec = recogniser()
    every = sentences(corpus)
    os.makedirs(ALIGNED, exist_ok=True)
    for f in needed_files(corpus):
        target = os.path.join(ALIGNED, f + '.json')
        if os.path.exists(target):
            continue
        pcm = tap.run_samples(call_wav(f, os.path.join(corpus, 'earnings21', 'media')))
        heard, step = [], 30 * RATE
        for a in range(0, len(pcm), step):
            heard += [[round(s + a / RATE, 2), round(e + a / RATE, 2), t] for s, e, t in tap.sherpa_words(rec, pcm[a:a + step])]
        ref, owner = [], []
        mine = [i for i, s in enumerate(every) if s[0] == f]
        for i in mine:
            for w in every[i][2]:
                if norm(w):
                    ref.append(norm(w))
                    owner.append(i)
        matcher = difflib.SequenceMatcher(None, ref, [norm(w[2]) for w in heard], autojunk=False)
        found = {}
        for block in matcher.get_matching_blocks():
            for k in range(block.size):
                found.setdefault(owner[block.a + k], []).append(heard[block.b + k])
        total = {}
        for o in owner:
            total[o] = total.get(o, 0) + 1
        timed = {str(i): [found[i][0][0], found[i][-1][1]] for i in mine
                 if total.get(i) and len(found.get(i, [])) >= 0.6 * total[i]}
        json.dump({'file': f, 'sentences': timed}, open(target, 'w'))
        print(f, len(timed), '/', len(mine), 'sentences on the clock', flush=True)
    return 0


def needed_files(corpus=None):
    if corpus:
        every = sentences(corpus)
        idx = [i for i, *_ in picks.WORD + picks.WHO + picks.MEANT] + [a for a, *_ in picks.ASKED] + [i for i, _ in picks.NAMED_NOT_ASKED]
        return sorted({every[i][0] for i in idx} | set(picks.HEARD_FILES))
    return sorted({c['file'] for c in json.load(open(CASES))})


def cases(corpus):
    """The hand-picked cases with their times: bench/comprehension/cases.json."""
    every = sentences(corpus)
    clock = {}
    for path in glob.glob(os.path.join(ALIGNED, '*.json')):
        clock.update({int(k): [v['start'], v['end']] if isinstance(v, dict) else v
                      for k, v in json.load(open(path))['sentences'].items()})
    text = lambda i: ' '.join(every[i][2])  # noqa: E731
    out, skipped = [], []

    def add(kind, first, last, **more):
        if first not in clock or last not in clock:
            skipped.append((kind, first))
            return
        start, end = clock[first][0], clock[last][1]
        if start < 5:
            skipped.append((kind, first))
            return
        out.append({'id': f'{kind}-{first}', 'kind': kind, 'file': every[first][0], 'start': start, 'end': end,
                    'tap': round(end + TAP_AFTER, 2), 'sentence': ' '.join(text(i) for i in range(first, last + 1)), **more})

    for f in picks.HEARD_FILES:
        mine = [i for i, s in enumerate(every) if s[0] == f and i in clock and every[i][1] != '0'
                and 10 <= len(s[2]) <= 35 and 3 <= clock[i][1] - clock[i][0] <= 15 and clock[i][0] > WINDOW]
        for i in mine[len(mine) // (2 * picks.HEARD_PER_FILE)::max(1, len(mine) // picks.HEARD_PER_FILE)][:picks.HEARD_PER_FILE]:
            add('heard', i, i)
    for first, last, name, asked in picks.ASKED:
        add('asked', first, last, name=name, reference=asked)
    for i, name in picks.NAMED_NOT_ASKED:
        add('named', i, i, name=name, reference='nobody asks ' + name + ' anything here')
    for kind, listed in [('word', picks.WORD), ('who', picks.WHO), ('meant', picks.MEANT)]:
        for i, target, reference in listed:
            add(kind, i, i, target=target, reference=reference)
    json.dump(out, open(CASES, 'w'), indent=1, ensure_ascii=False)
    kinds = {}
    for c in out:
        kinds[c['kind']] = kinds.get(c['kind'], 0) + 1
    print(kinds, 'from', len({c['file'] for c in out}), 'calls; not on the clock:', skipped)
    return 0


# ---------------------------------------------------------------- audio and recogniser (runner)

def call_wav(f, media):
    os.makedirs(os.path.join(OUT, 'calls'), exist_ok=True)
    wav = os.path.join(OUT, 'calls', f + '.wav')
    if not os.path.exists(wav):
        subprocess.run(['ffmpeg', '-y', '-loglevel', 'error', '-i', os.path.join(media, f + '.mp3'),
                        '-ac', '1', '-ar', str(RATE), wav], check=True)
    return wav


def audio():
    """Only the calls the cases need, from Rev's repository (plain git files, no LFS)."""
    corpus = os.path.join(OUT, 'corpus')
    files = needed_files()
    if not os.path.isdir(os.path.join(corpus, '.git')):
        subprocess.run(['git', 'clone', '--depth', '1', '--filter=blob:none', '--sparse', CORPUS_GIT, corpus], check=True)
    subprocess.run(['git', '-C', corpus, 'sparse-checkout', 'set', '--no-cone', *[f'earnings21/media/{f}.mp3' for f in files]], check=True)
    for f in files:
        call_wav(f, os.path.join(corpus, 'earnings21', 'media'))
    print(len(files), 'calls')
    return 0


def recogniser():
    """Parakeet on the processor, as ParakeetCPU.swift (bench/tap.py downloads the same model). All the
    runner's cores: the words are the same, only the time changes (it is not what we measure here)."""
    import tarfile
    import sherpa_onnx
    models = os.path.join(HERE, 'out', 'models')
    os.makedirs(models, exist_ok=True)
    folder = os.path.join(models, tap.SHERPA_MODEL)
    if not os.path.isdir(folder):
        archive = folder + '.tar.bz2'
        urllib.request.urlretrieve(f'https://github.com/k2-fsa/sherpa-onnx/releases/download/asr-models/{tap.SHERPA_MODEL}.tar.bz2', archive)
        tarfile.open(archive).extractall(models)
    pick = lambda part: sorted(glob.glob(os.path.join(folder, f'{part}*.onnx')))[0]  # noqa: E731
    return sherpa_onnx.OfflineRecognizer.from_transducer(
        encoder=pick('encoder'), decoder=pick('decoder'), joiner=pick('joiner'), tokens=os.path.join(folder, 'tokens.txt'),
        num_threads=os.cpu_count() or 2, model_type='nemo_transducer', decoding_method='greedy_search')


def hear():
    """The last 190 s before every tap (and 1 s after), through Parakeet: what the app would have."""
    listed = sample(json.load(open(CASES)))
    path = os.path.join(OUT, 'heard.json')
    # Kept between runs (actions/cache): the same clips through the same recogniser give the same words.
    # Only the taps not heard yet go through Parakeet (new cases, or a cache from fewer cases).
    heard = json.load(open(path)) if os.path.exists(path) else {}
    todo = [c for c in listed if c['id'] not in heard]
    if not todo:
        print(len(listed), 'taps: the words heard last time')
        return 0
    print(len(listed) - len(todo), 'taps kept from last time,', len(todo), 'to hear')
    rec = recogniser()
    calls = {}
    for c in todo:
        if c['file'] not in calls:
            calls[c['file']] = tap.run_samples(os.path.join(OUT, 'calls', c['file'] + '.wav'))
        a = max(0.0, c['tap'] - WINDOW)
        clip = calls[c['file']][int(a * RATE):int((c['tap'] + AFTER) * RATE)]
        heard[c['id']] = {'clip_start': a, 'words': tap.sherpa_words(rec, clip)}
    json.dump(heard, open(os.path.join(OUT, 'heard.json'), 'w'))
    print(len(heard), 'taps heard')
    return 0


# ---------------------------------------------------------------- cards (runner, server)

# Spending (owner, 06/10): every call to the server is counted, and the bench stops at the cap.
MAX_CALLS = int(os.environ.get('COMPREHEND_MAX_CALLS', '300'))
SAMPLE = int(os.environ.get('COMPREHEND_SAMPLE', '0'))  # cases per kind, 0 = all
_calls = {'n': 0}
_lock = threading.Lock()


# Answers kept between runs (actions/cache), keyed by the server's version of the instructions and the
# exact request: an unchanged case costs nothing. GET /api/explain gives the version without calling Gemini.
_answers = {'version': None, 'kept': {}, 'reused': 0}


def answers_load():
    try:
        with urllib.request.urlopen(SERVER + '/api/explain', timeout=30) as r:
            _answers['version'] = json.loads(r.read()).get('version')
    except Exception as e:
        print('No instructions version from the server (', str(e)[:80], '): nothing reused this time.')
        return
    path = os.path.join(OUT, 'answers.json')
    if os.path.exists(path):
        _answers['kept'] = json.load(open(path))
    print('Instructions version', _answers['version'] + ':', len(_answers['kept']), 'answers kept from earlier runs')


def answers_save():
    if _answers['version']:
        json.dump(_answers['kept'], open(os.path.join(OUT, 'answers.json'), 'w'))


def post(path, body):
    key = None
    if _answers['version']:
        key = hashlib.sha256((_answers['version'] + path + json.dumps(body, sort_keys=True)).encode()).hexdigest()
        if key in _answers['kept']:
            with _lock:
                _answers['reused'] += 1
            return _answers['kept'][key]
    answer = _post(path, body)
    if key and 'error' not in answer:
        with _lock:
            _answers['kept'][key] = answer
    return answer


def _post(path, body):
    with _lock:
        if _calls['n'] >= MAX_CALLS:
            return {'error': f'cap: {MAX_CALLS} calls reached, not sent'}
        _calls['n'] += 1
    code = os.environ.get('ASAID_TESTER_CODE')
    req = urllib.request.Request(SERVER + path, method='POST', data=json.dumps(body).encode(),
                                 headers={'content-type': 'application/json', 'x-lexalie-code': code or ''})
    error = ''
    for attempt in range(2):
        try:
            return json.loads(urllib.request.urlopen(req, timeout=90).read())
        except urllib.error.HTTPError as e:
            error = f'HTTP {e.code}: {e.read()[:200]!r}'
            if e.code < 500:
                break  # a refusal is not worth a second (paid) try
        except Exception as e:
            error = str(e)[:200]
        time.sleep(3)
    return {'error': error}


def explain(offered, focus=''):
    """The body AppModel.captureMoment sends for a tap in a call, for an Italian listener (B2) and a new
    user. No name ever goes: the Mac marks you as [tu] and puts names back on the card itself (P3)."""
    p = picks.LISTENERS['it-B2']
    return post('/api/explain', {'text': offered['sent'], 'heard': 'en-US', 'native': p['native'], 'level': p['level'],
                                 'known': [], 'struggling': [], 'watch': [], 'profile': '', 'source': '', 'overlap': False,
                                 'provider': 'gemini', 'focus': focus, 'tone': '', 'before': offered['before'],
                                 'after': offered['after']})


def card(body, offered):
    """What the panel shows: the sentence, then what came back."""
    if not isinstance(body, dict) or 'error' in body:
        return {'error': (body or {}).get('error', 'no answer') if isinstance(body, dict) else 'no answer'}
    keep = {k: body.get(k) for k in ('translation', 'intent', 'pieces', 'meant', 'for_you', 'asked', 'who', 'in_practice') if k in body}
    return {'sentence': offered['text'], **keep}


def same(offered, c, clip_start):
    """The sentence offered is the one said: as bench/tap.py, most of one covers the other."""
    return tap.right(offered, {'start': c['start'], 'end': c['end']}, clip_start)


def contains(text, target):
    t = [norm(w) for w in target.replace('-', ' ').split() if norm(w)]
    h = {norm(w) for w in text.replace('-', ' ').split()}
    return bool(t) and sum(w in h for w in t) >= max(1, round(0.6 * len(t)))


def explained(shown, target):
    """The card already has a piece about the target: no need to ask for the touch card."""
    return any(contains(' '.join(str(p.get(k, '')) for k in ('text', 'heard_as')), target) for p in (shown.get('pieces') or []))


def card_case(c, offered, clip_start):
    """One case: the sentence offered and the card for it. The marks are given afterwards, by hand,
    against the reference (bench/out/comprehend/marks.json): no paid judge."""
    row = {'id': c['id'], 'kind': c['kind'], 'sentence': c['sentence'], 'offered': offered[0]['text'] if offered else ''}
    right = [same(o, c, clip_start) for o in offered]
    row['first_right'] = bool(right) and right[0]
    if c['kind'] == 'heard':
        row['mark'] = 2 if right[:1] == [True] else 1 if True in right[1:2] else 0
        return row
    for k in ('target', 'name', 'reference'):
        if k in c:
            row[k] = c[k]
    if not offered:
        return row
    # One card, the same for the one named and for a listener who isn't (no name goes to the server).
    row['card'] = card(explain(offered[0]), offered[0])
    if c['kind'] in ('asked', 'named') or 'error' in row['card']:
        return row
    # One touch, only when the card didn't take up the word: tap it, or take the second sentence offered.
    if not explained(row['card'], c['target']):
        if contains(offered[0]['text'], c['target']):
            row['touch'] = 'focus'
            row['touch_card'] = card(explain(offered[0], focus=c['target'][:120]), offered[0])
        elif len(offered) > 1 and contains(offered[1]['text'], c['target']):
            row['touch'] = 'second'
            row['touch_card'] = card(explain(offered[1]), offered[1])
    return row


def sample(listed):
    if not SAMPLE:
        return listed
    out = []
    for kind in NAMES:
        mine = [c for c in listed if c['kind'] == kind]
        out += mine[::max(1, len(mine) // SAMPLE)][:SAMPLE]
    return out


def cards():
    if not os.environ.get('ASAID_TESTER_CODE'):
        print('ASAID_TESTER_CODE is not set: the cards need the server.')
        return 1
    listed = sample(json.load(open(CASES)))
    heard = json.load(open(os.path.join(OUT, 'heard.json')))
    taps = [{'id': c['id'], 'words': [[str(w[0]), str(w[1]), w[2]] for w in heard[c['id']]['words']],
             'tapAt': c['tap'] - heard[c['id']]['clip_start']} for c in listed if c['id'] in heard]
    path = os.path.join(OUT, 'taps.json')
    json.dump(taps, open(path, 'w'))
    res = subprocess.run([BIN, path], capture_output=True, text=True, check=True)
    offers = {r['id']: r['offered'] for r in map(json.loads, res.stdout.splitlines())}

    def one(c):
        try:
            return card_case(c, offers[c['id']], heard[c['id']]['clip_start'])
        except Exception as e:
            return {'id': c['id'], 'kind': c['kind'], 'sentence': c['sentence'], 'offered': '', 'error': str(e)[:300]}

    answers_load()
    with concurrent.futures.ThreadPoolExecutor(4) as pool:
        rows = list(pool.map(one, [c for c in listed if c['id'] in offers]))
    answers_save()
    json.dump(rows, open(os.path.join(OUT, 'rows.json'), 'w'), indent=1, ensure_ascii=False)
    errors = [r for r in rows if 'error' in r or 'error' in (r.get('card') or {}) or 'error' in (r.get('touch_card') or {})]
    print(len(rows), 'cases,', _calls['n'], 'calls to the server (cap', MAX_CALLS, '),', _answers['reused'], 'answers reused,',
          len(errors), 'with an error')
    return 0


# ---------------------------------------------------------------- report

NAMES = {'heard': "Didn't hear it: the sentence", 'asked': 'They asked you: "they asked you…"', 'named': 'Name only mentioned',
         'word': "A word you don't know (foreign or jargon)", 'who': 'Who or what it is', 'meant': 'Got the words, not the meaning'}


def pct(a, n):
    return f'{100 * a / n:.0f}%' if n else '—'


def report():
    """Marks: heard from the tap; the others from marks.json, given by hand against the reference:
    {"<id>": "yes" | "partly" | "no", "<id>|touch": …, "<id>|control": …} (asked: "yes" = the card
    says it was for you; control and named: "yes" = it wrongly says so)."""
    rows = json.load(open(os.path.join(OUT, 'rows.json')))
    path = os.path.join(OUT, 'marks.json')
    marks = json.load(open(path)) if os.path.exists(path) else {}
    calls = sum(k in r and 'error' not in r[k] for r in rows for k in ('card', 'touch_card'))
    lines = ['## Comprehension bench: when you get lost, does the card tell you?', '',
             'Real earnings calls (Earnings-21, CC BY-SA 4.0), the tap 0.5 s after the sentence, the same path as the Mac app in a '
             'call: the last 190 s through Parakeet, Conversation.swift, Ranking.swift, Redactor.swift, the real /api/explain, '
             f'for an Italian listener (B2). {calls} calls to the server. Mark 2 = the first card answers it, 1 = one touch away '
             '(or the card answers in part), 0 = not there.', '',
             '| Way of getting lost | Cases | Score | Answered at once | One touch away | Not there | Right sentence first |',
             '|---|---|---|---|---|---|---|']
    summary, alarms, pending = {}, [], 0
    for kind in NAMES:
        xs = [r for r in rows if r['kind'] == kind]
        if not xs or kind == 'named':
            alarms += [marks.get(r['id']) for r in xs]
            continue
        got = []
        for r in xs:
            if kind == 'heard':
                got.append(r['mark'])
                continue
            if 'card' not in r or 'error' in r.get('card', {}):
                got.append(0)
                continue
            first, touch = marks.get(r['id']), marks.get(r['id'] + '|touch')
            if first is None:
                pending += 1
                continue
            got.append(2 if first == 'yes' else 1 if first == 'partly' or touch == 'yes' else 0)
            if kind == 'asked':
                alarms.append(marks.get(r['id'] + '|control'))
        n = len(got)
        if not n:
            continue
        score = sum(got) / (2 * n)
        summary[kind] = round(100 * score, 1)
        lines.append(f"| {NAMES[kind]} | {n} | **{100 * score:.0f}%** | {pct(got.count(2), n)} | {pct(got.count(1), n)} | "
                     f"{pct(got.count(0), n)} | {pct(sum(x.get('first_right', False) for x in xs), len(xs))} |")
    alarms = [a for a in alarms if a is not None]
    if alarms:
        wrong = sum(a in ('yes', 'partly') for a in alarms)
        summary['false alarms'] = round(100 * wrong / len(alarms), 1)
        lines += ['', f'Said "they asked you" when nobody had: {pct(wrong, len(alarms))} ({wrong}/{len(alarms)}).']
    if pending:
        lines += ['', f'{pending} cards still to be marked by hand (bench/out/comprehend/marks.json).']
    errors = [r for r in rows if 'error' in r or 'error' in (r.get('card') or {})]
    if errors:
        e = errors[0].get('error') or errors[0]['card']['error']
        lines += ['', f'{len(errors)} cases had no card (counted as 0): `{e[:200]}`']
    tap.run.summary('\n'.join(lines))
    json.dump(summary, open(os.path.join(OUT, 'summary.json'), 'w'), indent=1)
    # The cards in the log too, one per line: the artifact may not be reachable from where they are marked.
    for r in rows:
        if r['kind'] != 'heard':
            print('CARD ' + json.dumps(r, ensure_ascii=False))
    return 0


if __name__ == '__main__':
    cmd = sys.argv[1] if len(sys.argv) > 1 else 'report'
    if cmd in ('align', 'cases'):
        sys.exit({'align': align, 'cases': cases}[cmd](sys.argv[2]))
    sys.exit({'audio': audio, 'hear': hear, 'cards': cards, 'report': report}[cmd]())
