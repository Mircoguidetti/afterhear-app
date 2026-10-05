"""The compressed model test (docs/PIANO.md, block D): the same Parakeet, whole or compressed,
on the same real meetings, on Apple chips and on Intel.

    python3 bench/compressed.py clips          # 2-minute clips of AMI meetings + the human transcript
    python3 bench/compressed.py sherpa         # every sherpa-onnx version of Parakeet (what Intel Macs run)
    python3 bench/compressed.py fluid BIN      # FluidAudio on the Neural Engine (what Apple chips run)
    python3 bench/compressed.py report         # one table from all the runners

For each model: wrong words against AMI's human transcript, memory (peak, and after loading),
space on disk, time to load and to transcribe two minutes, both as one tap clip (two minutes at
once) and as live listening (15-second pieces). The numbers go to the job summary.
"""
import glob
import json
import os
import platform
import resource
import subprocess
import sys
import tarfile
import time
import urllib.request
import wave

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import run  # noqa: E402  the bench's own AMI download, transcript and word error rate

OUT = os.path.join(HERE, 'out')
CLIPS = os.path.join(OUT, 'cclips')
RESULTS = os.path.join(OUT, 'compressed')
SHERPA = 'https://github.com/k2-fsa/sherpa-onnx/releases/download/asr-models/{}.tar.bz2'
# The one the Intel app runs today first; the others to compare. Missing ones are skipped.
SHERPA_MODELS = [
    'sherpa-onnx-nemo-parakeet-tdt-0.6b-v2-int8',
    'sherpa-onnx-nemo-parakeet-tdt-0.6b-v2-fp16',
    'sherpa-onnx-nemo-parakeet-tdt-0.6b-v2',
    'sherpa-onnx-nemo-parakeet-tdt-0.6b-v3-int8',
    'sherpa-onnx-nemo-parakeet-tdt-0.6b-v3',
]
LIVE_SECONDS = 15


def machine():
    name = os.environ.get('RUNNER_LABEL') or platform.platform()
    return f'{name} ({platform.machine()})'


def clips():
    """Eight clips of two minutes (what a tap sends) from two AMI meetings, with the human words."""
    folder = os.path.join(OUT, 'audio')
    os.makedirs(folder, exist_ok=True)
    os.makedirs(CLIPS, exist_ok=True)
    listed = []
    for meeting in run.MEETINGS:
        wav = run.fetch(run.AMI.format(m=meeting), os.path.join(folder, meeting + '.wav'))
        ref = run.reference_words(meeting, folder) or []
        for start in [60, 300, 600, 900]:
            truth = ' '.join(w for t, w in ref if start <= t < start + 120)
            if not truth:
                continue
            name = f'{meeting}-{start}.wav'
            subprocess.run(['ffmpeg', '-y', '-loglevel', 'error', '-ss', str(start), '-t', '120', '-i', wav,
                            '-ac', '1', '-ar', '16000', '-sample_fmt', 's16', os.path.join(CLIPS, name)], check=True)
            listed.append({'file': name, 'truth': truth})
    json.dump(listed, open(os.path.join(CLIPS, 'clips.json'), 'w'), indent=1)
    print(len(listed), 'clips')
    return 0 if listed else 1


def samples(path):
    import numpy
    with wave.open(path, 'rb') as w:
        return numpy.frombuffer(w.readframes(w.getnframes()), dtype=numpy.int16).astype(numpy.float32) / 32768.0


def rss_now():
    import psutil
    return psutil.Process().memory_info().rss


def rss_peak():
    peak = resource.getrusage(resource.RUSAGE_SELF).ru_maxrss
    return peak if sys.platform == 'darwin' else peak * 1024  # bytes on macOS, KB on Linux


def size(folder):
    return sum(os.path.getsize(f) for f in glob.glob(os.path.join(folder, '**', '*'), recursive=True) if os.path.isfile(f))


def sherpa_one(name):
    """One model in its own process, so the memory is that model's alone."""
    import sherpa_onnx
    models = os.path.join(OUT, 'models')
    os.makedirs(models, exist_ok=True)
    folder = os.path.join(models, name)
    if not os.path.isdir(folder):
        archive = os.path.join(models, name + '.tar.bz2')
        try:
            urllib.request.urlretrieve(SHERPA.format(name), archive)
        except Exception as e:
            return {'model': name, 'missing': str(e)[:80]}
        tarfile.open(archive).extractall(models)
        os.remove(archive)

    def pick(part):
        found = sorted(glob.glob(os.path.join(folder, f'{part}*.onnx')))
        return found[0]

    before = rss_now()
    t0 = time.time()
    rec = sherpa_onnx.OfflineRecognizer.from_transducer(
        encoder=pick('encoder'), decoder=pick('decoder'), joiner=pick('joiner'),
        tokens=os.path.join(folder, 'tokens.txt'), num_threads=max(1, (os.cpu_count() or 2) // 2),
        model_type='nemo_transducer', decoding_method='greedy_search', sample_rate=16000, feature_dim=80)
    load = time.time() - t0
    loaded = rss_now() - before

    def transcribe(pcm):
        s = rec.create_stream()
        s.accept_waveform(16000, pcm)
        rec.decode_stream(s)
        return s.result.text

    return measure(name, 'sherpa-onnx (processor)', size(folder), load, loaded, transcribe)


def measure(model, engine, disk, load, loaded, transcribe):
    listed = json.load(open(os.path.join(CLIPS, 'clips.json')))
    tap_errors, live_errors, tap_times, live_times = [], [], [], []
    for clip in listed:
        pcm = samples(os.path.join(CLIPS, clip['file']))
        t0 = time.time()
        text = transcribe(pcm)
        tap_times.append(time.time() - t0)
        tap_errors.append(run.wer(clip['truth'], text))
        t0 = time.time()
        step = 16000 * LIVE_SECONDS
        text = ' '.join(transcribe(pcm[i:i + step]) for i in range(0, len(pcm), step))
        live_times.append(time.time() - t0)
        live_errors.append(run.wer(clip['truth'], text))
    mid = lambda xs: sorted(xs)[len(xs) // 2] if xs else None  # noqa: E731
    return {'model': model, 'engine': engine, 'machine': machine(), 'clips': len(listed),
            'disk_mb': round(disk / 1e6), 'load_s': round(load, 1), 'loaded_mb': round(loaded / 1e6),
            'peak_mb': round(rss_peak() / 1e6),
            'tap_wer': round(100 * sum(tap_errors) / len(tap_errors), 1),
            'live_wer': round(100 * sum(live_errors) / len(live_errors), 1),
            'tap_s': round(mid(tap_times), 1), 'live_s': round(mid(live_times), 1)}


def sherpa():
    os.makedirs(RESULTS, exist_ok=True)
    rows = []
    for name in SHERPA_MODELS:
        res = subprocess.run([sys.executable, __file__, 'sherpa-one', name], capture_output=True, text=True)
        line = (res.stdout.strip().splitlines() or [''])[-1]
        try:
            rows.append(json.loads(line))
        except Exception:
            rows.append({'model': name, 'engine': 'sherpa-onnx (processor)', 'machine': machine(),
                         'failed': (res.stderr or res.stdout)[-300:]})
        print(rows[-1], flush=True)
    tag = os.environ.get('RUNNER_LABEL', 'local')
    json.dump(rows, open(os.path.join(RESULTS, f'sherpa-{tag}.json'), 'w'), indent=1)
    return 0


def fluid(binary):
    """The Swift tool in bench/fluid (FluidAudio, as Parakeet.swift uses it) prints one JSON line
    per model; here only the words are scored."""
    os.makedirs(RESULTS, exist_ok=True)
    listed = json.load(open(os.path.join(CLIPS, 'clips.json')))
    rows = []
    for version in ['v2', 'ultra']:
        res = subprocess.run([binary, version, CLIPS], capture_output=True, text=True)
        print(res.stderr[-2000:])
        try:
            out = json.loads(res.stdout.strip().splitlines()[-1])
        except Exception:
            rows.append({'model': f'fluidaudio-{version}', 'engine': 'FluidAudio (Neural Engine)', 'machine': machine(),
                         'failed': (res.stderr or res.stdout)[-300:]})
            continue
        truths = {c['file']: c['truth'] for c in listed}
        tap = [run.wer(truths[f], t) for f, t in out.pop('tap_texts').items()]
        live = [run.wer(truths[f], t) for f, t in out.pop('live_texts').items()]
        out.update({'engine': 'FluidAudio (Neural Engine)', 'machine': machine(), 'clips': len(tap),
                    'tap_wer': round(100 * sum(tap) / len(tap), 1), 'live_wer': round(100 * sum(live) / len(live), 1)})
        rows.append(out)
        print(out, flush=True)
    tag = os.environ.get('RUNNER_LABEL', 'local')
    json.dump(rows, open(os.path.join(RESULTS, f'fluid-{tag}.json'), 'w'), indent=1)
    return 0


def report():
    rows = []
    for path in sorted(glob.glob(os.path.join(OUT, '**', '*.json'), recursive=True)):
        if os.path.basename(path).startswith(('sherpa-', 'fluid-')):
            rows += json.load(open(path))
    lines = ['## Compressed model test (block D)', '',
             'Same eight two-minute clips of real meetings (AMI, CC BY 4.0) for every model. '
             '"Tap" = two minutes at once, as a tap; "live" = 15-second pieces, as while listening. '
             'Memory: peak while transcribing, and what loading the model added. Runner times are not a Mac\'s at home: compare rows on the same runner.',
             '', '| Runner | Engine | Model | Wrong words (tap) | Wrong words (live) | Peak memory | Model in memory | On disk | Load | 2 min (tap) | 2 min (live) |',
             '|---|---|---|---|---|---|---|---|---|---|---|']
    for r in sorted(rows, key=lambda r: (r.get('machine', ''), r.get('engine', ''), r.get('model', ''))):
        if 'missing' in r:
            continue
        if 'failed' in r:
            lines.append(f"| {r['machine']} | {r['engine']} | {r['model']} | failed: {r['failed'][-120:].replace('|', '/').replace(chr(10), ' ')} |||||||| ")
            continue
        lines.append(f"| {r['machine']} | {r['engine']} | {r['model']} | {r['tap_wer']}% | {r['live_wer']}% | {r['peak_mb']} MB | "
                     f"{r['loaded_mb']} MB | {r['disk_mb']} MB | {r['load_s']} s | {r['tap_s']} s | {r['live_s']} s |")
    run.summary('\n'.join(lines))
    json.dump(rows, open(os.path.join(OUT, 'compressed-all.json'), 'w'), indent=1)
    return 0


if __name__ == '__main__':
    cmd = sys.argv[1] if len(sys.argv) > 1 else 'report'
    if cmd == 'sherpa-one':
        print(json.dumps(sherpa_one(sys.argv[2])))
        sys.exit(0)
    sys.exit({'clips': clips, 'sherpa': sherpa, 'report': report}[cmd]() if cmd != 'fluid' else fluid(sys.argv[2]))
