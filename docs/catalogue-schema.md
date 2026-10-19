# Catalogue schema

The plugin reads one file, `.calibre-bookshelves.json`, from the root of the synced book folder. This document is the contract: anything that produces a file matching it can drive the plugin, and the plugin rejects anything that does not. Schema 1 is frozen; incompatible changes will bump `schema` and the plugin will refuse unknown values rather than guess.

A complete example is in [sample-catalogue.json](sample-catalogue.json). `tests/test_sample_catalogue.lua` checks that it passes the plugin's validator.

## Top level

| Field | Type | Rule |
|---|---|---|
| `schema` | integer | Must be `1`. |
| `library_id` | string | Lowercase UUID of the Calibre library (the `library_id` table in `metadata.db`). The plugin keeps a ledger per device keyed by this value; a catalogue from a different library is refused until the ledger is removed. |
| `revision` | string | 64 hex characters. SHA-256 of the canonical JSON of the catalogue without this field (`sort_keys`, separators `,`/`:`, non-ASCII unescaped). Only inequality matters to the plugin; it is used to detect a changed catalogue. |
| `books` | array | At most 10 000 entries, each a book object below. |
| `navigation` | object | Optional two-level shelf hierarchy for browsing (see below). Readers that do not understand it ignore it; the plugin falls back to a flat list of shelves when it is absent. |

## Book object

| Field | Type | Rule |
|---|---|---|
| `uuid` | string | Calibre book UUID, unique in the catalogue. |
| `file` | string | Filename relative to the folder root. ≤ 240 bytes, no `/` or `\`, must not start with `.`, must end in `.epub` or `.pdf` (case-insensitive). Unique in the catalogue, case-insensitively. |
| `bytes` | integer | Exact size of the file. The plugin treats a book as not yet transferred until a file of this size exists, so partial Syncthing transfers never enter a collection. |
| `shelves` | array of strings | ≤ 100 shelf names. Each ≤ 160 bytes, no leading/trailing whitespace, no control characters. `Favorites` and `To be read` (any case) are reserved for KOReader/ZenOS and refused. Across the catalogue, two names that differ only in case are an error. |
| `favourite` | string | `unmanaged`, `yes` or `no`. `unmanaged` means the catalogue says nothing; the device's own favourite flag is left alone. |
| `status` | string | `unmanaged`, `To Read`, `Reading`, `On Hold` or `Finished`. `unmanaged` leaves the device's reading status alone. |
| `title`, `authors`, `format` | string | Optional display text (≤ 2048 bytes each) for the category browser. Without them the filename is shown. |
| `book_uuid` | string | Optional duplicate of `uuid` kept for older readers. |

Shelf names may contain ` / `; in flat mode it is just part of the name.

## `navigation` (optional)

```json
{"version": 1, "nodes": [
  {"id": "mathematics", "name": "Mathematics", "path": "Mathematics"},
  {"id": "analysis", "name": "Analysis & PDE", "parent": "mathematics", "path": "Mathematics / Analysis & PDE"}
]}
```

Two levels: a node either has no `parent` (a subject) or names a subject as its `parent`, and a child's `path` must be `"<parent name> / <name>"`. `version` sets the budget:

| `version` | Nodes | Subjects | Sub-shelves | Read by |
|---|---|---|---|---|
| `1` | ≤ 14 | ≤ 6 | ≤ 8 | plugin 1.2 and later |
| `2` | ≤ 22 | ≤ 6 | ≤ 16 | plugin 1.5 and later |

Write the lowest version that fits your shelves if older plugins must keep browsing; plugins before 1.5 refuse version 2 in *Browse categories* (collection import is unaffected). From 1.5 on, an integer `version` above 2 is not an error: the browser lists the saved shelf names and says that a newer plugin is needed. A malformed `version` (not a positive integer) is still refused.

A book's `shelves` entries are matched to `path`. Books whose shelves match no node are listed under *Unassigned*; shelves that match no node are listed as legacy shelves. The reference exporter in this repository does not emit `navigation`; it is produced by a separate tool with a bounded taxonomy. If you emit it yourself, the constraints above are enforced by the plugin.

## What the plugin does with it

- Creates one KOReader collection per shelf name, tagged with `calibre_bookshelf_owner = library_id` in the collection settings. It only ever adds to, removes from, or deletes collections carrying that owner tag; your own collections are not touched.
- Removes a book from an owned collection when the catalogue no longer lists it there, and deletes an owned collection when it becomes empty.
- Applies `favourite` by adding/removing the file in KOReader's `favorites` collection, and `status` by writing the `summary.status` field of the book's sidecar (`Reading → reading`, `On Hold → abandoned`, `Finished → complete`). `To Read` is delegated to ZenOS's *To Be Read* index when that adapter is loaded, and refused otherwise. Every write is verified by reading it back; a backup of the touched files is taken first.
- Never writes reading positions, highlights or annotations. Those stay in the sidecar / KOSync.

## Companion state file

The reference exporter writes `.calibre-bookshelves-export.json` next to the catalogue. It is not read by the plugin; it only lets the exporter keep filenames stable and skip unchanged books. It is safe to sync it along with everything else.
