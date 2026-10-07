"""Where each word is (07/10): can the ear cut a word out of the real voice?

The tap with the ear replays the missed word with the real voice before saying what it means, cut from
the recogniser's word times. This bench checks those times against AMI's human word times on real
meetings: a sentence at a time, through the same recognisers as the app (Parakeet on the processor
as Intel Macs, FluidAudio on the Neural Engine as Apple chips). Free: runners only.

    python3 bench/wordtimes.py cases                  # sentences from AMI meetings, one clip each
    python3 bench/wordtimes.py sherpa                 # Parakeet on the processor
    python3 bench/wordtimes.py tool NAME BIN [ARGS]   # a Swift tool printing timed words per clip
    python3 bench/wordtimes.py report                 # one table, and whether the cut is good enough

A cut is good when the app's window (start - 0.06 s, end + 0.12 s, as EarFlow.cutRange) holds at least
90% of the word as a person timed it and adds at most 0.30 s of other sound.
"""
import difflib
import glob
import json
import os
import re
import subprocess
import sys
import time
import zipfile

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import run  # noqa: E402
import tap  # noqa: E402

OUT = os.path.join(HERE, 'out', 'wordtimes')
CLIPS = os.path.join(OUT, 'clips')
RESULTS = os.path.join(OUT, 'results')
MEETINGS = os.environ.get('WT_MEETINGS', 'ES2002a,ES2004a,IS1009a,TS3003a').split(',')
PER_MEETING = int(os.environ.get('WT_SENTENCES', '30'))
RATE = 16000
BEFORE, AFTER = 0.5, 0.5
# As EarFlow.cutRange.
PAD_START, PAD_END = 0.06, 0.12


def human_words(meeting, folder):
    """AMI's words with start and end, speaker by speaker, cut into sentences."""
    z = zipfile.ZipFile(run.fetch(run.AMI_WORDS, os.path.join(folder, 'ami_manual.zip')))
    sentences = []
    for name in z.namelist():
        if not re.search(rf'words/{meeting}\.[A-Z]\.words\.xml$', name):
            continue
        xml = z.read(name).decode('utf-8', 'ignore')
        cur = []
        for w in re.finditer(r'<w ([^>]*)>([^<]+)</w>', xml):
            attrs, text = w.group(1), w.group(2)
            if 'punc="true"' in attrs:
                if cur and text in '.?!':
                    sentences.append(cur)
                    cur = []
                continue
            st = re.search(r'starttime="([\d.]+)"', attrs)
            en = re.search(r'endtime="([\d.]+)"', attrs)
            if not st or not en:
                continue
            s, e = float(st.group(1)), float(en.group(1))
            if cur and s - cur[-1][1] > 1.5:
                sentences.append(cur)
                cur = []
            cur.append((s, e, text))
        if cur:
            sentences.append(cur)
    out = []
    for words in sentences:
        words = [w for w in words if run.norm(w[2]) and w[1] > w[0]]
        if len(words) < 6:
            continue
        s, e = words[0][0], words[-1][1]
        if 2 <= e - s <= 12:
            out.append(words)
    return sorted(out, key=lambda ws: ws[0][0])


def syllables(text):
    return max(1, len(re.findall(r'[aeiouy]+', text.lower())))


def cases():
    folder = os.path.join(HERE, 'out', 'audio')
    os.makedirs(folder, exist_ok=True)
    os.makedirs(CLIPS, exist_ok=True)
    listed = []
    for meeting in MEETINGS:
        try:
            wav = run.fetch(run.AMI.format(m=meeting), os.path.join(folder, meeting + '.wav'))
            short = os.path.join(OUT, meeting + '.wav')
            if not os.path.exists(short):
                subprocess.run(['ffmpeg', '-y', '-loglevel', 'error', '-i', wav, '-ac', '1', '-ar', str(RATE), short], check=True)
            pcm = tap.run_samples(short)
            sentences = human_words(meeting, folder)
        except Exception as e:
            print('skip', meeting, e)
            continue
        picks = sentences[:: max(1, len(sentences) // PER_MEETING)][:PER_MEETING]
        for k, words in enumerate(picks):
            a = max(0.0, words[0][0] - BEFORE)
            b = words[-1][1] + AFTER
            cid = f'{meeting}-{k:02d}.wav'
            tap.write_wav(os.path.join(CLIPS, cid), pcm[int(a * RATE):int(b * RATE)])
            text = ' '.join(w[2] for w in words)
            listed.append({'file': cid, 'start': a, 'words': [[s - a, e - a, t] for s, e, t in words],
                           'rate': sum(syllables(w[2]) for w in words) / (words[-1][1] - words[0][0])})
    json.dump(listed, open(os.path.join(OUT, 'cases.json'), 'w'))
    print(len(listed), 'sentences')


def norm(word):
    w = run.norm(word)
    return w[0] if w else ''


def score(engine, heard):
    """Recognised words matched to the human ones in order; then how far the times are."""
    truth = {c['file']: c for c in json.load(open(os.path.join(OUT, 'cases.json')))}
    starts, ends, good, total, matched, fast_good, fast_total = [], [], 0, 0, 0, 0, 0
    for name, case in truth.items():
        got = heard.get(name)
        if not got:
            continue
        human = case['words']
        rec = got['words']
        a = [norm(w[2]) for w in human]
        b = [norm(w[2]) for w in rec]
        total += len(human)
        fast = case['rate'] >= 5.0
        for block in difflib.SequenceMatcher(a=a, b=b, autojunk=False).get_matching_blocks():
            for i in range(block.size):
                h, r = human[block.a + i], rec[block.b + i]
                if not a[block.a + i]:
                    continue
                matched += 1
                starts.append(r[0] - h[0])
                ends.append(r[1] - h[1])
                lo, hi = r[0] - PAD_START, r[1] + PAD_END
                inside = max(0.0, min(hi, h[1]) - max(lo, h[0]))
                extra = (hi - lo) - inside
                ok = inside >= 0.9 * (h[1] - h[0]) and extra <= 0.30
                good += ok
                if fast:
                    fast_total += 1
                    fast_good += ok
    # The margins tried around the recogniser's times: the best one goes into EarFlow.cutRange.
    sweep = {}
    for ps in (0.06, 0.1, 0.15, 0.2, 0.25):
        for pe in (0.12, 0.18, 0.25, 0.32):
            ok_n = n = 0
            for name, case in truth.items():
                got = heard.get(name)
                if not got:
                    continue
                human, rec = case['words'], got['words']
                a = [norm(w[2]) for w in human]
                b = [norm(w[2]) for w in rec]
                for block in difflib.SequenceMatcher(a=a, b=b, autojunk=False).get_matching_blocks():
                    for i in range(block.size):
                        if not a[block.a + i]:
                            continue
                        h, r = human[block.a + i], rec[block.b + i]
                        lo, hi = r[0] - ps, r[1] + pe
                        inside = max(0.0, min(hi, h[1]) - max(lo, h[0]))
                        n += 1
                        ok_n += inside >= 0.9 * (h[1] - h[0]) and (hi - lo) - inside <= 0.45
            sweep[f'{ps}/{pe}'] = round(100 * ok_n / n, 1) if n else None
    def med(xs):
        xs = sorted(abs(x) for x in xs)
        return round(xs[len(xs) // 2], 3) if xs else None
    def p90(xs):
        xs = sorted(abs(x) for x in xs)
        return round(xs[int(len(xs) * 0.9)], 3) if xs else None
    row = {'engine': engine, 'machine': tap.machine(), 'words': total, 'matched': matched,
           'start_error_median': med(starts), 'start_error_p90': p90(starts),
           'end_error_median': med(ends), 'end_error_p90': p90(ends),
           'cut_good': round(100 * good / matched, 1) if matched else None,
           'cut_good_fast': round(100 * fast_good / fast_total, 1) if fast_total else None, 'fast_words': fast_total,
           'sweep': sweep, 'best_margins': max(sweep, key=lambda k: sweep[k] or 0) if sweep else None}
    os.makedirs(RESULTS, exist_ok=True)
    json.dump(row, open(os.path.join(RESULTS, re.sub(r'[^a-z0-9]+', '-', f"{os.environ.get('RUNNER_LABEL', 'local')}-{engine}".lower()) + '.json'), 'w'))
    print(json.dumps(row, indent=1))


def sherpa():
    import tarfile
    import urllib.request
    import sherpa_onnx
    models = os.path.join(HERE, 'out', 'models')
    os.makedirs(models, exist_ok=True)
    folder = os.path.join(models, tap.SHERPA_MODEL)
    if not os.path.isdir(folder):
        archive = folder + '.tar.bz2'
        urllib.request.urlretrieve(f'https://github.com/k2-fsa/sherpa-onnx/releases/download/asr-models/{tap.SHERPA_MODEL}.tar.bz2', archive)
        tarfile.open(archive).extractall(models)
    pick = lambda part: sorted(glob.glob(os.path.join(folder, f'{part}*.onnx')))[0]  # noqa: E731
    rec = sherpa_onnx.OfflineRecognizer.from_transducer(
        encoder=pick('encoder'), decoder=pick('decoder'), joiner=pick('joiner'), tokens=os.path.join(folder, 'tokens.txt'),
        num_threads=max(1, (os.cpu_count() or 2) // 2), model_type='nemo_transducer', decoding_method='greedy_search')
    heard = {}
    for path in sorted(glob.glob(os.path.join(CLIPS, '*.wav'))):
        t0 = time.time()
        heard[os.path.basename(path)] = {'seconds': time.time() - t0, 'words': tap.sherpa_words(rec, tap.run_samples(path))}
    score('Parakeet compressed, processor (sherpa-onnx int8)', heard)


def tool(name, binary, *args):
    res = subprocess.run([binary, *args, CLIPS], capture_output=True, text=True)
    print(res.stderr[-2000:])
    heard = {}
    for line in res.stdout.splitlines():
        try:
            row = json.loads(line)
        except Exception:
            continue
        heard[row['file']] = {'seconds': row['seconds'], 'words': [[float(w[0]), float(w[1]), w[2]] for w in row['words']]}
    score(name, heard)


def report():
    rows = [json.load(open(p)) for p in sorted(glob.glob(os.path.join(HERE, 'out', 'wtresults', '**', '*.json'), recursive=True))]
    lines = ['| Recogniser | Machine | Words matched | Start error (median / 90%) | End error (median / 90%) | Good cuts | Good cuts, fast speech |',
             '|---|---|---|---|---|---|---|']
    for r in rows:
        lines.append(f"| {r['engine']} | {r['machine']} | {r['matched']} of {r['words']} | {r['start_error_median']} s / {r['start_error_p90']} s | "
                     f"{r['end_error_median']} s / {r['end_error_p90']} s | {r['cut_good']}% | {r['cut_good_fast']}% ({r['fast_words']}) |")
    for r in rows:
        lines.append(f"\n{r['engine']}: best margins (before/after, s, whole word heard and at most 0.45 s more) {r.get('best_margins')}: "
                     + ', '.join(f"{k} {v}%" for k, v in (r.get('sweep') or {}).items()))
    text = '\n'.join(lines)
    print(text)
    summary = os.environ.get('GITHUB_STEP_SUMMARY')
    if summary:
        open(summary, 'a').write('## Where each word is (the ear\'s cut)\n\n' + text + '\n')
    json.dump(rows, open(os.path.join(HERE, 'out', 'wordtimes-summary.json'), 'w'), indent=1)


if __name__ == '__main__':
    cmd = sys.argv[1] if len(sys.argv) > 1 else 'report'
    if cmd == 'cases':
        cases()
    elif cmd == 'sherpa':
        sherpa()
    elif cmd == 'tool':
        tool(*sys.argv[2:])
    else:
        report()
