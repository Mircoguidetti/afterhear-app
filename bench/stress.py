"""Stress test of the recognisers that can run on the user's own device (docs/BRAIN.md § 19.22).

    python3 bench/stress.py clips <condition>   # cut the clips, make the condition, transcribe, score
    python3 bench/stress.py table               # all conditions in one table (after the jobs)

Same audio for everyone: two-minute clips from real meetings (AMI corpus, CC BY 4.0, six
meetings, four clips each), in three conditions:
- clean: as recorded;
- fast:  25% faster (a film where they speak quickly), pitch kept;
- noisy: another meeting mixed underneath at about 5 dB below (a bar, people around);
plus "invented": 60 s of music-like sound and noise, nobody speaking: every word written there
is made up (Whisper's known flaw);
- languages: Spanish, French and German, 10 sentences each from FLEURS (Google, CC BY 4.0):
  real people, but reading aloud, so everyone looks better than in a conversation; it compares
  the recognisers language by language (owner, 02/10: Chinese left out for now).

Recognisers: on the device, free: Whisper large-v3-turbo, Parakeet TDT 0.6B v2 (English only) and
v3 (25 European languages); no paid service (owner, 06/10: the voices stay on the device, nothing
is spent). Scoring as run.py (fillers not counted), and numbers as words on both sides
("25" = "twenty five"), so nobody is blamed for writing digits.
Times are the runner's CPU: Apple chips run these models several times faster.
"""
import json
import os
import re
import subprocess
import sys
import time
import wave

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import run  # noqa: E402

OUT = os.path.join(run.OUT, 'stress')
MEETINGS = os.environ.get('STRESS_MEETINGS', 'ES2002a,ES2004a,IS1009a,IS1001a,TS3003a,EN2002a').split(',')
STARTS = [60, 300, 600, 900]

ONES = 'zero one two three four five six seven eight nine ten eleven twelve thirteen fourteen fifteen sixteen seventeen eighteen nineteen'.split()
TENS = 'twenty thirty forty fifty sixty seventy eighty ninety'.split()


def spoken(n):
    """12 → twelve, 25 → twenty five, 1999 → one thousand nine hundred ninety nine."""
    if n < 20:
        return ONES[n]
    if n < 100:
        return TENS[n // 10 - 2] + ('' if n % 10 == 0 else ' ' + ONES[n % 10])
    if n < 1000:
        return ONES[n // 100] + ' hundred' + ('' if n % 100 == 0 else ' ' + spoken(n % 100))
    if n < 1_000_000:
        return spoken(n // 1000) + ' thousand' + ('' if n % 1000 == 0 else ' ' + spoken(n % 1000))
    return str(n)


def words(text):
    text = re.sub(r'\d+', lambda m: ' ' + spoken(int(m.group(0))) + ' ', text or '')
    return ' '.join(run.norm(text))


def wer(ref, hyp, lang='en'):
    if lang == 'en':
        return run.wer(words(ref), words(hyp))
    # Other languages: letters with accents kept, punctuation and apostrophes out, digits as written.
    def plain(t):
        t = re.sub(r"[’'\-]", ' ', (t or '').lower())
        return ' '.join(re.findall(r'\w+', t))
    return run.wer(plain(ref), plain(hyp)) if plain(ref) else None


FLEURS = 'https://huggingface.co/datasets/google/fleurs/resolve/main/data/{c}/'
LANGS = {'es': 'es_419', 'fr': 'fr_fr', 'de': 'de_de'}
PER_LANGUAGE = 10


def fleurs(folder):
    """The first sentences of FLEURS' test set in each language, with what was read."""
    import tarfile
    import urllib.request
    out = []
    for lang, code in LANGS.items():
        truth = {}
        tsv = urllib.request.urlopen(FLEURS.format(c=code) + 'test.tsv', timeout=120).read().decode('utf-8')
        for line in tsv.splitlines():
            f = line.split('\t')
            if len(f) > 2:
                truth.setdefault(f[1], f[2])
        taken = 0
        with urllib.request.urlopen(FLEURS.format(c=code) + 'audio/test.tar.gz', timeout=300) as r:
            with tarfile.open(fileobj=r, mode='r|gz') as tar:
                for member in tar:
                    name = os.path.basename(member.name)
                    if not member.isfile() or name not in truth:
                        continue
                    raw = os.path.join(folder, f'{lang}-{name}')
                    with open(raw, 'wb') as w:
                        w.write(tar.extractfile(member).read())
                    wav = os.path.join(folder, f'{lang}-{taken:02d}.wav')
                    ffmpeg('-i', raw, '-ac', '1', '-ar', '16000', wav)
                    os.remove(raw)
                    out.append({'name': f'{lang}-{taken:02d}', 'file': wav, 'truth': truth[name], 'lang': lang})
                    taken += 1
                    if taken >= PER_LANGUAGE:
                        break
        print('fleurs', lang, taken, flush=True)
    return out


def pcm(path):
    import numpy
    with wave.open(path, 'rb') as w:
        return numpy.frombuffer(w.readframes(w.getnframes()), dtype=numpy.int16).astype(numpy.float32) / 32768.0


def ffmpeg(*args):
    subprocess.run(['ffmpeg', '-y', '-loglevel', 'error', *args], check=True)


def cut(condition):
    """The clips of one condition, as 16 kHz mono WAV, with the human transcript."""
    audio = os.path.join(run.OUT, 'audio')
    folder = os.path.join(OUT, condition)
    os.makedirs(audio, exist_ok=True)
    os.makedirs(folder, exist_ok=True)
    if condition == 'languages':
        return fleurs(folder)
    full = {}
    for m in MEETINGS:
        try:
            wav = run.fetch(run.AMI.format(m=m), os.path.join(audio, m + '.wav'))
        except Exception as e:
            print('skip', m, e)
            continue
        short = os.path.join(audio, m + '.16k.wav')
        if not os.path.exists(short):
            ffmpeg('-i', wav, '-t', '1080', '-ac', '1', '-ar', '16000', short)
        full[m] = short
    clips = []
    for m, short in full.items():
        ref = run.reference_words(m, audio)
        if not ref:
            continue
        others = [x for x in full if x != m]
        for start in STARTS:
            truth = ' '.join(w for t, w in ref if start <= t < start + 120)
            if len(truth.split()) < 40:
                continue
            name = f'{m}-{start}'
            out = os.path.join(folder, name + '.wav')
            if condition == 'clean':
                ffmpeg('-ss', str(start), '-t', '120', '-i', short, out)
            elif condition == 'fast':
                # 25% faster, same pitch: 120 s of speech in 96 s. Same words, so the same transcript.
                ffmpeg('-ss', str(start), '-t', '120', '-i', short, '-filter:a', 'atempo=1.25', out)
            elif condition == 'noisy':
                babble = full[others[len(clips) % len(others)]] if others else short
                ffmpeg('-ss', str(start), '-t', '120', '-i', short, '-ss', str(start + 200), '-t', '120', '-i', babble,
                       '-filter_complex', '[1:a]volume=0.56[b];[0:a][b]amix=inputs=2:duration=first:normalize=0', out)
            clips.append({'name': name, 'file': out, 'truth': truth, 'lang': 'en'})
    if condition == 'clean':
        # Nobody speaking: chords and noise, 60 s. Whatever is written here is invented.
        out = os.path.join(folder, 'invented-music.wav')
        ffmpeg('-f', 'lavfi', '-i', 'aevalsrc=0.2*sin(2*PI*220*t)+0.15*sin(2*PI*277*t)+0.12*sin(2*PI*330*t)*sin(2*PI*0.5*t):s=16000:d=60',
               '-f', 'lavfi', '-i', 'anoisesrc=color=pink:amplitude=0.05:d=60:r=16000',
               '-filter_complex', 'amix=inputs=2:normalize=0', '-ac', '1', '-ar', '16000', out)
        clips.append({'name': 'invented-music', 'file': out, 'truth': '', 'lang': 'en'})
    return clips


def recognisers():
    """(name, languages it can do or None for all, function(path, lang) -> text)."""
    found = []
    # Whisper large was measured on 02/10 and lost to Parakeet everywhere: off unless asked.
    try:
        if not os.environ.get('STRESS_WHISPER'):
            raise RuntimeError('skipped (measured on 02/10, behind Parakeet)')
        from faster_whisper import WhisperModel
        model = WhisperModel('large-v3-turbo', device='cpu', compute_type='int8')

        def whisper(path, lang):
            segs, _ = model.transcribe(pcm(path), language=lang, vad_filter=True, condition_on_previous_text=False)
            return ' '.join(s.text for s in segs)
        found.append(('Whisper large-v3-turbo', None, whisper))
    except Exception as e:
        print('whisper large:', str(e)[:300])
    try:
        import onnx_asr
        from huggingface_hub import snapshot_download
        # A real folder, not the hub's links: onnxruntime refuses weights outside the model folder.
        for version, langs in (('v2', {'en'}), ('v3', None)):
            local = snapshot_download(f'istupakov/parakeet-tdt-0.6b-{version}-onnx', local_dir=os.path.join(run.OUT, f'parakeet-{version}'))
            model_p = onnx_asr.load_model(f'nemo-parakeet-tdt-0.6b-{version}', local)

            def parakeet(path, lang, m=model_p):
                text = m.recognize(path)
                return text if isinstance(text, str) else ' '.join(text)
            found.append((f'Parakeet TDT 0.6B {version}', langs, parakeet))
    except Exception as e:
        print('parakeet:', str(e)[:300])
    return found


def wanted(engine):
    """STRESS_ONLY=whisper,parakeet…: only those (the others were measured already)."""
    only = [w.strip().lower() for w in os.environ.get('STRESS_ONLY', '').split(',') if w.strip()]
    return not only or any(w in engine.lower() for w in only)


def clips(condition):
    items = cut(condition)
    rows = []
    from concurrent.futures import ThreadPoolExecutor

    def one(engine, fn, c):
        t0 = time.time()
        try:
            hyp, error = fn(c['file'], c['lang']), None
        except Exception as e:
            hyp, error = '', str(e)[:200]
        seconds = time.time() - t0
        row = {'condition': condition, 'engine': engine, 'clip': c['name'], 'lang': c['lang'],
               'seconds': round(seconds, 1), 'hyp': hyp, 'error': error}
        if error:
            print(engine, c['name'], 'error:', error, flush=True)
        if c['truth']:
            row['wer'] = wer(c['truth'], hyp, c['lang']) if error is None else None
        else:
            row['invented'] = len(words(hyp).split())
        print(engine, condition, c['name'], row.get('wer', row.get('invented')), f'{seconds:.0f}s', flush=True)
        return row

    for engine, langs, fn in recognisers():
        if not wanted(engine):
            continue
        todo = [c for c in items if langs is None or c['lang'] in langs]
        # The servers work in parallel (a few at a time); the models on this machine one by one.
        workers = 6 if '(server)' in engine else 1
        with ThreadPoolExecutor(max_workers=workers) as pool:
            rows += list(pool.map(lambda c: one(engine, fn, c), todo))
    json.dump({'clips': [{k: c[k] for k in ('name', 'truth', 'lang')} for c in items], 'rows': rows},
              open(os.path.join(OUT, f'{condition}.json'), 'w'), indent=1)
    return 0


def table():
    rows = []
    for name in ('clean', 'fast', 'noisy', 'languages'):
        path = os.path.join(OUT, f'{name}.json')
        if os.path.exists(path):
            rows += json.load(open(path))['rows']
    engines = sorted({r['engine'] for r in rows})
    md = ['| Recogniser | Clean | Fast (+25%) | Noisy | Words invented on music | Runner time per 2 min |', '|---|---|---|---|---|---|']
    for e in engines:
        cells = []
        for cond in ('clean', 'fast', 'noisy'):
            s = [r['wer'] for r in rows if r['engine'] == e and r['condition'] == cond and r.get('wer') is not None]
            cells.append(f'{100 * sum(s) / len(s):.1f}% ({len(s)})' if s else '—')
        inv = [r['invented'] for r in rows if r['engine'] == e and 'invented' in r]
        t = sorted(r['seconds'] for r in rows if r['engine'] == e and r['condition'] == 'clean' and 'wer' in r)
        md.append(f"| {e} | {' | '.join(cells)} | {inv[0] if inv else '—'} | {t[len(t) // 2] if t else '—'} s |")
    lang_md = ['| Recogniser | ' + ' | '.join(LANGS) + ' |', '|---|' + '---|' * len(LANGS)]
    for e in engines:
        cells = []
        for lang in LANGS:
            s = [r['wer'] for r in rows if r['engine'] == e and r['condition'] == 'languages' and r.get('lang') == lang and r.get('wer') is not None]
            cells.append(f'{100 * sum(s) / len(s):.1f}% ({len(s)})' if s else '—')
        if any(c != '—' for c in cells):
            lang_md.append(f"| {e} | {' | '.join(cells)} |")
    run.summary('## Stress test: recognisers on the device and on servers\n\n'
                'English: real meetings. Word errors against the human transcript (lower is better), number of clips in brackets. '
                'Fillers ("um") not counted, numbers compared as words. Times on the runner\'s CPU, not a Mac.\n\n' + '\n'.join(md) +
                '\n\n### Other languages (FLEURS, read aloud)\n\n' + '\n'.join(lang_md))
    return 0


if __name__ == '__main__':
    mode = sys.argv[1] if len(sys.argv) > 1 else 'table'
    sys.exit(clips(sys.argv[2]) if mode == 'clips' else table())
