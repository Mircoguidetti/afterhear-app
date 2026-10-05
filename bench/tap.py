"""The tap bench (docs/PIANO.md, block D): does a tap give you the sentence you missed?

The same path as the Mac app: the last two minutes of sound before the tap (a call: the last
three) go through the real recogniser, the words through Conversation.swift and Ranking.swift,
and the first sentence offered is checked against the one really said, from AMI's human transcript.

    python3 bench/tap.py cases                  # meetings, missed sentences, the clip of every tap
    python3 bench/tap.py sherpa                 # Parakeet on the processor (what Intel Macs run)
    python3 bench/tap.py tool NAME BIN [ARGS]   # a Swift tool printing timed words (FluidAudio, Apple)
    python3 bench/tap.py report                 # one table from all the runners, and the gate

Taps: while the sentence is still being said, 0.5 s, 10 s and 2 min after it ends. Context:
"video" (two minutes back, the last 30 s first, as AppModel) and "call" (three minutes, all of it).
"""
import glob
import json
import os
import platform
import re
import subprocess
import sys
import time
import wave
import zipfile

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import run  # noqa: E402  AMI download and word error rate, shared with the other benches

OUT = os.path.join(HERE, 'out')
CASES = os.path.join(OUT, 'tap')
RESULTS = os.path.join(OUT, 'tapresults')
TURNS = os.environ.get('TURNS_BIN', './turns')
MEETINGS = os.environ.get('TAP_MEETINGS', 'ES2002a,ES2003a,ES2004a,IS1009a,TS3003a,TS3004a').split(',')
MINUTES = 20
PER_MEETING = int(os.environ.get('TAP_SENTENCES', '6'))
RATE = 16000
# As AppModel: tapWindow 120 s, memorySeconds 190 s in calls, reactionSeconds 30, 1 s after the tap.
VIDEO_WINDOW, CALL_WINDOW, FRESH, AFTER = 120, 190, 30, 1
TAPS = [('during', None), ('0.5s', 0.5), ('10s', 10), ('2min', 120)]
SHERPA_MODEL = 'sherpa-onnx-nemo-parakeet-tdt-0.6b-v2-int8'


def machine():
    return f"{os.environ.get('RUNNER_LABEL') or platform.platform()} ({platform.machine()})"


# ---------------------------------------------------------------- cases

def human_sentences(meeting, folder):
    """AMI's words with punctuation, speaker by speaker, cut into sentences."""
    z = zipfile.ZipFile(run.fetch(run.AMI_WORDS, os.path.join(folder, 'ami_manual.zip')))
    out = []
    for name in z.namelist():
        m = re.search(rf'words/{meeting}\.([A-Z])\.words\.xml$', name)
        if not m:
            continue
        xml = z.read(name).decode('utf-8', 'ignore')
        cur = []
        for w in re.finditer(r'<w ([^>]*)>([^<]+)</w>', xml):
            attrs, text = w.group(1), w.group(2)
            st = re.search(r'starttime="([\d.]+)"', attrs)
            en = re.search(r'endtime="([\d.]+)"', attrs)
            if 'punc="true"' in attrs:
                if cur and text in '.?!':
                    out.append(cur)
                    cur = []
                continue
            if not st or not en:
                continue
            s, e = float(st.group(1)), float(en.group(1))
            if cur and s - cur[-1][1] > 1.5:
                out.append(cur)
                cur = []
            cur.append((s, e, text))
        if cur:
            out.append(cur)
    sentences = []
    for words in out:
        words = [w for w in words if run.norm(w[2])]
        if len(words) < 7:
            continue
        s, e = words[0][0], words[-1][1]
        if 2 <= e - s <= 12:
            sentences.append({'start': s, 'end': e, 'text': ' '.join(w[2] for w in words)})
    return sorted(sentences, key=lambda x: x['start'])


def write_wav(path, pcm):
    import numpy
    with wave.open(path, 'wb') as w:
        w.setnchannels(1)
        w.setsampwidth(2)
        w.setframerate(RATE)
        w.writeframes((numpy.clip(pcm, -1, 1) * 32767).astype(numpy.int16).tobytes())


def cases():
    """Six meetings, six missed sentences each, four taps each: one clip per tap and context."""
    folder = os.path.join(OUT, 'audio')
    os.makedirs(folder, exist_ok=True)
    meetings = os.path.join(CASES, 'meetings')
    os.makedirs(meetings, exist_ok=True)
    listed = []
    for meeting in MEETINGS:
        try:
            wav = run.fetch(run.AMI.format(m=meeting), os.path.join(folder, meeting + '.wav'))
            short = os.path.join(meetings, meeting + '.wav')
            if not os.path.exists(short):
                subprocess.run(['ffmpeg', '-y', '-loglevel', 'error', '-i', wav, '-t', str(MINUTES * 60),
                                '-ac', '1', '-ar', str(RATE), short], check=True)
            pcm = run_samples(short)
            sentences = human_sentences(meeting, folder)
        except Exception as e:
            print('skip', meeting, e)
            continue
        length = len(pcm) / RATE
        # Room for three minutes before and two after; spread over the meeting.
        usable = [s for s in sentences if s['start'] > CALL_WINDOW and s['end'] + 125 < length]
        picks = usable[:: max(1, len(usable) // PER_MEETING)][:PER_MEETING]
        for k, sentence in enumerate(picks):
            for label, after in TAPS:
                tap = sentence['start'] + 0.6 * (sentence['end'] - sentence['start']) if after is None else sentence['end'] + after
                for context in (['video', 'call'] if label in ('10s', '2min') else ['video']):
                    window = CALL_WINDOW if context == 'call' else VIDEO_WINDOW
                    a, b = max(0.0, tap - window), tap + AFTER
                    cid = f'{meeting}-{k}-{label}-{context}'
                    listed.append({'id': cid, 'meeting': meeting, 'tap': label, 'context': context,
                                   'clip_start': a, 'tap_at': tap - a, 'delay': None if after is None else after,
                                   'truth': sentence})
    json.dump(listed, open(os.path.join(CASES, 'cases.json'), 'w'), indent=1)
    print(len(listed), 'taps from', len({c['meeting'] for c in listed}), 'meetings')
    return 0 if listed else 1


def clips():
    """Cuts the clip of every tap from the meetings (on each runner: smaller to carry around)."""
    folder = os.path.join(CASES, 'clips')
    os.makedirs(folder, exist_ok=True)
    pcm = {}
    for c in json.load(open(os.path.join(CASES, 'cases.json'))):
        if c['meeting'] not in pcm:
            pcm[c['meeting']] = run_samples(os.path.join(CASES, 'meetings', c['meeting'] + '.wav'))
        a = c['clip_start']
        b = a + c['tap_at'] + AFTER
        write_wav(os.path.join(folder, c['id'] + '.wav'), pcm[c['meeting']][int(a * RATE):int(b * RATE)])
    print(len(os.listdir(folder)), 'clips')
    return 0


def run_samples(path):
    import numpy
    with wave.open(path, 'rb') as w:
        return numpy.frombuffer(w.readframes(w.getnframes()), dtype=numpy.int16).astype(numpy.float32) / 32768.0


# ---------------------------------------------------------------- recognisers

def sherpa_words(rec, pcm):
    """As ParakeetCPU.words: pieces glued into words, a new word at "▁", a number after letters apart."""
    s = rec.create_stream()
    s.accept_waveform(RATE, pcm)
    rec.decode_stream(s)
    r = s.result
    tokens, times = list(r.tokens), list(r.timestamps)
    durations = list(getattr(r, 'durations', []) or [])
    total = len(pcm) / RATE
    out, starts_word = [], False
    for i, piece in enumerate(tokens):
        start = float(times[i])
        end = start + float(durations[i]) if i < len(durations) else (float(times[i + 1]) if i + 1 < len(times) else total)
        text = piece.replace('▁', ' ').strip()
        after_letters = bool(out) and out[-1][2][-1:].isalpha() and text[:1].isdigit()
        if piece.startswith((' ', '▁')) or not out or starts_word or after_letters:
            if not text:
                starts_word = True
                continue
            starts_word = False
            out.append([start, end, text])
        else:
            out[-1] = [out[-1][0], max(out[-1][1], end), out[-1][2] + text]
    return out


def sherpa():
    import tarfile
    import urllib.request
    import sherpa_onnx
    models = os.path.join(OUT, 'models')
    os.makedirs(models, exist_ok=True)
    folder = os.path.join(models, SHERPA_MODEL)
    if not os.path.isdir(folder):
        archive = folder + '.tar.bz2'
        urllib.request.urlretrieve(f'https://github.com/k2-fsa/sherpa-onnx/releases/download/asr-models/{SHERPA_MODEL}.tar.bz2', archive)
        tarfile.open(archive).extractall(models)
    pick = lambda part: sorted(glob.glob(os.path.join(folder, f'{part}*.onnx')))[0]  # noqa: E731
    # As ParakeetCPU.swift: half the cores, greedy search.
    rec = sherpa_onnx.OfflineRecognizer.from_transducer(
        encoder=pick('encoder'), decoder=pick('decoder'), joiner=pick('joiner'), tokens=os.path.join(folder, 'tokens.txt'),
        num_threads=max(1, (os.cpu_count() or 2) // 2), model_type='nemo_transducer', decoding_method='greedy_search')
    heard = {}
    for path in sorted(glob.glob(os.path.join(CASES, 'clips', '*.wav'))):
        t0 = time.time()
        words = sherpa_words(rec, run_samples(path))
        heard[os.path.basename(path)] = {'seconds': time.time() - t0, 'words': words}
    return score('Parakeet compressed, processor (sherpa-onnx int8)', heard)


def tool(name, binary, *args):
    """A Swift tool that prints {"file", "seconds", "words"} per clip."""
    res = subprocess.run([binary, *args, os.path.join(CASES, 'clips')], capture_output=True, text=True)
    print(res.stderr[-3000:])
    heard = {}
    for line in res.stdout.splitlines():
        try:
            row = json.loads(line)
        except Exception:
            continue
        heard[row['file']] = {'seconds': row['seconds'], 'words': [[float(w[0]), float(w[1]), w[2]] for w in row['words']]}
    if not heard:
        return save([{'engine': name, 'machine': machine(), 'failed': (res.stderr or res.stdout or 'no output')[-400:]}], name)
    return score(name, heard)


# ---------------------------------------------------------------- scoring

def overlap(a, b):
    return max(0.0, min(a[1], b[1]) - max(a[0], b[0]))


def right(offered, truth, clip_start):
    """The sentence offered is the missed one: it covers most of it, or most of it is the missed one."""
    s, e = offered['start'] + clip_start, offered['end'] + clip_start
    o = overlap((s, e), (truth['start'], truth['end']))
    return o >= 0.5 * (truth['end'] - truth['start']) or o >= 0.5 * max(e - s, 0.01)


def recall(truth, text):
    t, h = run.norm(truth), set(run.norm(text))
    return sum(w in h for w in t) / len(t) if t else 0


def score(engine, heard):
    listed = json.load(open(os.path.join(CASES, 'cases.json')))
    batch = []
    for c in listed:
        h = heard.get(c['id'] + '.wav')
        if h is None:
            continue
        words = [[str(w[0]), str(w[1]), w[2]] for w in h['words']]
        fresh = FRESH if c['context'] == 'video' else None
        batch.append({'id': c['id'], 'words': words, 'tapAt': c['tap_at'], 'fresh': fresh, 'delay': None})
        if c['delay'] is not None:
            batch.append({'id': c['id'] + '|learned', 'words': words, 'tapAt': c['tap_at'], 'fresh': fresh, 'delay': c['delay']})
    path = os.path.join(OUT, 'tap-turns-in.json')
    json.dump(batch, open(path, 'w'))
    res = subprocess.run([TURNS, path], capture_output=True, text=True, check=True)
    ranked = {r['id']: r for r in map(json.loads, res.stdout.splitlines())}
    rows = []
    for c in listed:
        h = heard.get(c['id'] + '.wav')
        if h is None:
            continue
        for variant in ['new', 'learned']:
            r = ranked.get(c['id'] + ('|learned' if variant == 'learned' else ''))
            if r is None:
                continue
            top = r['top']
            first = bool(top) and right(top[0], c['truth'], c['clip_start'])
            rows.append({'id': c['id'], 'tap': c['tap'], 'context': c['context'], 'user': variant,
                         'first': first, 'top3': any(right(t, c['truth'], c['clip_start']) for t in top),
                         'words_right': round(recall(c['truth']['text'], top[0]['text']) if first else 0, 3),
                         'seconds': round(h['seconds'] + r['micros'] / 1e6, 2),
                         'offered': top[0]['text'] if top else '', 'truth': c['truth']['text']})
    return save([{'engine': engine, 'machine': machine(), 'rows': rows}], engine)


def save(rows, engine):
    os.makedirs(RESULTS, exist_ok=True)
    tag = re.sub(r'[^a-z0-9]+', '-', f"{os.environ.get('RUNNER_LABEL', 'local')}-{engine}".lower())
    json.dump(rows, open(os.path.join(RESULTS, f'tap-{tag}.json'), 'w'), indent=1)
    for r in rows:
        if 'failed' in r:
            print('FAILED', r['engine'], r['failed'])
        else:
            n = len([x for x in r['rows'] if x['user'] == 'new'])
            f = sum(x['first'] for x in r['rows'] if x['user'] == 'new')
            print(r['engine'], r['machine'], f'{f}/{n} right first')
    return 0


# ---------------------------------------------------------------- report

def pct(a, n):
    return f'{100 * a / n:.0f}%' if n else '—'


def report():
    runs = []
    for path in sorted(glob.glob(os.path.join(OUT, '**', 'tap-*.json'), recursive=True)):
        if 'tap-turns-in' not in path:
            runs += json.load(open(path))
    lines = ['## Tap bench: does a tap give the sentence you missed?', '',
             f'{len(MEETINGS)} real meetings (AMI, CC BY 4.0), {PER_MEETING} missed sentences each, checked against the human transcript. '
             'Same path as the Mac app: the clip before the tap, the real recogniser, Conversation.swift and Ranking.swift. '
             '"New user": no learned delay yet; "learned": the app knows your usual delay. '
             'Seconds = recognising the clip on the runner + choosing (a runner is slower than a Mac at home).', '']
    summary = {}
    for r in runs:
        if 'failed' in r:
            lines += [f"**{r['engine']} on {r['machine']}: did not run.** `{r['failed'][-300:].strip()}`", '']
            continue
        lines += [f"### {r['engine']} · {r['machine']}", '',
                  '| Tap | Context | User | Taps | Right sentence first | In the first 3 | Words of it right | Seconds (median) |',
                  '|---|---|---|---|---|---|---|---|']
        groups = {}
        for x in r['rows']:
            groups.setdefault((x['tap'], x['context'], x['user']), []).append(x)
        order = [t for t, _ in TAPS]
        for (tap, ctx, user), xs in sorted(groups.items(), key=lambda kv: (order.index(kv[0][0]), kv[0][1], kv[0][2])):
            n = len(xs)
            secs = sorted(x['seconds'] for x in xs)
            firsts = [x for x in xs if x['first']]
            words = sum(x['words_right'] for x in firsts) / len(firsts) if firsts else 0
            lines.append(f"| {tap} | {ctx} | {user} | {n} | {pct(len(firsts), n)} | {pct(sum(x['top3'] for x in xs), n)} | "
                         f"{100 * words:.0f}% | {secs[n // 2]:.1f} |")
        new = [x for x in r['rows'] if x['user'] == 'new']
        summary[(r['engine'], r['machine'])] = (sum(x['first'] for x in new), len(new))
        wrong = [x for x in new if not x['first']][:5]
        if wrong:
            lines += ['', 'Some it got wrong:'] + [f"- {x['tap']}/{x['context']}: offered “{x['offered'][:90]}” — missed “{x['truth'][:90]}”" for x in wrong]
        lines.append('')
    lines += ['### All together (new user, every tap)', '', '| Engine | Runner | Right sentence first |', '|---|---|---|']
    lines += [f'| {e} | {m} | {pct(f, n)} ({f}/{n}) |' for (e, m), (f, n) in sorted(summary.items())]
    gate = check_gate(summary, runs)
    run.summary('\n'.join(lines + [''] + gate[1]))
    os.makedirs(OUT, exist_ok=True)
    json.dump({f'{e} · {m}': {'first': f, 'n': n} for (e, m), (f, n) in summary.items()},
              open(os.path.join(OUT, 'tap-summary.json'), 'w'), indent=1)
    return 0 if gate[0] else 1


BASELINE = os.path.join(HERE, 'tap-baseline.json')
# Apple's new recogniser may not run on a runner at all: measured when it does, never a gate.
OPTIONAL = ('Apple',)


def check_gate(summary, runs):
    """The gate (block D, point 6): every engine of the baseline ran, and none finds the right sentence
    first more than 2 points less often than in bench/tap-baseline.json."""
    if not os.path.exists(BASELINE):
        return True, ['### Gate', '', 'No baseline yet (bench/tap-baseline.json): this run measures, it does not block.']
    base = json.load(open(BASELINE))
    now = {f'{e} · {m}': 100 * f / n for (e, m), (f, n) in summary.items() if n}
    out, ok = ['### Gate', '', '| Engine · runner | Baseline | Now | |', '|---|---|---|---|'], True
    for key, b in sorted(base.items()):
        if key.startswith(OPTIONAL):
            continue
        cur = now.get(key)
        good = cur is not None and cur >= b - 2
        ok &= good
        out.append(f"| {key} | {b:.0f}% | {'did not run' if cur is None else f'{cur:.0f}%'} | {'ok' if good else '**blocked**'} |")
    out += ['', '**Passed.**' if ok else '**Blocked: the version is not published until this is green again.**']
    return ok, out


if __name__ == '__main__':
    cmd = sys.argv[1] if len(sys.argv) > 1 else 'report'
    if cmd == 'tool':
        sys.exit(tool(*sys.argv[2:]))
    sys.exit({'cases': cases, 'clips': clips, 'sherpa': sherpa, 'report': report}[cmd]())
