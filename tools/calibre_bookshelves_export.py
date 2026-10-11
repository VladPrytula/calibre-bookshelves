#!/usr/bin/env python3
"""Export books and a Calibre Bookshelves catalogue from a Calibre library.

Reads the library through ``calibredb`` only; never writes to Calibre. Writes one
file per book plus ``.calibre-bookshelves.json`` into the destination folder, which
you then sync or copy to the device by any means (USB, Syncthing, ...).

Filenames are frozen per Calibre UUID in ``.calibre-bookshelves-export.json`` so that
later title edits do not rename files on the device (KOReader keeps reading progress
next to the file). Python 3.9+, standard library only.
"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import sqlite3
import subprocess
import sys
import tempfile
import unicodedata
import uuid as uuidlib

CATALOGUE = '.calibre-bookshelves.json'
STATE = '.calibre-bookshelves-export.json'
TMP_PREFIX = '.calibre-bookshelves-tmp-'
STATUSES = ('unmanaged', 'To Read', 'Reading', 'On Hold', 'Finished')
RESERVED = ('favorites', 'to be read')
MAX_BOOKS = 10000
UUID_RE = re.compile(r'^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$')
CANDIDATES = (
    '/Applications/calibre.app/Contents/MacOS/calibredb',
    '/usr/bin/calibredb', '/usr/local/bin/calibredb', '/opt/calibre/calibredb',
    r'C:\Program Files\Calibre2\calibredb.exe',
)


class ExportError(Exception):
    pass


# ---------- pure helpers (unit-tested) ----------

def stem(title, authors, uuid):
    text = unicodedata.normalize('NFC', f'{title} - {authors}')
    text = re.sub(r'[<>:"/\\|?*\x00-\x1f]', ' ', text)
    text = re.sub(r'\s+', ' ', text).strip(' .')
    while len(text.encode('utf-8')) > 180:
        text = text[:-1]
    return text.rstrip(' .') + f' [{uuid[:8]}]'


def field_key(spec):
    """Calibre column spec ('tags' or '#name') -> key used by `calibredb list --for-machine`."""
    if spec.startswith('#'):
        if not re.fullmatch(r'#[a-z0-9_]+', spec):
            raise ExportError(f'Invalid custom column name: {spec}')
        return '*' + spec[1:]
    if not re.fullmatch(r'[a-z_]+', spec):
        raise ExportError(f'Invalid column name: {spec}')
    return spec


def shelf_names(value, title):
    if value is None or value == '':
        return []
    if isinstance(value, str):
        value = [value]
    if not isinstance(value, list):
        raise ExportError(f'Shelf column must be a tags-like or text column ({title}).')
    names = []
    for name in value:
        if not isinstance(name, str):
            raise ExportError(f'Shelf column must contain text ({title}).')
        if (not name or name != name.strip() or len(name.encode('utf-8')) > 160
                or any(ord(c) < 32 for c in name) or name.casefold() in RESERVED):
            raise ExportError(f'Invalid or reserved shelf name {name!r} ({title}). '
                              '"Favorites" and "To be read" are owned by KOReader/ZenOS.')
        if name not in names:
            names.append(name)
    return sorted(names)


def display(value):
    text = re.sub(r'[\x00-\x1f\x7f]', ' ', str(value or '')).strip()
    return text.encode('utf-8')[:2048].decode('utf-8', errors='ignore')


def build_catalogue(library_id, entries):
    books = sorted(entries, key=lambda b: b['uuid'])
    if len(books) > MAX_BOOKS:
        raise ExportError(f'The plugin accepts at most {MAX_BOOKS} books.')
    seen = {}
    for b in books:
        for name in b['shelves']:
            other = seen.setdefault(name.casefold(), name)
            if other != name:
                raise ExportError(f'Shelf names differ only in case: {other!r} and {name!r}.')
    result = {'schema': 1, 'library_id': library_id, 'books': books}
    payload = json.dumps(result, ensure_ascii=False, sort_keys=True, separators=(',', ':')).encode()
    result['revision'] = hashlib.sha256(payload).hexdigest()
    return result


def plan(books, formats, shelves_key, favourite_key, status_key, state):
    """Decide the filename and format for every book; returns (selected, skipped)."""
    selected, skipped, names = [], [], {}
    for book in books:
        title = book.get('title') or book['uuid']
        if not UUID_RE.match(book.get('uuid') or ''):
            raise ExportError(f'Book without a valid UUID: {title}')
        # Local libraries list format file paths; a Content server lists bare format names.
        available = {(Path(p).suffix.lstrip('.') if '.' in p else p).lower() for p in book.get('formats') or []}
        fmt = next((f for f in formats if f in available), None)
        if not fmt:
            skipped.append(title)
            continue
        shelves = shelf_names(book.get(shelves_key), title)
        favourite = 'unmanaged'
        if favourite_key:
            raw = book.get(favourite_key)
            if raw not in (None, True, False):
                raise ExportError(f'Favourite column must be a Yes/No column ({title}).')
            favourite = 'unmanaged' if raw is None else ('yes' if raw else 'no')
        status = 'unmanaged'
        if status_key:
            status = book.get(status_key) or 'unmanaged'
            if status not in STATUSES:
                raise ExportError(f'Reading status must be one of {", ".join(STATUSES[1:])} ({title}).')
        prev = state.get(book['uuid']) or {}
        base = prev.get('stem') or stem(title, book.get('authors') or '', book['uuid'])
        file = f'{base}.{fmt}'
        if file.casefold() in names:
            raise ExportError(f'Filename collision: {file}')
        names[file.casefold()] = True
        selected.append({'id': book['id'], 'uuid': book['uuid'], 'title': display(title),
                         'authors': display(book.get('authors')), 'format': fmt, 'file': file, 'stem': base,
                         'shelves': shelves, 'favourite': favourite, 'status': status,
                         'last_modified': book.get('last_modified'), 'previous': prev})
    return selected, skipped


def parse_list(output):
    """`calibredb list --for-machine` may append diagnostics such as 'Using proxies: ...' to stdout
    when it talks to a Content server; decode the leading JSON array and ignore the rest."""
    start = output.find('[')
    if start < 0:
        raise ExportError('calibredb list returned no JSON:\n' + output.strip()[:500])
    try:
        value, _ = json.JSONDecoder().raw_decode(output, start)
    except json.JSONDecodeError as exc:
        raise ExportError(f'calibredb list returned malformed JSON ({exc}).')
    if not isinstance(value, list):
        raise ExportError('calibredb list did not return a book array.')
    return value


def needs_export(entry, dest):
    prev = entry['previous']
    path = dest / entry['file']
    return (not prev or prev.get('file') != entry['file'] or prev.get('last_modified') != entry['last_modified']
            or not path.is_file() or path.stat().st_size != prev.get('bytes'))


# ---------- calibre access ----------

def find_calibredb(explicit):
    for candidate in ([explicit] if explicit else []) + [os.environ.get('CALIBREDB'), shutil.which('calibredb')] + list(CANDIDATES):
        if candidate and Path(candidate).is_file():
            return candidate
    raise ExportError('calibredb not found. Pass --calibredb or set CALIBREDB.')


class Calibre:
    def __init__(self, exe, library, username=None, password=None):
        self.base = [exe, '--with-library', library]
        if username:
            self.base += ['--username', username]
        if password:
            self.base += ['--password', password]

    def run(self, *args, timeout=600):
        try:
            done = subprocess.run(self.base + list(args), capture_output=True, text=True, timeout=timeout)
        except subprocess.TimeoutExpired:
            raise ExportError(f'calibredb {args[0]} timed out after {timeout}s.')
        if done.returncode:
            raise ExportError(f'calibredb {args[0]} failed:\n{done.stderr.strip() or done.stdout.strip()}')
        return done.stdout


def library_id(library):
    if re.match(r'^https?://', library):
        return str(uuidlib.uuid5(uuidlib.NAMESPACE_URL, library.rstrip('/')))
    db = Path(library) / 'metadata.db'
    if not db.is_file():
        raise ExportError(f'Not a Calibre library (metadata.db missing): {library}')
    with sqlite3.connect(db.as_uri() + '?mode=ro', uri=True) as con:
        return con.execute('SELECT uuid FROM library_id').fetchone()[0]


def write_json(path, value):
    encoded = json.dumps(value, ensure_ascii=False, indent=2, sort_keys=True) + '\n'
    if path.exists() and path.read_text(encoding='utf-8') == encoded:
        return
    pending = path.parent / (TMP_PREFIX + path.name)
    pending.write_text(encoded, encoding='utf-8')
    os.replace(pending, path)


# ---------- main ----------

def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__.split('\n\n')[0])
    parser.add_argument('--library', required=True, help='Calibre library folder, or a Content server URL')
    parser.add_argument('--dest', required=True, type=Path, help='Folder that will hold books and the catalogue')
    parser.add_argument('--calibredb', help='Path to calibredb (default: $CALIBREDB, PATH, common install locations)')
    parser.add_argument('--username'); parser.add_argument('--password', help='Content server credentials; see calibredb --help for <stdin>/<f:file> forms')
    parser.add_argument('--shelves', default='tags', help="Column holding shelf names: 'tags' or a custom column like '#shelves' (default: tags)")
    parser.add_argument('--favourite', help="Optional Yes/No custom column, e.g. '#favourite'")
    parser.add_argument('--status', help="Optional text/enum custom column with To Read / Reading / On Hold / Finished, e.g. '#reading_status'")
    parser.add_argument('--formats', default='epub,pdf', help='Preference order; one file per book (default: epub,pdf)')
    parser.add_argument('--search', help="Calibre search expression limiting which books are exported, e.g. 'tags:kindle' or '#device:true'")
    parser.add_argument('--prune', action='store_true', help='Delete files this tool exported earlier for books that are no longer selected')
    parser.add_argument('--dry-run', action='store_true', help='Report the plan without writing anything')
    args = parser.parse_args(argv)

    formats = [f.strip().lower() for f in args.formats.split(',') if f.strip()]
    if not formats or any(f not in ('epub', 'pdf') for f in formats):
        raise ExportError('--formats accepts only epub and pdf (the plugin opens nothing else).')
    shelves_key = field_key(args.shelves)
    favourite_key = field_key(args.favourite) if args.favourite else None
    status_key = field_key(args.status) if args.status else None

    dest = args.dest
    if dest.exists() and not dest.is_dir():
        raise ExportError(f'Destination is not a folder: {dest}')
    state_path = dest / STATE
    state = json.loads(state_path.read_text(encoding='utf-8')) if state_path.is_file() else {'books': {}}
    if state.get('library_id') and state['library_id'] != library_id(args.library):
        raise ExportError('Destination was exported from a different Calibre library. Use a new folder or delete '
                          f'{STATE} to start over (the device will then re-import every shelf).')
    lib_id = library_id(args.library)

    cal = Calibre(find_calibredb(args.calibredb), args.library, args.username, args.password)
    fields = ['id', 'uuid', 'title', 'authors', 'formats', 'last_modified', shelves_key] + [k for k in (favourite_key, status_key) if k]
    list_args = ['list', '--for-machine', '--fields', ','.join(fields)] + (['--search', args.search] if args.search else [])
    books = parse_list(cal.run(*list_args))
    if not books:
        raise ExportError('The library returned no books' + (' for that search' if args.search else '') + '; nothing was changed.')
    selected, skipped = plan(books, formats, shelves_key, favourite_key, status_key, state['books'])
    pending = [e for e in selected if needs_export(e, dest)]
    keep = {e['file'] for e in selected}
    stale = sorted({f for f in [b.get('file') for b in state['books'].values()] + list(state.get('stale') or [])
                    if f and f not in keep and (dest / f).is_file()})

    print(f'{len(selected)} books selected, {len(pending)} to export, {len(skipped)} skipped (no EPUB/PDF), {len(stale)} previously exported files no longer selected.')
    for title in skipped:
        print('  skipped:', title)
    for name in stale:
        print('  stale:', name, '(deleted with --prune)' if not args.prune else '(deleting)')
    if args.dry_run:
        for e in pending:
            print('  would export:', e['file'])
        return 0

    dest.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix='calibre-bookshelves-') as tmp:
        stage = Path(tmp)
        for fmt in formats:
            ids = ','.join(str(e['id']) for e in pending if e['format'] == fmt)
            if ids:
                cal.run('export', ids, '--to-dir', str(stage), '--formats', fmt, '--template', 'calibre-{uuid}',
                        '--dont-write-opf', '--dont-save-cover', '--dont-save-extra-files', '--dont-asciiize')
        for e in pending:
            src = stage / f"calibre-{e['uuid']}.{e['format']}"
            if not src.is_file() or not src.stat().st_size:
                raise ExportError(f"Calibre did not export {e['file']}; nothing in {dest} was changed.")
            e['bytes'] = src.stat().st_size
        # Everything exported and checked; now move files into place one by one.
        for e in pending:
            src = stage / f"calibre-{e['uuid']}.{e['format']}"
            target = dest / e['file']
            pending_path = dest / (TMP_PREFIX + e['file'])
            shutil.move(str(src), str(pending_path))
            os.replace(pending_path, target)
            old = e['previous'].get('file')
            if old and old != e['file'] and (dest / old).is_file():
                (dest / old).unlink()
            print('  exported:', e['file'])

    entries, next_state = [], {}
    for e in selected:
        size = e.get('bytes') or (dest / e['file']).stat().st_size
        entries.append({'uuid': e['uuid'], 'book_uuid': e['uuid'], 'file': e['file'], 'bytes': size, 'format': e['format'],
                        'title': e['title'], 'authors': e['authors'], 'shelves': e['shelves'],
                        'favourite': e['favourite'], 'status': e['status']})
        next_state[e['uuid']] = {'stem': e['stem'], 'file': e['file'], 'bytes': size, 'last_modified': e['last_modified']}
    if args.prune:
        for name in stale:
            (dest / name).unlink()
            print('  deleted:', name)
    write_json(dest / CATALOGUE, build_catalogue(lib_id, entries))
    write_json(state_path, {'schema': 1, 'library_id': lib_id, 'books': next_state, 'stale': [] if args.prune else stale})
    print(f'Catalogue written: {dest / CATALOGUE}')
    return 0


if __name__ == '__main__':
    try:
        sys.exit(main())
    except ExportError as exc:
        print('Error:', exc, file=sys.stderr)
        sys.exit(1)
