# Calibre Bookshelves for KOReader

This is a KOReader plugin that shows the shelves you keep in Calibre on your e-reader, without needing a network connection while you read. It comes with a small Python script that exports a Calibre library into a folder of EPUB and PDF files together with a catalogue file describing which book belongs on which shelf. Once that folder is on the device, the plugin reads the catalogue and creates matching KOReader collections, adds a shelf browser (as a plain list or with covers), and can optionally set the favourite flag and reading status from Calibre columns as well.

Getting the folder onto the device is left to whatever you already use: a USB cable, Calibre's *Send to device*, Syncthing, or anything else that copies files. I use Syncthing myself, but the plugin does not depend on it.

Calibre remains the place where books and shelves are managed. The plugin only maintains the collections it created itself and leaves your other collections alone. It does not modify reading positions, highlights or annotations, and it never deletes book files.

I have been using this on a Kindle Scribe and a Paperwhite running KOReader 2026.07 with ZenOS 4.0.1, exporting from Calibre 9.15 on macOS, both directly from the library folder and through a Content server with authentication. The plugin only uses KOReader's own APIs, so it should work on other devices KOReader supports, but I have not tried them. Reports are welcome.

## How it fits together

```text
Calibre library ──calibre_bookshelves_export.py──▶ folder/
                                                     ├── Title - Author [uuid8].epub
                                                     ├── …
                                                     └── .calibre-bookshelves.json
                                                              │  (your transport: USB, Syncthing, …)
                                                              ▼
                                                   KOReader + calibre-bookshelf.koplugin
                                                     collections, category browser,
                                                     favourites, reading status
```

## Install the plugin

1. Download `calibre-bookshelf-<version>.zip` from the latest release and check it against the published SHA-256.
2. Unzip it. Copy the `calibre-bookshelf.koplugin` folder into KOReader's `plugins` directory on the device (on a Kindle: `koreader/plugins/`).
3. Restart KOReader. The plugin appears in the main menu under **More tools → Calibre Bookshelves**.

The plugin looks for `.calibre-bookshelves.json` in KOReader's home folder, then in `/mnt/us/Books`, `/mnt/base-us/KindleLibrary` and `/mnt/us/KindleLibrary`. If your books live elsewhere, use **Set synced book folder** in the plugin menu.

## Export from Calibre

Requires Python 3.9+ (standard library only) and Calibre's `calibredb`. The exporter only reads the library; it never writes to Calibre.

```sh
python3 tools/calibre_bookshelves_export.py \
  --library "/path/to/Calibre Library" \
  --dest "/path/to/synced/folder"
```

By default every Calibre **tag** becomes a shelf. For a dedicated column instead:

```sh
python3 tools/calibre_bookshelves_export.py --library … --dest … \
  --shelves '#shelves' --favourite '#favourite' --status '#reading_status'
```

- `--shelves` is `tags` or a tags-like custom column. Names `Favorites` and `To be read` are reserved by KOReader/ZenOS and refused.
- `--favourite` is an optional Yes/No column. Unset cells leave the device's favourite flag alone.
- `--status` is an optional text column holding `To Read`, `Reading`, `On Hold` or `Finished`. Unset cells leave the device's status alone.
- `--formats epub,pdf` is the preference order; one file per book. Books with neither format are listed and skipped.
- `--dry-run` shows what would happen. `--prune` deletes files this tool exported earlier for books that are no longer selected; without it they are only reported. Files the tool did not create are never deleted.
- `--library` also accepts a Content server URL (`http://host:8080`, plus `--username`/`--password` when the server has authentication enabled) if you prefer not to close Calibre. In that mode the catalogue's `library_id` is derived from the URL rather than read from `metadata.db`, so keep using the same URL for the same destination folder.

Close the Calibre GUI before exporting from a library folder; `calibredb` refuses to open a library the GUI has open, and the exporter reports that refusal verbatim.

Filenames are `Title - Authors [first 8 of uuid].ext`, frozen per book in `.calibre-bookshelves-export.json` on first export. Renaming a book in Calibre later changes the title shown on the device but not the filename, so KOReader keeps its reading progress. Changing a book's content re-exports it under the same name. If you delete that state file, the next export treats every book as new and may rename files.

If you sync with Syncthing, add `.calibre-bookshelves-tmp-*` to the folder's ignore patterns so half-written files are never picked up, and keep `*.sdr` out of the folder's sync scope so devices do not exchange reading sidecars.

## Use it on the device

Open the plugin menu while in the file browser (not inside a book):

- **Import now** reconciles collections with the catalogue. With **Automatic import while in Library** on (default), this also happens about once a minute whenever you are in the file browser and the catalogue has changed. A book is only added once a file of the exact size in the catalogue exists, so partial transfers never appear.
- **Browse categories** opens the shelf browser: a tile or compact list of shelves, and inside each shelf a list or cover grid of books, with EPUB/PDF choice when both exist.
- **Status / last result** shows what the last import did or why it stopped.
- **Reapply explicit Calibre favourites/status** forces those flags again even if the catalogue did not change (for example after you changed them by hand on the device).

Every change to a collection, favourite or status is backed up under KOReader's settings folder before it is written and read back afterwards; an import that cannot verify its own write stops and tells you.

## What it does not do

No wireless transfer, no reading-position sync (use KOSync), no annotation handling, no sending from the device back to Calibre, no automatic shelf creation in Calibre. The exporter does not choose which books to send: everything with an EPUB or PDF goes. If you want a selection, give the selection a tag in Calibre and build a virtual library, or run the exporter against a Content server with that virtual library.

## Development

```sh
python3 -m unittest discover -s tests -p 'test_*.py'   # exporter, with a fake calibredb
sh tools/test_lua.sh                                   # plugin, Lua 5.1 in a disposable container
python3 tools/package_plugin.py                        # deterministic release ZIP + SHA-256 in dist/
```

The Lua tests exercise the plugin against KOReader's real `readcollection.lua` (vendored, unmodified, see `tests/upstream/SOURCE.md`) with controlled doubles for widgets, sidecars and ZenOS. They are not a rendering test; check a real device after changes to the browser. The catalogue format is specified in [docs/catalogue-schema.md](docs/catalogue-schema.md).

## Licence

AGPL-3.0-or-later, the same as KOReader. See [LICENSE](LICENSE). `tests/upstream/readcollection.lua` is KOReader's, under the same licence.
