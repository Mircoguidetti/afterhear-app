"""The test bench for the brain (docs/BRAIN.md § 19.18).

    python3 bench/run.py synthetic   # scripted conversations with reactions: a gate in CI
    python3 bench/run.py audio       # real meetings (AMI corpus, CC BY 4.0) through Whisper

Both use the same Ranking.swift as the apps, compiled to ./rank (see .github/workflows/bench.yml).
Simulated taps come 0 s, 10 s, 2 min and 20 min after the missed sentence. Metrics:
- right sentence: the missed one is first; candidates: it's in the first three;
- recogniser: word error rate of the open-source stand-in against AMI's human transcript
  (Apple's recogniser is tested by hand on the devices);
- explanation: with the secrets set, /api/explain on the real server and a judge model's mark;
- timings: ranking, recognition (real-time factor), explanation.
The numbers go to the job summary and bench/out/.
"""
import wave
import json
import math
import os
import re
import subprocess
import sys
import time
import urllib.request
import zipfile

HERE = os.path.dirname(os.path.abspath(__file__))
OUT = os.path.join(HERE, 'out')
RANK = os.environ.get('RANK_BIN', './rank')
SERVER = os.environ.get('ASAID_SERVER', 'https://asaid-nine.vercel.app')
DELAYS = [('0s', 0.5), ('10s', 10), ('2min', 120), ('20min', 1200)]
# Open-license meetings: real people, British and European accents, overlapping voices.
MEETINGS = os.environ.get('BENCH_MEETINGS', 'ES2002a,IS1009a').split(',')
AMI = 'https://groups.inf.ed.ac.uk/ami/AMICorpusMirror/amicorpus/{m}/audio/{m}.Mix-Headset.wav'
AMI_WORDS = 'https://groups.inf.ed.ac.uk/ami/AMICorpusAnnotations/ami_public_manual_1.6.2.zip'
MINUTES = float(os.environ.get('BENCH_MINUTES', '22'))


def summary(md):
    print(md)
    path = os.environ.get('GITHUB_STEP_SUMMARY')
    if path:
        with open(path, 'a', encoding='utf-8') as f:
            f.write(md + '\n')


def rank(cases):
    os.makedirs(OUT, exist_ok=True)
    path = os.path.join(OUT, 'cases.json')
    json.dump(cases, open(path, 'w'))
    res = subprocess.run([RANK, path], capture_output=True, text=True, check=True)
    return [json.loads(line) for line in res.stdout.splitlines() if line.strip()]


def baseline(lines, truth, tap, delay):
    """Before the reactions (the old rule): the turn before your last reply, otherwise the closest."""
    theirs = [i for i, l in enumerate(lines) if not l.get('mine') and l['end'] <= tap + 0.5]
    mine = [i for i, l in enumerate(lines) if l.get('mine') and l['end'] <= tap + 0.5]
    if mine:
        before = [i for i in theirs if i < mine[-1]]
        late = [i for i in theirs if i > mine[-1] and tap - lines[i]['end'] < 4]
        if before and not late:
            return before[-1] == truth
    target = tap - (delay if delay is not None else 2.5)
    return bool(theirs) and min(theirs, key=lambda i: abs(lines[i]['end'] - target)) == truth


def table(results, cases):
    by = {}
    names = {c['name']: c for c in cases}
    for r in results:
        b = by.setdefault(r['tap'], {'n': 0, 'top1': 0, 'top3': 0, 'base': 0, 'us': []})
        b['n'] += 1
        b['top1'] += r['rank'] == 1
        b['top3'] += r['rank'] is not None and r['rank'] <= 3
        b['us'].append(r['micros'])
        c = names[r['name']]
        tap = next(t for t in c['taps'] if (t.get('label') or '') == r['tap'])
        b['base'] += baseline(c['lines'], c['truth'], tap['at'], tap.get('delay'))
    rows = ['| Tap | Taps | Right sentence | In the first 3 | Before (old rule) | Ranking time |', '|---|---|---|---|---|---|']
    tot = {'n': 0, 'top1': 0, 'top3': 0, 'base': 0}
    for k, b in by.items():
        rows.append(f"| {k} | {b['n']} | {pct(b['top1'], b['n'])} | {pct(b['top3'], b['n'])} | {pct(b['base'], b['n'])} | {sorted(b['us'])[len(b['us']) // 2]} µs |")
        for x in tot:
            tot[x] += b[x]
    rows.append(f"| **all** | {tot['n']} | **{pct(tot['top1'], tot['n'])}** | **{pct(tot['top3'], tot['n'])}** | {pct(tot['base'], tot['n'])} | |")
    return '\n'.join(rows), tot


def pct(a, n):
    return f'{100 * a / n:.0f}%' if n else '—'


# ---------------------------------------------------------------- synthetic

def synthetic():
    cases = json.load(open(os.path.join(HERE, 'cases.json')))
    results = rank(cases)
    md, tot = table(results, cases)
    misses = [f"- {r['name']} · {r['tap']}: missed sentence at #{r['rank']}, first was {r['top'][0]} ({', '.join(r['reasons']) or 'closest'})"
              for r in results if r['rank'] != 1]
    summary('## Brain bench · scripted conversations\n\nReactions in the script: "yeah yeah", laughs, a question then silence, '
            'a change of subject, answering while guessing, expressions being learned.\n\n' + md +
            ('\n\nNot first:\n' + '\n'.join(misses) if misses else ''))
    json.dump(results, open(os.path.join(OUT, 'synthetic.json'), 'w'), indent=1)
    # The gate: the missed sentence must almost always be among the three shown.
    ok = tot['top3'] >= 0.95 * tot['n'] and tot['top1'] >= 0.8 * tot['n']
    if not ok:
        summary('\n**Gate failed**: in the first 3 must be ≥ 95%, first ≥ 80%.')
    return 0 if ok else 1


# ---------------------------------------------------------------- audio

def fetch(url, path):
    if not os.path.exists(path):
        print('download', url)
        urllib.request.urlretrieve(url, path)
    return path


def reference_words(meeting, folder):
    """AMI's human transcript: every word with its time, all speakers together."""
    try:
        z = zipfile.ZipFile(fetch(AMI_WORDS, os.path.join(folder, 'ami_manual.zip')))
    except Exception as e:  # the bench still runs without it
        print('no reference transcript:', e)
        return None
    words = []
    for name in z.namelist():
        if re.search(rf'words/{meeting}\.[A-Z]\.words\.xml$', name):
            xml = z.read(name).decode('utf-8', 'ignore')
            for m in re.finditer(r'<w [^>]*starttime="([\d.]+)"[^>]*>([^<]+)</w>', xml):
                if 'punc="true"' in m.group(0):
                    continue
                words.append((float(m.group(1)), m.group(2)))
    return sorted(words)


def wer(ref, hyp):
    r, h = norm(ref), norm(hyp)
    if not r:
        return None
    prev = list(range(len(h) + 1))
    for i in range(1, len(r) + 1):
        cur = [i] + [0] * len(h)
        for j in range(1, len(h) + 1):
            cur[j] = min(prev[j] + 1, cur[j - 1] + 1, prev[j - 1] + (r[i - 1] != h[j - 1]))
        prev = cur
    return prev[-1] / len(r)


# Hesitation sounds: the human transcript writes them, most recognisers rightly leave them out.
# Counting them would blame every recogniser for words nobody needs.
FILLERS = {'um', 'uh', 'uhm', 'umm', 'mm', 'mmm', 'hmm', 'hm', 'mm-hmm', 'uh-huh', 'er', 'erm', 'ah', 'eh', 'oh'}


def norm(text):
    return [w for w in re.findall(r"[a-z0-9']+", text.lower().replace('-', ' ')) if w not in FILLERS]


def explain(sentence):
    code = os.environ.get('ASAID_TESTER_CODE')
    if not code:
        return None
    req = urllib.request.Request(SERVER + '/api/explain', method='POST',
                                 data=json.dumps({'text': sentence, 'heard': 'en-GB', 'native': 'it', 'level': 'B2'}).encode(),
                                 headers={'content-type': 'application/json', 'x-lexalie-code': code})
    t0 = time.time()
    try:
        body = json.loads(urllib.request.urlopen(req, timeout=60).read())
    except Exception as e:
        return {'error': str(e)[:120], 'ms': int((time.time() - t0) * 1000)}
    return {'ms': int((time.time() - t0) * 1000), 'body': body}


def judge(sentence, body):
    """The mark comes from the server (api/judge), with its own keys: only the tester code is needed here."""
    code = os.environ.get('ASAID_TESTER_CODE')
    if not code or not body:
        return None
    req = urllib.request.Request(SERVER + '/api/judge', method='POST',
                                 data=json.dumps({'sentence': sentence, 'explanation': body}).encode(),
                                 headers={'content-type': 'application/json', 'x-lexalie-code': code})
    try:
        return json.loads(urllib.request.urlopen(req, timeout=60).read())
    except Exception as e:
        return {'mark': None, 'why': str(e)[:120]}

def recognisers(clips, folder):
    """The same two-minute clips (what a tap sends) through the recognisers on the device: Whisper
    here, and Apple's on a Mac (bench/apple.swift, job "apple"), against AMI's human transcript.
    No server recogniser (owner, 06/10: the voices stay on the device, nothing is spent)."""
    out = os.path.join(OUT, 'clips')
    os.makedirs(out, exist_ok=True)
    scores = {'whisper (open source)': []}
    times = {}
    listed = []
    for meeting, short, ref, segments, length in clips:
        for start in [60, 300, 600, 900][: int(os.environ.get('BENCH_CLIPS', '4'))]:
            if start + 120 > length:
                continue
            truth = ' '.join(w for t, w in ref if start <= t < start + 120)
            if not truth:
                continue
            name = f'{meeting}-{start}'
            # WAV, for Apple's recognisers on the Mac.
            subprocess.run(['ffmpeg', '-y', '-loglevel', 'error', '-ss', str(start), '-t', '120', '-i', short,
                            '-ac', '1', '-ar', '16000', os.path.join(out, name + '.wav')], check=True)
            listed.append({'name': name, 'file': name + '.wav', 'truth': truth})
            whisper = ' '.join(w.word for s in segments for w in (s.words or []) if start <= w.start < start + 120)
            scores['whisper (open source)'].append(wer(truth, whisper))
            for engine, text, seconds in private_recognisers(os.path.join(out, name + '.wav')):
                scores.setdefault(engine, [])
                if text is not None:
                    scores[engine].append(wer(truth, text))
                    times.setdefault(engine, []).append(seconds)
    json.dump(listed, open(os.path.join(out, 'clips.json'), 'w'), indent=1)
    json.dump({'scores': scores, 'times': times}, open(os.path.join(out, 'scores.json'), 'w'), indent=1)
    return recogniser_table(scores, times)


_PRIVATE = {}


def private_recognisers(wav):
    """Recognisers that can run on the user's own Mac, so the voices never leave it (owner, 02/10:
    the private mode for calls and real life). Only with BENCH_PRIVATE=1: big models, slow on the
    runner's CPU (its times are not a Mac's: Apple chips run them several times faster)."""
    if not os.environ.get('BENCH_PRIVATE'):
        return []
    out = []
    if 'whisper' not in _PRIVATE:
        try:
            from faster_whisper import WhisperModel
            _PRIVATE['whisper'] = WhisperModel('large-v3-turbo', device='cpu', compute_type='int8')
        except Exception as e:
            print('whisper large', str(e)[:200])
            _PRIVATE['whisper'] = None
    if _PRIVATE['whisper']:
        t0 = time.time()
        try:
            import numpy
            with wave.open(wav, 'rb') as w:
                samples = numpy.frombuffer(w.readframes(w.getnframes()), dtype=numpy.int16).astype(numpy.float32) / 32768.0
            segs, _ = _PRIVATE['whisper'].transcribe(samples, language='en', vad_filter=True, condition_on_previous_text=False)
            out.append(('whisper large-v3-turbo (private)', ' '.join(s.text for s in segs), time.time() - t0))
        except Exception as e:
            print('whisper large', str(e)[:200])
            out.append(('whisper large-v3-turbo (private)', None, 0))
    if 'parakeet' not in _PRIVATE:
        try:
            import onnx_asr
            from huggingface_hub import snapshot_download
            local = snapshot_download('istupakov/parakeet-tdt-0.6b-v2-onnx', local_dir=os.path.join(OUT, 'parakeet'))
            _PRIVATE['parakeet'] = onnx_asr.load_model('nemo-parakeet-tdt-0.6b-v2', local)
        except Exception as e:
            print('parakeet', str(e)[:200])
            _PRIVATE['parakeet'] = None
    if _PRIVATE['parakeet']:
        t0 = time.time()
        try:
            text = _PRIVATE['parakeet'].recognize(wav)
            out.append(('parakeet tdt 0.6b v2 (private)', text if isinstance(text, str) else ' '.join(text), time.time() - t0))
        except Exception as e:
            print('parakeet', str(e)[:200])
            out.append(('parakeet tdt 0.6b v2 (private)', None, 0))
    return out


def recogniser_table(scores, times):
    rows = ['| Recogniser | Clips | Wrong words | Time for 2 min |', '|---|---|---|---|']
    for p, s in sorted(scores.items(), key=lambda kv: (sum(kv[1]) / len(kv[1])) if kv[1] else 9):
        if not s:
            rows.append(f'| {p} | 0 | not measured (no key, or failed) | |')
            continue
        t = times.get(p) or []
        rows.append(f"| {p} | {len(s)} | {100 * sum(s) / len(s):.1f}% | {('%.1f s' % (sorted(t)[len(t) // 2])) if t else 'on the runner'} |")
    return ('\n\n### Recognisers on the same clips\n\nTwo-minute clips, like a tap sends, against the human transcript '
            '(hesitation sounds like "um" not counted).\n\n' + '\n'.join(rows))


def apple():
    """Adds Apple's recognisers (run on a Mac by bench/apple.swift) to the table of the same clips."""
    out = os.path.join(OUT, 'clips')
    clips = {c['name']: c for c in json.load(open(os.path.join(out, 'clips.json')))}
    data = json.load(open(os.path.join(out, 'scores.json')))
    scores, times = data['scores'], data['times']
    notes = []
    for line in open(os.path.join(out, 'apple.jsonl')):
        r = json.loads(line)
        engine = r['engine']
        if r.get('error'):
            notes.append(f"- {engine} · {r['name']}: {r['error']}")
            scores.setdefault(engine, [])
            continue
        scores.setdefault(engine, []).append(wer(clips[r['name']]['truth'], r['text']))
        times.setdefault(engine, []).append(r['seconds'])
    summary('## Apple on a Mac vs the others, same clips' + recogniser_table(scores, times) +
            ('\n\nNot transcribed:\n' + '\n'.join(notes[:10]) if notes else ''))
    return 0


def audio():
    import numpy
    from faster_whisper import WhisperModel  # pip install faster-whisper
    folder = os.path.join(OUT, 'audio')
    os.makedirs(folder, exist_ok=True)
    model = WhisperModel(os.environ.get('BENCH_WHISPER', 'base.en'), device='cpu', compute_type='int8')
    cases, asr, clips = [], [], []
    for meeting in MEETINGS:
        try:
            wav = fetch(AMI.format(m=meeting), os.path.join(folder, meeting + '.wav'))
        except Exception as e:
            print('skip', meeting, e)
            continue
        short = os.path.join(folder, meeting + '.16k.wav')
        subprocess.run(['ffmpeg', '-y', '-loglevel', 'error', '-i', wav, '-t', str(MINUTES * 60), '-ac', '1', '-ar', '16000', short], check=True)
        t0 = time.time()
        # The samples themselves, not the file: faster-whisper's own decoder breaks with some PyAV versions.
        with wave.open(short, 'rb') as w:
            pcm = numpy.frombuffer(w.readframes(w.getnframes()), dtype=numpy.int16).astype(numpy.float32) / 32768.0
        segments, info = model.transcribe(pcm, language='en', vad_filter=True, word_timestamps=True)
        segments = list(segments)
        took = time.time() - t0
        length = min(info.duration, MINUTES * 60)
        lines = [{'start': round(s.start, 2), 'end': round(s.end, 2), 'text': s.text.strip(), 'mine': False}
                 for s in segments if s.text.strip()]
        hyp = ' '.join(w.word for s in segments for w in (s.words or []))
        ref = reference_words(meeting, folder)
        error = wer(' '.join(w for t, w in ref if t <= length), hyp) if ref else None
        asr.append({'meeting': meeting, 'minutes': round(length / 60, 1), 'rtf': round(took / max(length, 1), 3),
                    'wer': None if error is None else round(error, 3), 'lines': len(lines)})
        if ref:
            clips.append((meeting, short, ref, segments, length))
        # The missed sentences: long enough to hold something, spread over the meeting.
        long = [i for i, l in enumerate(lines) if len(l['text'].split()) >= 7]
        picks = long[:: max(1, len(long) // 12)][:12]
        for i in picks:
            taps = []
            for label, delay in DELAYS:
                at = lines[i]['end'] + delay
                if at <= length:
                    # The delay the app learned is never exactly this one: ±30%, alternating.
                    learned = delay * (1.3 if (i + len(taps)) % 2 else 0.7) if delay > 1 else delay
                    taps.append({'at': round(at, 2), 'delay': round(learned, 2), 'label': label})
            if lines[i]['end'] + 10 <= length:
                taps.append({'at': round(lines[i]['end'] + 10, 2), 'delay': None, 'label': '10s-new'})
            if taps:
                cases.append({'name': f'{meeting} #{i}', 'lines': lines, 'truth': i, 'taps': taps})
    if not cases:
        summary('## Brain bench · real meetings\n\nNo audio could be downloaded.')
        return 1
    results = rank(cases)
    md, tot = table(results, cases)
    def errors(a):
        return '—' if a['wer'] is None else '%.0f%%' % (100 * a['wer'])
    rec = '\n'.join(f"| {a['meeting']} | {a['minutes']} min | {a['lines']} | {errors(a)} | {a['rtf']}× |" for a in asr)
    text = ('## Brain bench · real meetings (AMI, CC BY 4.0)\n\n'
            'Recogniser: Whisper (open source) standing in for Apple\'s, which is tested by hand on the devices. '
            'Here nobody reacts ("yeah yeah", laughs): it measures closeness and silences only, the hardest case.\n\n'
            '| Meeting | Audio | Sentences | Word errors | Recognition time |\n|---|---|---|---|---|\n' + rec + '\n\n' + md)

    # Explanations: a few of the missed sentences through the real server, marked by a judge model.
    marks, ms, empty = [], [], 0
    sentences = []
    for c in cases:
        s = c['lines'][c['truth']]['text']
        if s not in sentences:
            sentences.append(s)
    for s in sentences[:8]:
        e = explain(s)
        if e is None:
            break
        ms.append(e['ms'])
        body = e.get('body')
        if not body or not body.get('pieces'):
            empty += 1
        j = judge(s, body)
        if j and j.get('mark'):
            marks.append(j['mark'])
    if ms:
        text += (f'\n\n### Explanations\n\n{len(ms)} sentences through /api/explain: median {sorted(ms)[len(ms) // 2]} ms, '
                 f'{empty} with nothing to explain' + (f', judge mark {sum(marks) / len(marks):.1f}/5' if marks else ', judge unavailable') + '.')
    else:
        text += '\n\nExplanations not measured: set ASAID_TESTER_CODE in the repository secrets.'
    text += recognisers(clips, folder)
    summary(text)
    json.dump({'asr': asr, 'results': results}, open(os.path.join(OUT, 'audio.json'), 'w'), indent=1)
    return 0


if __name__ == '__main__':
    sys.exit({'synthetic': synthetic, 'audio': audio, 'apple': apple}[sys.argv[1] if len(sys.argv) > 1 else 'synthetic']())
