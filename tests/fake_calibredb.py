#!/usr/bin/env python3
"""Minimal calibredb stand-in for tests: serves `list --for-machine` and `export` from a JSON fixture.

The fixture path comes from $FAKE_CALIBRE_FIXTURE. It is a list of book objects with the
fields the exporter asks for, plus "content": {"epub": "...", "pdf": "..."} for export bodies.
"""
import json
import os
from pathlib import Path
import sys


def main():
    args = sys.argv[1:]
    assert args[:1] == ['--with-library'], args
    args = args[2:]
    books = json.loads(Path(os.environ['FAKE_CALIBRE_FIXTURE']).read_text())
    if os.environ.get('FAKE_CALIBRE_FAIL'):
        print(os.environ['FAKE_CALIBRE_FAIL'], file=sys.stderr)
        return 2
    if args[0] == 'list':
        fields = args[args.index('--fields') + 1].split(',')
        print(json.dumps([{f: b.get(f) for f in fields if f in b} for b in books], indent=2))
        if os.environ.get('FAKE_CALIBRE_TRAILING'):
            print(os.environ['FAKE_CALIBRE_TRAILING'])
        return 0
    if args[0] == 'export':
        ids = {int(i) for i in args[1].split(',')}
        to_dir = Path(args[args.index('--to-dir') + 1])
        fmt = args[args.index('--formats') + 1]
        for b in books:
            if b['id'] in ids and fmt in b.get('content', {}):
                (to_dir / f"calibre-{b['uuid']}.{fmt}").write_text(b['content'][fmt])
        return 0
    raise SystemExit('unsupported: ' + ' '.join(args))


if __name__ == '__main__':
    sys.exit(main())
