"""Checks for tools/calibre_bookshelves_export.py against a fake calibredb (no Calibre needed)."""
import importlib.util
import json
import os
from pathlib import Path
import sqlite3
import subprocess
import sys
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
TOOL = ROOT / 'tools' / 'calibre_bookshelves_export.py'
FAKE = ROOT / 'tests' / 'fake_calibredb.py'
spec = importlib.util.spec_from_file_location('exporter', TOOL)
exporter = importlib.util.module_from_spec(spec)
spec.loader.exec_module(exporter)

U1, U2, U3 = ('11111111-1111-4111-8111-111111111111', '22222222-2222-4222-8222-222222222222',
              '33333333-3333-4333-8333-333333333333')
LIB_ID = 'abcdefab-1234-4abc-8abc-abcdefabcdef'


def book(id, uuid, title, authors='Ann Author', tags=(), formats=('epub',), **extra):
    return {'id': id, 'uuid': uuid, 'title': title, 'authors': authors, 'tags': list(tags),
            'formats': [f'/lib/{title}.{f}' for f in formats], 'last_modified': '2026-10-01T00:00:00+00:00',
            'content': {f: f'{title}-{f}-body' for f in formats}, **extra}


class Fixture:
    def __init__(self):
        self.tmp = tempfile.TemporaryDirectory()
        base = Path(self.tmp.name)
        self.library = base / 'library'
        self.library.mkdir()
        with sqlite3.connect(self.library / 'metadata.db') as con:
            con.execute('CREATE TABLE library_id (id INTEGER PRIMARY KEY, uuid TEXT)')
            con.execute('INSERT INTO library_id VALUES (1, ?)', (LIB_ID,))
        self.fixture = base / 'books.json'
        self.dest = base / 'dest'

    def set_books(self, books):
        self.fixture.write_text(json.dumps(books))

    def run(self, *extra, fail=None, trailing=None):
        env = {**os.environ, 'FAKE_CALIBRE_FIXTURE': str(self.fixture)}
        if fail:
            env['FAKE_CALIBRE_FAIL'] = fail
        if trailing:
            env['FAKE_CALIBRE_TRAILING'] = trailing
        return subprocess.run([sys.executable, str(TOOL), '--library', str(self.library), '--dest', str(self.dest),
                               '--calibredb', str(FAKE), *extra], capture_output=True, text=True, env=env)

    def catalogue(self):
        return json.loads((self.dest / exporter.CATALOGUE).read_text())


class PureHelpers(unittest.TestCase):
    def test_stem_is_bounded_and_safe(self):
        s = exporter.stem('A/B: "C"?' + 'x' * 300, 'Au & Th', U1)
        self.assertNotIn('/', s)
        self.assertTrue(s.endswith(' [11111111]'))
        self.assertLessEqual(len(s.encode()), 192)

    def test_reserved_and_invalid_shelf_names(self):
        for bad in ('Favorites', 'to be read', ' lead', 'trail ', 'x' * 161):
            with self.assertRaises(exporter.ExportError):
                exporter.shelf_names([bad], 't')
        self.assertEqual(exporter.shelf_names(['b', 'a', 'a'], 't'), ['a', 'b'])

    def test_case_collision_rejected(self):
        with self.assertRaises(exporter.ExportError):
            exporter.build_catalogue(LIB_ID, [
                {'uuid': U1, 'shelves': ['Maths']}, {'uuid': U2, 'shelves': ['maths']}])

    def test_formats_accept_paths_and_content_server_names(self):
        books = [{'id': 1, 'uuid': U1, 'title': 'A', 'formats': ['/lib/A.EPUB']},
                 {'id': 2, 'uuid': U2, 'title': 'B', 'formats': ['PDF', 'MOBI']},
                 {'id': 3, 'uuid': U3, 'title': 'C', 'formats': ['MOBI']}]
        selected, skipped = exporter.plan(books, ['epub', 'pdf'], 'tags', None, None, {})
        self.assertEqual([(e['title'], e['format']) for e in selected], [('A', 'epub'), ('B', 'pdf')])
        self.assertEqual(skipped, ['C'])

    def test_field_keys(self):
        self.assertEqual(exporter.field_key('tags'), 'tags')
        self.assertEqual(exporter.field_key('#shelves'), '*shelves')
        with self.assertRaises(exporter.ExportError):
            exporter.field_key('#bad name')


class EndToEnd(unittest.TestCase):
    def setUp(self):
        self.f = Fixture()
        self.addCleanup(self.f.tmp.cleanup)

    def test_export_writes_books_state_and_valid_catalogue(self):
        self.f.set_books([book(1, U1, 'Alpha', tags=['Maths', 'Physics']),
                          book(2, U2, 'Beta', formats=('pdf',)),
                          book(3, U3, 'Gamma', formats=('mobi',))])
        r = self.f.run()
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertIn('1 skipped', r.stdout)
        cat = self.f.catalogue()
        self.assertEqual(cat['schema'], 1)
        self.assertEqual(cat['library_id'], LIB_ID)
        self.assertEqual(len(cat['revision']), 64)
        self.assertEqual([b['file'] for b in cat['books']],
                         ['Alpha - Ann Author [11111111].epub', 'Beta - Ann Author [22222222].pdf'])
        self.assertEqual(cat['books'][0]['shelves'], ['Maths', 'Physics'])
        self.assertEqual(cat['books'][0]['favourite'], 'unmanaged')
        self.assertEqual(cat['books'][0]['status'], 'unmanaged')
        self.assertEqual((self.f.dest / cat['books'][0]['file']).read_text(), 'Alpha-epub-body')
        self.assertEqual(cat['books'][0]['bytes'], len('Alpha-epub-body'))
        self.assertFalse(list(self.f.dest.glob(exporter.TMP_PREFIX + '*')))

    def test_rename_keeps_frozen_filename_and_unchanged_books_are_not_reexported(self):
        self.f.set_books([book(1, U1, 'Alpha')])
        self.assertEqual(self.f.run().returncode, 0)
        self.f.set_books([{**book(1, U1, 'Alpha Renamed'), 'content': {'epub': 'SHOULD-NOT-BE-WRITTEN'}}])
        r = self.f.run()
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertIn('0 to export', r.stdout)
        cat = self.f.catalogue()
        self.assertEqual(cat['books'][0]['file'], 'Alpha - Ann Author [11111111].epub')
        self.assertEqual(cat['books'][0]['title'], 'Alpha Renamed')
        self.assertEqual((self.f.dest / cat['books'][0]['file']).read_text(), 'Alpha-epub-body')

    def test_modified_book_is_reexported(self):
        self.f.set_books([book(1, U1, 'Alpha')])
        self.f.run()
        self.f.set_books([{**book(1, U1, 'Alpha'), 'last_modified': '2026-10-02T00:00:00+00:00',
                           'content': {'epub': 'new-body'}}])
        r = self.f.run()
        self.assertIn('1 to export', r.stdout)
        self.assertEqual((self.f.dest / 'Alpha - Ann Author [11111111].epub').read_text(), 'new-body')

    def test_removed_book_is_reported_then_pruned_only_on_request(self):
        self.f.set_books([book(1, U1, 'Alpha'), book(2, U2, 'Beta')])
        self.f.run()
        unrelated = self.f.dest / 'my-own-file.epub'
        unrelated.write_text('mine')
        self.f.set_books([book(1, U1, 'Alpha')])
        r = self.f.run()
        self.assertIn('1 previously exported files no longer selected', r.stdout)
        self.assertTrue((self.f.dest / 'Beta - Ann Author [22222222].epub').exists())
        self.assertEqual(len(self.f.catalogue()['books']), 1)
        r = self.f.run('--prune')
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertFalse((self.f.dest / 'Beta - Ann Author [22222222].epub').exists())
        self.assertTrue(unrelated.exists())

    def test_dry_run_writes_nothing(self):
        self.f.set_books([book(1, U1, 'Alpha')])
        r = self.f.run('--dry-run')
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertIn('would export', r.stdout)
        self.assertFalse(self.f.dest.exists())

    def test_custom_columns(self):
        self.f.set_books([{**book(1, U1, 'Alpha'), '*shelves': ['Maths / Analysis'], '*favourite': True, '*reading_status': 'Reading'}])
        r = self.f.run('--shelves', '#shelves', '--favourite', '#favourite', '--status', '#reading_status')
        self.assertEqual(r.returncode, 0, r.stderr)
        b = self.f.catalogue()['books'][0]
        self.assertEqual((b['shelves'], b['favourite'], b['status']), (['Maths / Analysis'], 'yes', 'Reading'))

    def test_bad_status_and_reserved_tag_fail_before_writing(self):
        self.f.set_books([{**book(1, U1, 'Alpha'), '*reading_status': 'Done'}])
        r = self.f.run('--status', '#reading_status')
        self.assertEqual(r.returncode, 1)
        self.assertIn('Reading status', r.stderr)
        self.f.set_books([book(1, U1, 'Alpha', tags=['Favorites'])])
        r = self.f.run()
        self.assertEqual(r.returncode, 1)
        self.assertIn('reserved', r.stderr)
        self.assertFalse(self.f.dest.exists())

    def test_calibredb_failure_is_reported_and_destination_untouched(self):
        self.f.set_books([book(1, U1, 'Alpha')])
        self.f.run()
        before = sorted(p.name for p in self.f.dest.iterdir())
        r = self.f.run(fail='Another calibre program such as calibre-server or the main calibre program is running.')
        self.assertEqual(r.returncode, 1)
        self.assertIn('main calibre program is running', r.stderr)
        self.assertEqual(before, sorted(p.name for p in self.f.dest.iterdir()))

    def test_trailing_calibredb_diagnostics_are_ignored(self):
        # calibredb appends e.g. "Using proxies: {...}" to stdout when it talks to a Content server.
        self.f.set_books([book(1, U1, 'Alpha')])
        r = self.f.run(trailing="Using proxies: {'no': '127.0.0.1,localhost,::1'}")
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertEqual(len(self.f.catalogue()['books']), 1)

    def test_malformed_list_output_is_an_error(self):
        self.assertEqual(exporter.parse_list('  [{"id": 1}]  trailing'), [{'id': 1}])
        for bad in ('no json here', '[1, 2', '{"a": 1}'):
            with self.assertRaises(exporter.ExportError):
                exporter.parse_list(bad)

    def test_different_library_refused(self):
        self.f.set_books([book(1, U1, 'Alpha')])
        self.f.run()
        with sqlite3.connect(self.f.library / 'metadata.db') as con:
            con.execute('UPDATE library_id SET uuid = ?', ('99999999-9999-4999-8999-999999999999',))
        r = self.f.run()
        self.assertEqual(r.returncode, 1)
        self.assertIn('different Calibre library', r.stderr)


if __name__ == '__main__':
    unittest.main()
