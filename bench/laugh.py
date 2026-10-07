"""Laughter (07/10): does the Mac hear people laugh in a call, for "why they laughed"?

The app checks the last 10 seconds of a call every 10 seconds with Apple's sound classifier
(ToneMeter.laughter). This bench runs that same code on AMI meetings, where people marked every laugh
by hand, and counts the windows it gets right. Free: runners only.

    python3 bench/laugh.py cases         # meetings, cut to 20 minutes, mono 16 kHz
    python3 bench/laugh.py score OUT     # OUT: the Swift tool's lines; prints precision and recall
"""
import json
import os
import re
import subprocess
import sys
import zipfile

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import run  # noqa: E402

OUT = os.path.join(HERE, 'out', 'laugh')
MEETINGS = os.environ.get('LAUGH_MEETINGS', 'ES2002a,ES2004a,IS1009a,TS3003a').split(',')
MINUTES = 20


def laughs(meeting, folder):
    z = zipfile.ZipFile(run.fetch(run.AMI_WORDS, os.path.join(folder, 'ami_manual.zip')))
    spans = []
    for name in z.namelist():
        if re.search(rf'words/{meeting}\.[A-Z]\.words\.xml$', name):
            xml = z.read(name).decode('utf-8', 'ignore')
            for m in re.finditer(r'<vocalsound ([^>]*)/?>', xml):
                attrs = m.group(1)
                if 'type="laugh"' not in attrs:
                    continue
                st = re.search(r'starttime="([\d.]+)"', attrs)
                en = re.search(r'endtime="([\d.]+)"', attrs)
                if st and en:
                    spans.append((float(st.group(1)), float(en.group(1))))
    return sorted(spans)


def cases():
    folder = os.path.join(HERE, 'out', 'audio')
    os.makedirs(folder, exist_ok=True)
    os.makedirs(os.path.join(OUT, 'wav'), exist_ok=True)
    truth = {}
    for meeting in MEETINGS:
        try:
            wav = run.fetch(run.AMI.format(m=meeting), os.path.join(folder, meeting + '.wav'))
            short = os.path.join(OUT, 'wav', meeting + '.wav')
            subprocess.run(['ffmpeg', '-y', '-loglevel', 'error', '-i', wav, '-t', str(MINUTES * 60), '-ac', '1', '-ar', '16000', short], check=True)
            truth[meeting + '.wav'] = [s for s in laughs(meeting, folder) if s[0] < MINUTES * 60]
        except Exception as e:
            print('skip', meeting, e)
    json.dump(truth, open(os.path.join(OUT, 'truth.json'), 'w'))
    print({k: len(v) for k, v in truth.items()}, 'laughs')


def score(path):
    truth = json.load(open(os.path.join(OUT, 'truth.json')))
    tp = fp = fn = tn = 0
    for line in open(path):
        try:
            row = json.loads(line)
        except Exception:
            continue
        a, b = row['start'], row['start'] + 10
        # A laugh of at least half a second inside the window.
        real = any(min(b, e) - max(a, s) >= 0.5 for s, e in truth.get(row['file'], []))
        if row['laugh'] and real:
            tp += 1
        elif row['laugh']:
            fp += 1
        elif real:
            fn += 1
        else:
            tn += 1
    precision = round(100 * tp / (tp + fp), 1) if tp + fp else None
    recall = round(100 * tp / (tp + fn), 1) if tp + fn else None
    text = (f"| {os.environ.get('RUNNER_LABEL', 'local')} | {tp + fn} windows with laughter of {tp + fp + fn + tn} | "
            f"heard {tp} | missed {fn} | false alarms {fp} | precision {precision}% | recall {recall}% |")
    print(text)
    summary = os.environ.get('GITHUB_STEP_SUMMARY')
    if summary:
        open(summary, 'a').write('## Laughter in calls (ToneMeter.laughter on AMI)\n\n| Machine | Laughter | Heard | Missed | False alarms | Precision | Recall |\n|---|---|---|---|---|---|---|\n' + text + '\n')


if __name__ == '__main__':
    if sys.argv[1] == 'cases':
        cases()
    else:
        score(sys.argv[2])
