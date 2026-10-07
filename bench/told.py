"""What they told you to do (block COSA 7, 07/10): does /api/told return only what was asked of you?

Written cases, the way the Mac sends them: the others' lines as text, names and numbers already taken out,
the listener as [tu]. Each case says what must come back (a request for the listener) and what must
not (the group's tasks, someone else's, chit-chat). Calls Gemini through the real server: by hand only,
with the owner's go, never more than TOLD_MAX_CALLS calls.

    python3 bench/told.py            # runs the cases, writes bench/out/told.json and the summary
"""
import json
import os
import re
import sys
import time
import urllib.error
import urllib.request

HERE = os.path.dirname(os.path.abspath(__file__))
OUT = os.path.join(HERE, 'out')
SERVER = os.environ.get('LEXALIE_SERVER', 'https://asaid-nine.vercel.app')
MAX_CALLS = int(os.environ.get('TOLD_MAX_CALLS', '20'))

# want: words that must appear in some item (quote or meaning), one list per expected item;
# never: words that must not be in any quote; empty want = nothing should come back.
CASES = [
    {'id': 'doctor', 'source': 'in_person', 'heard': 'en-GB', 'lines': [
        "Right, so it's a chest infection, nothing serious.",
        "[tu], take one of these twice a day after meals, for seven days.",
        "And if the cough isn't better by next week, come back and see me.",
        "Any questions? No? Lovely."],
     'want': [['twice'], ['come back', 'week']], 'never': []},
    {'id': 'landlord', 'source': 'in_person', 'heard': 'en-GB', 'lines': [
        "The flat's yours from the first.",
        "I'll need the deposit by Friday, otherwise I can't hold it.",
        "Oh and the boiler's a bit temperamental, just bleed the radiators in winter."],
     'want': [['deposit', 'friday']], 'never': []},
    {'id': 'call-deck', 'source': 'call', 'heard': 'en-US', 'lines': [
        "Okay, so the launch moves to March.",
        "[PERSON_1] will book the room for the offsite.",
        "[tu], could you send me the deck by Thursday?",
        "Great, thanks everyone."],
     'want': [['deck']], 'never': ['book the room']},
    {'id': 'chitchat', 'source': 'call', 'heard': 'en-US', 'lines': [
        "How was the weekend?", "Oh lovely, we went to the coast.", "The weather was amazing, honestly.",
        "Anyway, we're still waiting on finance."],
     'want': [], 'never': []},
    {'id': 'group-only', 'source': 'call', 'heard': 'en-GB', 'lines': [
        "Let's all have a look at the doc before Monday.", "[PERSON_2], you own the budget section.",
        "[PERSON_3] is on holiday next week."],
     'want': [], 'never': ['budget section', 'holiday']},
    {'id': 'pharmacy', 'source': 'in_person', 'heard': 'en-GB', 'lines': [
        "That's eight sixty, please.", "You'll need to show your health card next time, love.",
        "Keep them in the fridge once opened."],
     'want': [['health card'], ['fridge']], 'never': []},
    {'id': 'doctor-es', 'source': 'in_person', 'heard': 'es-ES', 'lines': [
        "Bueno, no es nada grave.",
        "Tómese una pastilla cada ocho horas, y no conduzca mientras las tome.",
        "Pida cita para dentro de dos semanas en recepción."],
     'want': [['ocho'], ['conduzca'], ['cita']], 'never': []},
    {'id': 'question', 'source': 'call', 'heard': 'en-US', 'lines': [
        "So we can do the review Tuesday or Wednesday.", "[tu], what works better for you?",
        "No rush, just let me know today."],
     'want': [['tuesday', 'wednesday', 'works']], 'never': []},
    {'id': 'someone-else', 'source': 'call', 'heard': 'en-US', 'lines': [
        "[PERSON_1], please call the supplier about the delay.", "And [PERSON_2], update the tracker.",
        "That's it from me."],
     'want': [], 'never': ['supplier', 'tracker']},
    {'id': 'bank', 'source': 'in_person', 'heard': 'en-GB', 'lines': [
        "Lovely, so just sign here, and here.", "And bring in a copy of your ID tomorrow, then we can open the account.",
        "We close at four, by the way."],
     'want': [['sign'], ['id', 'tomorrow']], 'never': []},
    {'id': 'buried', 'source': 'call', 'heard': 'en-GB', 'lines': [
        "The numbers for Q3 look solid, revenue up eight percent.", "Churn is flat, which is fine for now.",
        "We're hiring two engineers in Lisbon.", "Oh, [tu], before I forget, can you get me a ballpark for March by Friday?",
        "Marketing wants to rethink the funnel.", "Right, that's everything."],
     'want': [['ballpark', 'march']], 'never': ['hiring', 'funnel']},
]


def post(body, calls):
    if calls['n'] >= MAX_CALLS:
        return {'error': f'cap: {MAX_CALLS} calls reached, not sent'}
    calls['n'] += 1
    req = urllib.request.Request(SERVER + '/api/told', method='POST', data=json.dumps(body).encode(),
                                 headers={'content-type': 'application/json', 'x-lexalie-code': os.environ.get('ASAID_TESTER_CODE', '')})
    try:
        return json.loads(urllib.request.urlopen(req, timeout=90).read())
    except urllib.error.HTTPError as e:
        return {'error': f'HTTP {e.code}: {e.read()[:200]!r}'}
    except Exception as e:
        return {'error': str(e)[:200]}


def words(text):
    return re.findall(r"\w+", text.lower())


def found(needles, items):
    blob = ' '.join((i.get('quote', '') + ' ' + i.get('meaning', '')).lower() for i in items)
    return any(n in blob for n in needles)


def check(case, answer):
    items = answer.get('items') or []
    source = ' '.join(case['lines']).lower()
    got = {'id': case['id'], 'items': items, 'error': answer.get('error')}
    if answer.get('error'):
        got['ok'] = False
        return got
    want = case['want']
    got['found'] = sum(found(w, items) for w in want)
    got['expected'] = len(want)
    got['extra'] = max(0, len(items) - max(len(want), 1)) if want else len(items)
    got['forbidden'] = [n for n in case['never'] if any(n in i.get('quote', '').lower() for i in items)]
    # The quote must be the speaker's words, not a rewrite: most of its words are in the lines.
    got['quotes_real'] = all(sum(w in source for w in words(i.get('quote', ''))) >= 0.8 * max(1, len(words(i.get('quote', ''))))
                             for i in items)
    got['short'] = all(len(i.get('meaning', '').split()) <= 18 for i in items)
    got['ok'] = (got['found'] == len(want) and got['extra'] == 0 and not got['forbidden'] and got['quotes_real'] and got['short'])
    return got


def main():
    calls = {'n': 0}
    rows = []
    for case in CASES:
        answer = post({'lines': case['lines'], 'source': case['source'], 'heard': case['heard'], 'native': 'it', 'level': 'B2'}, calls)
        rows.append(check(case, answer))
        time.sleep(0.5)
    os.makedirs(OUT, exist_ok=True)
    json.dump(rows, open(os.path.join(OUT, 'told.json'), 'w'), indent=1, ensure_ascii=False)
    ok = sum(r['ok'] for r in rows)
    lines = ['## What they told you to do (/api/told)', '',
             f'{len(rows)} written cases (doctor, landlord, pharmacy, bank, calls; some with nothing for you), {calls["n"]} calls to the server.',
             f'**Right: {ok} of {len(rows)}** (every request for you found, nothing extra, nobody else\'s task, real quotes, short meanings).', '',
             '| Case | Right | Found | Extra | Someone else\'s | Items |', '|---|---|---|---|---|---|']
    for r in rows:
        shown = ' / '.join(f"“{i.get('quote', '')}” → {i.get('meaning', '')}{' (unsure)' if i.get('unsure') else ''}" for i in r['items']) or (r.get('error') or '—')
        lines.append(f"| {r['id']} | {'yes' if r['ok'] else 'no'} | {r.get('found', 0)}/{r.get('expected', 0)} | {r.get('extra', 0)} | "
                     f"{', '.join(r.get('forbidden') or []) or '—'} | {shown.replace('|', '/')} |")
    text = '\n'.join(lines)
    print(text)
    summary = os.environ.get('GITHUB_STEP_SUMMARY')
    if summary:
        open(summary, 'a').write(text + '\n')
    return 0


if __name__ == '__main__':
    sys.exit(main())
