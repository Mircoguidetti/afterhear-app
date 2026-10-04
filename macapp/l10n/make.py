#!/usr/bin/env python3
"""The Mac app in seven languages (owner, 03/10: the same languages as the landing).

Finds every word the app shows, checks each one has its six translations in strings.py, and
writes Afterhear/<language>.lproj/Localizable.strings and InfoPlist.strings.

  python3 macapp/l10n/make.py          check and write
  python3 macapp/l10n/make.py --todo   list the keys still without a translation

A word is shown when it is the first argument of a SwiftUI view that translates by itself
(Text("…"), Button("…"), Toggle("…"), …) or is wrapped in String(localized: "…"). A value put
into the words (\\(x)) becomes %@ for text and %lld for whole numbers: name the whole-number
values in INTS below. A Text("…") with a value is translated only when strings.py has its key.
"""
import os
import re
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
APP = os.path.join(HERE, '..', 'Afterhear')
sys.path.insert(0, HERE)
from strings import T, PLIST  # noqa: E402

LANGS = ['it', 'es', 'fr', 'de', 'ru', 'pt']

VIEWS = r'(?:\b(?:Text|Button|Toggle|Picker|Section|Label|LabeledContent|DisclosureGroup|TextField|SecureField|Menu|Link|Stepper|ProgressView|Window)|\.(?:help|navigationTitle|alert|confirmationDialog))'
WRAPPED = r'(?:String\(localized:\s*|LocalizedStringResource = |IntentDescription\()'
START = re.compile(r'(?:' + VIEWS + r'\(\s*|' + WRAPPED + r')"')

# Values that are whole numbers (%lld); everything else is text (%@).
INTS = {
    'clipDays', 'count', 'n', 'total', 'done', 'minutes', 'days', 'waiting', 'tapsToday', 'labelled',
    'knownCount', 'againCount', 'right', 'today', 'lastWeek', 'week', 'score', 'before', 'taps', 'understood',
    'maybeNot', 'heard', 'percent', 'back', 'tapped', 'quizCount', 'ago',
}


def literal_at(src, i):
    """The Swift string literal starting at the quote src[i], with its interpolations."""
    assert src[i] == '"'
    j, out, parts = i + 1, '', []
    while True:
        c = src[j]
        if c == '\\' and src[j + 1] == '(':
            depth, k = 1, j + 2
            while depth:
                if src[k] == '(':
                    depth += 1
                elif src[k] == ')':
                    depth -= 1
                elif src[k] == '"':  # a literal inside the value: skip it
                    k = src.index('"', k + 1)
                k += 1
            expr = src[j + 2:k - 1]
            parts.append(expr)
            out += '\0'
            j = k
            continue
        if c == '\\':
            out += src[j:j + 2]
            j += 2
            continue
        if c == '"':
            return out, parts, j + 1
        out += c
        j += 1


def spec(expr):
    name = expr.strip()
    last = re.split(r'[.(]', name.replace('?', ''))
    if name in INTS or last[-1] in INTS or name.endswith('.count') or name.startswith('Int('):
        return '%lld'
    return '%@'


def keys():
    found = {}
    for f in sorted(os.listdir(APP)):
        if not f.endswith('.swift'):
            continue
        src = open(os.path.join(APP, f), encoding='utf-8').read()
        for m in START.finditer(src):
            q = m.end() - 1
            if src[q - 3:q] == '"""':
                continue
            text, parts, _ = literal_at(src, q)
            if not re.search(r'[A-Za-z]', text):
                continue
            key = text.replace('%', '%%') if parts else text
            for p in parts:
                key = key.replace('\0', spec(p), 1)
            key = key.replace('\\"', '"').replace('\\n', '\n')
            found.setdefault(key, f)
    return found


def esc(s):
    return s.replace('\\', '\\\\').replace('"', '\\"').replace('\n', '\\n')


def specs(s):
    return re.findall(r'%(?:\d\$)?(?:lld|@|lf|d)', s)


def norm(sp):
    return [re.sub(r'\d\$', '', x) for x in sp]


def main():
    found = keys()
    missing = [k for k in found if k not in T]
    if '--todo' in sys.argv:
        for k in missing:
            print(f'{found[k]}: {k!r}')
        print(len(missing), 'missing of', len(found))
        return
    bad = []
    for k, v in T.items():
        if len(v) != len(LANGS):
            bad.append(f'{k!r}: {len(v)} translations')
            continue
        for lang, t in zip(LANGS, v):
            if sorted(norm(specs(t))) != sorted(specs(k)):
                bad.append(f'{lang} {k!r}: values {specs(t)} vs {specs(k)}')
    if missing or bad:
        for k in missing:
            print('missing:', found[k], repr(k))
        for b in bad:
            print('wrong:', b)
        sys.exit(1)
    for i, lang in enumerate(LANGS + ['en']):
        folder = os.path.join(APP, f'{lang}.lproj')
        os.makedirs(folder, exist_ok=True)
        if lang != 'en':
            with open(os.path.join(folder, 'Localizable.strings'), 'w', encoding='utf-8') as out:
                out.write('/* Written by macapp/l10n/make.py from strings.py: edit there. */\n\n')
                for k in sorted(found):
                    out.write(f'"{esc(k)}" = "{esc(T[k][i])}";\n')
        with open(os.path.join(folder, 'InfoPlist.strings'), 'w', encoding='utf-8') as out:
            out.write('/* Written by macapp/l10n/make.py from strings.py: edit there. */\n\n')
            for k, v in PLIST.items():
                out.write(f'"{k}" = "{esc(v[i] if lang != "en" else v[-1])}";\n')
    unused = [k for k in T if k not in found]
    print(f'{len(found)} words, {len(LANGS)} languages written', f'({len(unused)} unused in strings.py)' if unused else '')


if __name__ == '__main__':
    main()
