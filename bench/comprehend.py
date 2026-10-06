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
- heard: the first sentence offered is the one said (2), the second one is (1).
- asked: the card says the question was for you and what it was (/api/judgecard "asked"); with a
  listener who wasn't named (control) and with a name only mentioned, it must not say so.
- word, who, meant: /api/judgecard against the reference, for an Italian listener (B2) and a native.
"""
import concurrent.futures
import difflib
import glob
import json
import os
import re
import subprocess
import sys
import time
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
    """Parakeet on the processor, as ParakeetCPU.swift (bench/tap.py downloads the same model)."""
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
        num_threads=max(1, (os.cpu_count() or 2) // 2), model_type='nemo_transducer', decoding_method='greedy_search')


def hear():
    """The last 190 s before every tap (and 1 s after), through Parakeet: what the app would have."""
    rec = recogniser()
    listed = json.load(open(CASES))
    calls, heard = {}, {}
    for c in listed:
        if c['file'] not in calls:
            calls[c['file']] = tap.run_samples(os.path.join(OUT, 'calls', c['file'] + '.wav'))
        a = max(0.0, c['tap'] - WINDOW)
        clip = calls[c['file']][int(a * RATE):int((c['tap'] + AFTER) * RATE)]
        heard[c['id']] = {'clip_start': a, 'words': tap.sherpa_words(rec, clip)}
    json.dump(heard, open(os.path.join(OUT, 'heard.json'), 'w'))
    print(len(heard), 'taps heard')
    return 0


# ---------------------------------------------------------------- cards (runner, server)

def post(path, body):
    code = os.environ.get('ASAID_TESTER_CODE')
    req = urllib.request.Request(SERVER + path, method='POST', data=json.dumps(body).encode(),
                                 headers={'content-type': 'application/json', 'x-lexalie-code': code or ''})
    for attempt in range(3):
        try:
            return json.loads(urllib.request.urlopen(req, timeout=90).read())
        except Exception as e:
            error = str(e)[:200]
            time.sleep(3 * (attempt + 1))
    return {'error': error}


def explain(offered, listener, name, focus=''):
    """The body AppModel.captureMoment sends for a tap in a call (known/struggling: a new user)."""
    p = picks.LISTENERS[listener]
    return post('/api/explain', {'text': offered['sent'], 'heard': 'en-US', 'native': p['native'], 'level': p['level'],
                                 'known': [], 'struggling': [], 'watch': [], 'profile': '', 'source': '', 'overlap': False,
                                 'provider': 'gemini', 'focus': focus, 'tone': '', 'before': offered['before'],
                                 'after': offered['after'], 'name': name})


def card(body, offered):
    """What the panel shows: the sentence, then what came back."""
    if not isinstance(body, dict) or 'error' in body:
        return None
    keep = {k: body.get(k) for k in ('translation', 'intent', 'pieces', 'meant', 'for_you', 'asked', 'who', 'in_practice') if k in body}
    return {'sentence': offered['text'], **keep}


def judge(kind, c, listener_label, shown):
    if shown is None:
        return {'answered': 'error'}
    return post('/api/judgecard', {'kind': kind, 'sentence': c['sentence'][:2000], 'target': (c.get('target') or c.get('name', ''))[:300],
                                   'reference': c['reference'][:1000], 'listener': listener_label[:200], 'card': shown})


def same(offered, c, clip_start):
    """The sentence offered is the one said: as bench/tap.py, most of one covers the other."""
    return tap.right(offered, {'start': c['start'], 'end': c['end']}, clip_start)


def contains(text, target):
    t = [norm(w) for w in target.replace('-', ' ').split() if norm(w)]
    h = {norm(w) for w in text.replace('-', ' ').split()}
    return bool(t) and sum(w in h for w in t) >= max(1, round(0.6 * len(t)))


def mark_case(c, offered, clip_start, listener):
    """One case, one listener: the mark and why, with what was shown."""
    row = {'id': c['id'], 'kind': c['kind'], 'listener': listener, 'sentence': c['sentence'],
           'offered': offered[0]['text'] if offered else ''}
    right = [same(o, c, clip_start) for o in offered]
    row['first_right'] = bool(right) and right[0]
    if c['kind'] == 'heard':
        row['mark'] = 2 if right[:1] == [True] else 1 if True in right[1:2] else 0
        return row
    if not offered:
        row['mark'] = 0
        return row
    if c['kind'] in ('asked', 'named'):
        name = c['name']
        shown = card(explain(offered[0], 'it-B2', name), offered[0])
        verdict = judge('asked', c, f"{picks.LISTENERS['it-B2']['label']}, named {name}", shown)
        row.update(listener=listener, name=name, card=shown, judge=verdict)
        said = verdict.get('answered')
        if listener == 'control' or c['kind'] == 'named':
            row['false_alarm'] = said in ('yes', 'partly')
            row['mark'] = 0 if row['false_alarm'] else 2
        else:
            row['mark'] = 2 if said == 'yes' else 1 if said == 'partly' else 0
        return row
    label = picks.LISTENERS[listener]['label']
    shown = card(explain(offered[0], listener, ''), offered[0])
    verdict = judge(c['kind'], c, label, shown)
    row.update(card=shown, judge=verdict)
    if verdict.get('answered') == 'yes':
        row['mark'] = 2
        return row
    # One touch: tap the word in the sentence shown, or take the second sentence offered.
    touch = None
    if contains(offered[0]['text'], c['target']):
        touch = ('focus', card(explain(offered[0], listener, '', focus=c['target'][:120]), offered[0]))
    elif len(offered) > 1 and contains(offered[1]['text'], c['target']):
        touch = ('second', card(explain(offered[1], listener, ''), offered[1]))
    if touch:
        again = judge(c['kind'], c, label, touch[1])
        row.update(touch=touch[0], touch_card=touch[1], touch_judge=again)
        row['mark'] = 1 if again.get('answered') == 'yes' or verdict.get('answered') == 'partly' else 0
    else:
        row['mark'] = 1 if verdict.get('answered') == 'partly' else 0
    return row


def cards():
    if not os.environ.get('ASAID_TESTER_CODE'):
        print('ASAID_TESTER_CODE is not set: the cards need the server.')
        return 1
    listed = json.load(open(CASES))
    heard = json.load(open(os.path.join(OUT, 'heard.json')))
    taps = [{'id': c['id'], 'words': [[str(w[0]), str(w[1]), w[2]] for w in heard[c['id']]['words']],
             'tapAt': c['tap'] - heard[c['id']]['clip_start']} for c in listed if c['id'] in heard]
    path = os.path.join(OUT, 'taps.json')
    json.dump(taps, open(path, 'w'))
    res = subprocess.run([BIN, path], capture_output=True, text=True, check=True)
    offers = {r['id']: r['offered'] for r in map(json.loads, res.stdout.splitlines())}
    jobs = []
    for c in listed:
        if c['id'] not in offers:
            continue
        if c['kind'] == 'heard':
            listeners = ['it-B2']
        elif c['kind'] == 'asked':
            listeners = ['named', 'control']
        elif c['kind'] == 'named':
            listeners = ['mentioned']
        else:
            listeners = list(picks.LISTENERS)
        for listener in listeners:
            jobs.append((c, listener))

    def one(job):
        c, listener = job
        if listener == 'control':
            c = dict(c, name=picks.CONTROL_NAME,
                     reference=f"nobody asks {picks.CONTROL_NAME} anything here (the question is for {c['name']})")
        try:
            return mark_case(c, offers[c['id']], heard[c['id']]['clip_start'], listener)
        except Exception as e:
            return {'id': c['id'], 'kind': c['kind'], 'listener': listener, 'sentence': c['sentence'], 'offered': '',
                    'mark': 0, 'error': str(e)[:300]}

    with concurrent.futures.ThreadPoolExecutor(6) as pool:
        rows = list(pool.map(one, jobs))
    json.dump(rows, open(os.path.join(OUT, 'rows.json'), 'w'), indent=1, ensure_ascii=False)
    print(len(rows), 'cards marked,', sum('error' in r or (r.get('judge') or {}).get('answered') == 'error' for r in rows), 'errors')
    return 0


# ---------------------------------------------------------------- report

NAMES = {'heard': "Didn't hear it: the sentence", 'asked': 'They asked you: "they asked you…"',
         'word': "A word you don't know (foreign or jargon)", 'who': 'Who or what it is', 'meant': 'Got the words, not the meaning'}


def pct(a, n):
    return f'{100 * a / n:.0f}%' if n else '—'


def report():
    rows = json.load(open(os.path.join(OUT, 'rows.json')))
    lines = ['## Comprehension bench: when you get lost, does the card tell you?', '',
             'Real earnings calls (Earnings-21, CC BY-SA 4.0), the tap 0.5 s after the sentence, the same path as the Mac app in a '
             'call: the last 190 s through Parakeet, Conversation.swift, Ranking.swift, Redactor.swift, the real /api/explain. '
             'Mark 2 = the first card answers it, 1 = one touch away, 0 = not there. Score = marks over the most possible.', '',
             '| Way of getting lost | Listener | Cases | Score | Answered at once | One touch away | Not there | Right sentence first |',
             '|---|---|---|---|---|---|---|---|']
    summary = {}
    groups = {}
    for r in rows:
        if r['kind'] in ('named',) or r.get('listener') == 'control':
            continue
        groups.setdefault((r['kind'], r['listener']), []).append(r)
    for kind in NAMES:
        for (k, listener), xs in sorted(groups.items()):
            if k != kind:
                continue
            n = len(xs)
            marks = [x.get('mark', 0) for x in xs]
            score = sum(marks) / (2 * n) if n else 0
            summary[f'{kind} · {listener}'] = round(100 * score, 1)
            lines.append(f"| {NAMES[kind]} | {listener} | {n} | **{100 * score:.0f}%** | {pct(marks.count(2), n)} | {pct(marks.count(1), n)} | "
                         f"{pct(marks.count(0), n)} | {pct(sum(x.get('first_right', False) for x in xs), n)} |")
    alarms = [r for r in rows if r.get('listener') == 'control' or r['kind'] == 'named']
    if alarms:
        wrong = sum(r.get('false_alarm', False) for r in alarms)
        summary['asked · false alarms'] = round(100 * wrong / len(alarms), 1)
        lines += ['', f"Said \"they asked you\" when nobody had: {pct(wrong, len(alarms))} ({wrong}/{len(alarms)}: "
                  f"the same questions for a listener who wasn't named, and names only mentioned)."]
    errors = [r for r in rows if 'error' in r or (r.get('judge') or {}).get('error')]
    if errors:
        lines += ['', f'{len(errors)} cases had a server error (counted as 0): `{(errors[0].get("error") or errors[0]["judge"].get("error", ""))[:200]}`']
    lines += ['', '### Some misses', '']
    for kind in NAMES:
        miss = [r for r in rows if r['kind'] == kind and r.get('mark') == 0 and r.get('listener') != 'control'][:4]
        for r in miss:
            why = (r.get('judge') or {}).get('why', '') if kind != 'heard' else f"offered “{r['offered'][:100]}”"
            lines.append(f"- {kind}/{r['listener']}: “{r['sentence'][:110]}” — {why[:200]}")
    tap.run.summary('\n'.join(lines))
    json.dump(summary, open(os.path.join(OUT, 'summary.json'), 'w'), indent=1)
    return 0


if __name__ == '__main__':
    cmd = sys.argv[1] if len(sys.argv) > 1 else 'report'
    if cmd in ('align', 'cases'):
        sys.exit({'align': align, 'cases': cases}[cmd](sys.argv[2]))
    sys.exit({'audio': audio, 'hear': hear, 'cards': cards, 'report': report}[cmd]())
