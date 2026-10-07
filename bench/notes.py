"""Puts a bench's result files on the run as notes (GitHub annotations), which anyone can read on a
public repository without signing in: the logs and the artifacts need an account.

    python3 bench/notes.py FILE [FILE ...]
"""
import json
import os
import sys

CHUNK = 30000   # an annotation holds up to 64 KB
MOST = 9        # GitHub keeps 10 notes per step


def escape(text):
    return text.replace('%', '%25').replace('\r', '%0D').replace('\n', '%0A')


def main(paths):
    text = ''
    for path in paths:
        if not os.path.exists(path):
            continue
        try:
            body = json.dumps(json.load(open(path)), ensure_ascii=False, separators=(',', ':'))
        except Exception:
            body = open(path).read()
        text += f'== {os.path.basename(path)}\n{body}\n'
    parts = [text[i:i + CHUNK] for i in range(0, len(text), CHUNK)][:MOST] or ['(no results)']
    for k, part in enumerate(parts):
        print(f'::notice title=results {k + 1}/{len(parts)}::{escape(part)}')
    return 0


if __name__ == '__main__':
    sys.exit(main(sys.argv[1:]))
