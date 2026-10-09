"""The deal card (private equity first, owner 09/10) through the real server: Gemini, only by hand.

  python3 bench/deal.py corpus     # free: Earnings-21 and Earnings-22 human transcripts (sparse clone)
  python3 bench/deal.py run        # 8 single calls + 3 companies call after call with a dossier (17 calls)
  python3 bench/deal.py show       # free: an earlier run's results as lines in the log
  python3 bench/deal.py replay     # the chain calls of an earlier run again, each with the same dossier it had

Real public calls (Rev.com's Earnings-21 and Earnings-22, CC BY-SA 4.0) stand in for the calls a deal
team has with management: figures, guidance, analysts' questions, and answers that go around them.
The single calls test figures, traps, claims and dodged questions. For three companies with several
calls (MTN Ghana four years, Telkom Indonesia two calls, one Polish company three), each call's
card is turned into dossier facts as the app does, and the next call is read against them: that
tests "what doesn't match the earlier calls". Marked by hand from the log.
"""
import json
import os
import subprocess
import sys
import time

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import insieme  # noqa: E402

OUT = os.path.join(HERE, 'out', 'deal')
CORPUS = os.path.join(HERE, 'out', 'earnings')
GIT = 'https://github.com/revdotcom/speech-datasets.git'
SINGLE = ['4341191', '4366302', '4344338', '4320211', '4364366', '4360674', '4359971', '4346818']
CHAINS = {
    'MTN Ghana': ['mtngh_fy18_call_audio_04032019', '2020-03-0230487MTN-Ghana-2019-Annual-Results-Call',
                  '2020-Annual-Results-Call-Recording', 'MTN-Ghana-2021-Third-Quarter-Results-Call'],
    'Telkom Indonesia': ['4351517', '4426736'],
    'Polish company (OTGLF)': ['4432298', '4453085', '4472403'],
}


def corpus():
    if not os.path.isdir(os.path.join(CORPUS, '.git')):
        subprocess.run(['git', 'clone', '--depth', '1', '--filter=blob:none', '--sparse', GIT, CORPUS], check=True)
    subprocess.run(['git', '-C', CORPUS, 'sparse-checkout', 'set', 'earnings21/transcripts/nlp_references',
                    'earnings22/transcripts/force_aligned_nlp_references'], check=True)
    for f in SINGLE + [f for c in CHAINS.values() for f in c]:
        print(f, len(lines(f)), 'lines')


def path(f):
    a = os.path.join(CORPUS, 'earnings21', 'transcripts', 'nlp_references', f + '.nlp')
    return a if os.path.exists(a) else os.path.join(CORPUS, 'earnings22', 'transcripts', 'force_aligned_nlp_references', f + '.aligned.nlp')


def lines(f):
    """The call as the app's lines: one per sentence, who = speaker id."""
    rows = [r.rstrip('\n').split('|') for r in open(path(f), encoding='utf-8')][1:]
    out, cur, speaker = [], [], None
    for r in rows:
        token, sp, punct = r[0], r[1], r[4]
        if speaker is not None and sp != speaker and cur:
            out.append((speaker, ' '.join(cur)))
            cur = []
        speaker = sp
        cur.append(token + punct)
        if punct and punct in '.?!':
            out.append((speaker, ' '.join(cur)))
            cur = []
    if cur:
        out.append((speaker, ' '.join(cur)))
    return [{'i': k, 'who': f'speaker {sp}', 'text': t[:1200]} for k, (sp, t) in enumerate(out)][:2500]


def card(f, dossier):
    ls = lines(f)
    started = time.time()
    answer = insieme.post('/api/endcard', {'mode': 'deal', 'source': 'management', 'lines': ls, 'native': 'it',
                                           'heard': 'en', 'dossier': dossier})
    return ls, answer, round(time.time() - started, 1)


def facts(f, answer, date):
    """The card's figures and claims as dossier facts, the way the app keeps them."""
    out = []
    for k, n in enumerate(answer.get('numbers', [])):
        q = f" ({n['qualifier']})" if n.get('qualifier') else ''
        out.append({'id': f'{f}-n{k}', 'source': 'management', 'date': date, 'topic': n['topic'],
                    'fact': f"{n['metric']}: {n['value']}{q} [{n['status']}]"[:300]})
    for k, c in enumerate(answer.get('claims', [])):
        out.append({'id': f'{f}-c{k}', 'source': 'management', 'date': date, 'topic': c['topic'], 'fact': c['claim'][:300]})
    return out


def run():
    insieme.check_version('/api/endcard', os.environ.get('INSIEME_EXPECT_ENDCARD', ''))
    rows = []
    only = os.environ.get('DEAL_ONLY', '')
    for f in ([] if only else SINGLE):
        ls, answer, secs = card(f, [])
        rows.append({'group': 'single', 'file': f, 'seconds': secs, 'card': answer, 'text': {l['i']: l['text'] for l in ls}})
        print(f, {k: len(answer.get(k, [])) for k in ('numbers', 'traps', 'claims', 'dodged', 'asked_you')}, answer.get('error', ''))
    for company, files in CHAINS.items():
        if only and company != only:
            continue
        dossier = []
        for k, f in enumerate(files):
            ls, answer, secs = card(f, dossier)
            rows.append({'group': company, 'file': f, 'seconds': secs, 'card': answer, 'dossier': list(dossier),
                         'text': {l['i']: l['text'] for l in ls}})
            print(company, f, 'contradictions', len(answer.get('contradictions', [])), answer.get('error', ''))
            dossier += facts(f, answer, f'call {k + 1}')
            dossier = dossier[-200:]
    os.makedirs(OUT, exist_ok=True)
    json.dump(rows, open(os.path.join(OUT, 'deal.json'), 'w'), ensure_ascii=False, indent=1)
    print('calls to the server:', insieme._calls['n'], '·', insieme.cost())


def replay():
    """Same calls, same dossiers as an earlier run: only the instructions changed, so the
    contradictions can be compared one for one."""
    insieme.check_version('/api/endcard', os.environ.get('INSIEME_EXPECT_ENDCARD', ''))
    only = os.environ.get('DEAL_ONLY', '')
    before = json.load(open(os.path.join(OUT, 'deal.json')))
    rows = []
    for r in before:
        if r['group'] == 'single' or not r.get('dossier') or (only and r['group'] != only):
            continue
        ls, answer, secs = card(r['file'], r['dossier'])
        facts_by_id = {d['id']: d for d in r['dossier']}
        print(f"\n=== {r['group']} · {r['file']} · {secs} s {answer.get('error', '')}")
        for label, c in (('BEFORE', r['card']), ('NOW', answer)):
            for x in c.get('contradictions', []):
                d = facts_by_id.get(x['fact_id'], {})
                print(f"  {label} {x['line']} [{x['kind']}] {x['note']}\n      before ({d.get('date')}): {d.get('fact')}")
        for x in answer.get('traps', []):
            print(f"  NOW TRAP {x['line']} [{x['kind']}] {x['note']}")
        for x in answer.get('numbers', []):
            if 'EBITDA' in x['metric'].upper():
                print(f"  NOW NUM {x['line']} {x['value']} = {x['metric']} | {x['qualifier']}")
        rows.append({**r, 'card': answer, 'seconds': secs})
    json.dump(rows, open(os.path.join(OUT, 'deal-replay.json'), 'w'), ensure_ascii=False, indent=1)
    print('calls to the server:', insieme._calls['n'], '·', insieme.cost())


def show():
    for r in json.load(open(os.path.join(OUT, 'deal.json'))):
        c, t = r['card'], r['text']
        said = lambda i: t.get(str(i), t.get(i, ''))[:240]  # noqa: E731
        print(f"\n=== {r['group']} · {r['file']} · {r['seconds']} s {c.get('error', '')}")
        for n in c.get('numbers', []):
            print(f"  NUM {n['line']} [{n['status']}] {n['value']} = {n['metric']} | qualifier: {n['qualifier']} | topic: {n['topic']} | unsure: {n['unsure']}")
            print(f"      said: {said(n['line'])}")
        for x in c.get('traps', []):
            print(f"  TRAP {x['line']} [{x['kind']}] {x['note']}\n      said: {said(x['line'])}")
        for x in c.get('claims', []):
            print(f"  CLAIM {x['line']} ({x['topic']}) {x['claim']}")
        for x in c.get('dodged', []):
            print(f"  DODGED q{x['line']} a{x['answer_line']}: {x['question']} -> {x['how']}\n      Q: {said(x['line'])}\n      A: {said(x['answer_line'])}")
        for x in c.get('asked_you', []):
            print(f"  ASKED {x['line']}: {x['meaning']}")
        facts_by_id = {d['id']: d for d in r.get('dossier', [])}
        for x in c.get('contradictions', []):
            d = facts_by_id.get(x['fact_id'], {})
            print(f"  CONTRA {x['line']} [{x['kind']}] {x['note']}\n      now: {said(x['line'])}\n      before ({d.get('date')}): {d.get('fact')}")


if __name__ == '__main__':
    what = sys.argv[1] if len(sys.argv) > 1 else ''
    if what == 'corpus':
        corpus()
    elif what == 'show':
        show()
    elif what == 'replay':
        if not os.environ.get('ASAID_TESTER_CODE'):
            sys.exit('ASAID_TESTER_CODE is not set: this needs the server.')
        corpus()
        replay()
    elif what == 'run':
        if not os.environ.get('ASAID_TESTER_CODE'):
            sys.exit('ASAID_TESTER_CODE is not set: this needs the server.')
        corpus()
        run()
        show()
    else:
        sys.exit(__doc__)
