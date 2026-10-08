"""Free test of the end-of-session score (PIANO, INSIEME test 1): in each bench call, without being told
where the hand-picked moments are, which sentences does a text-and-timing score pick?"""
import json, os, re, sys, statistics, collections
sys.path.insert(0, '/home/user/afterhear-app/bench')
import comprehend
from wordfreq import zipf_frequency

CORPUS = '/tmp/claude-0/-home-user-afterhear/94b41b4c-0da4-5e55-a99e-77484e310bc2/scratchpad/p1/sd'
AL = '/home/user/afterhear-app/bench/out/comprehend/aligned'
cases = json.load(open('/home/user/afterhear-app/bench/comprehension/cases.json'))

# Written from general knowledge of how people soften things at work, not from the bench's targets.
LITERAL = ["right-size", "right size", "rightsiz", "rationaliz", "streamlin", "headcount", "restructur", "optimiz",
           "challenging", "softness", "soft patch", "plays out", "stay tuned", "more to come", "not ideal",
           "with respect", "quite good", "might be worth", "no rush", "cautiously", "too early to", "we'll see",
           "difficult decision", "tough decision", "take action", "structural action", "let go", "reduce the size",
           "normaliz", "rebalanc", "prudent", "lumpy", "noise", "one-off", "non-recurring", "not going to comment",
           "i wouldn't", "i'd rather not", "to be fair", "to be honest", "frankly", "at the end of the day",
           "moving parts", "on the table", "in the pipeline", "low-hanging", "a bit of a", "not where we want",
           "disappoint", "pressure on", "headwind", "tailwind", "pull forward", "push out", "pushed out",
           "wait and see", "give or take", "ballpark", "back half", "front half", "price discipline", "under review",
           "exploring options", "strategic alternatives", "not in a position", "remains to be seen", "we're comfortable",
           "in line with", "flattish", "modest", "temporary", "transitory", "mixed", "unchanged", "reiterat"]
FILLER = {"uh", "um", "uh,", "um,", "er", "erm"}
STOP = set("the a an and or but of to in on at for with by from as is are was were be been it its this that these those we our you your they their i my he she his her not no so if then than there here what which who whom how why when where do does did have has had will would can could should may might must just also very really about into over under up down out more most some any all each other such only own same too s t don't can't won't".split())


def words(t):
    return re.findall(r"[A-Za-z][A-Za-z'\-]*", t)


def is_question(t):
    t = t.strip().lower()
    if t.endswith('?'):
        return True
    f = (t.split() or [''])[0].strip(',')
    return f in {"what", "why", "how", "when", "where", "who", "do", "does", "did", "can", "could", "would", "will",
                 "are", "is", "have", "has", "shall", "should"} and len(t.split()) <= 20


def signals(text, rate_z):
    ws = words(text)
    low = text.lower()
    s = {}
    content = [w for w in ws if w.lower() not in STOP and len(w) > 2]
    # Rare words: jargon you may not know (lowercase, not names).
    rare = [w for w in content if not w[0].isupper() and zipf_frequency(w.lower().strip("'-"), 'en') < 3.2]
    s['rare'] = min(len(rare), 3)
    # Acronyms and initialisms.
    s['acronym'] = min(len([w for w in re.findall(r"\b[A-Z][A-Z&]{1,5}s?\b", text) if w not in {"I", "OK", "US", "CEO", "CFO", "Q"}]), 2)
    # Names of things: capitalised, not first word, uncommon (companies, products, places you may not know).
    names = [w for i, w in enumerate(ws) if i > 0 and w[0].isupper() and not w.isupper() and zipf_frequency(w.lower(), 'en') < 3.0]
    s['name'] = min(len(set(names)), 2)
    s['literal'] = sum(1 for p in LITERAL if p in low)
    s['negation'] = 1 if re.search(r"\b(not|never|n't|no longer|neither|nor)\b|n't\b", low) else 0
    fill = sum(1 for w in text.lower().split() if w.strip(',.') in {"uh", "um", "er"})
    s['fillers'] = fill / max(1, len(ws))
    s['fast'] = max(0.0, rate_z)
    s['question'] = 1 if is_question(text) else 0
    s['length'] = len(ws)
    return s


W = dict(rare=0.9, acronym=0.8, name=0.7, literal=1.0, negation=0.2, fillers=2.0, fast=0.35, question=0.3)


def score(s, w=W):
    if s['length'] < 6:
        return -1  # "thank you", "next question": never a moment
    return sum(w[k] * s[k] for k in w)


def load():
    every = comprehend.sentences(CORPUS)
    calls = collections.defaultdict(list)
    for gi, (f, sp, ws) in enumerate(every):
        calls[f].append((gi, sp, ' '.join(ws)))
    out = {}
    for f in sorted(set(c['file'] for c in cases)):
        p = os.path.join(AL, f + '.json')
        if not os.path.exists(p):
            continue
        al = json.load(open(p))['sentences']
        rows = []
        for gi, sp, text in calls[f]:
            a = al.get(str(gi))
            if not a:
                continue
            dur = max(0.5, a['end'] - a['start'])
            rows.append(dict(i=gi, sp=sp, text=text, start=a['start'], end=a['end'], rate=len(text.split()) / dur))
        if len(rows) < 0.5 * len(calls[f]):
            continue  # only calls aligned end to end
        rates = [r['rate'] for r in rows if r['end'] - r['start'] > 2]
        mu, sd = statistics.mean(rates), statistics.pstdev(rates) or 1
        for r in rows:
            r['sig'] = signals(r['text'], (r['rate'] - mu) / sd)
        out[f] = rows
    return out


def pick(rows, k=4, gap=60, w=W, listener=None):
    scored = []
    for r in rows:
        sc = score(r['sig'], w)
        if listener and re.search(r"\b%s\b" % re.escape(listener), r['text']) and r['sig']['question']:
            sc += 5  # a question put to you by name: always
        scored.append((sc, r))
    scored.sort(key=lambda x: -x[0])
    chosen = []
    for sc, r in scored:
        if all(abs(r['start'] - c['start']) >= gap for c in chosen):
            chosen.append(r)
        if len(chosen) == k:
            break
    return chosen


def hit(r, c):
    return r['start'] < c['end'] and c['start'] < r['end']


def evaluate(data, files, k=4, w=W, verbose=False):
    hard = [c for c in cases if c['kind'] in ('word', 'who', 'meant') and c['file'] in files]
    slots = hits = cand_hit = 0
    for f in files:
        rows = data[f]
        cs = [c for c in hard if c['file'] == f]
        if not cs:
            continue
        chosen = pick(rows, k, w=w)
        h = sum(1 for r in chosen if any(hit(r, c) for c in cs))
        slots += min(k, len(cs))
        hits += min(h, len(cs))
        cands = pick(rows, 20, gap=0, w=w)
        cand_hit += sum(1 for c in cs if any(hit(r, c) for r in cands))
        if verbose:
            print(f, 'cases', len(cs), 'hits', h, [r['text'][:70] for r in chosen if any(hit(r, c) for c in cs)])
    # Questions to you: with the listener's name, is it among the 4?
    asked = [c for c in cases if c['kind'] == 'asked' and c['file'] in files]
    a_hit = 0
    for c in asked:
        chosen = pick(data[c['file']], k, w=w, listener=c['name'])
        a_hit += any(hit(r, c) for r in chosen)
    # False alarm control: named but not asked → must not be picked as a question to you.
    return dict(hard_slots=slots, hard_hits=hits, rate=hits / max(1, slots), cand20=cand_hit / max(1, len(hard)),
                n_hard=len(hard), asked=a_hit, n_asked=len(asked))


if __name__ == '__main__':
    data = load()
    files = sorted(data)
    print('calls', len(files), 'sentences', sum(len(v) for v in data.values()))
    print('ALL', evaluate(data, files, verbose='-v' in sys.argv))
    a, b = files[0::2], files[1::2]
    print('half A', evaluate(data, a))
    print('half B', evaluate(data, b))
