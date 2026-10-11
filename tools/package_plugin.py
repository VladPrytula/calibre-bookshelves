#!/usr/bin/env python3
"""Build a deterministic release ZIP of the plugin from source and print its SHA-256."""
import hashlib
from pathlib import Path
import re
import zipfile

ROOT = Path(__file__).resolve().parents[1]


def main():
    source = ROOT / 'calibre-bookshelf.koplugin'
    version = re.search(r'version\s*=\s*"([0-9.]+)"', (source / '_meta.lua').read_text())[1]
    dest = ROOT / 'dist'
    dest.mkdir(exist_ok=True)
    archive = dest / ('calibre-bookshelf-' + version + '.zip')
    with zipfile.ZipFile(archive, 'w', compression=zipfile.ZIP_DEFLATED) as output:
        for path in sorted(source.glob('*.lua')):
            entry = zipfile.ZipInfo(source.name + '/' + path.name, (1980, 1, 1, 0, 0, 0))
            entry.compress_type = zipfile.ZIP_DEFLATED
            entry.external_attr = 0o100644 << 16
            output.writestr(entry, path.read_bytes())
    digest = hashlib.sha256(archive.read_bytes()).hexdigest()
    archive.with_suffix('.zip.sha256').write_text(digest + '  ' + archive.name + '\n')
    print(archive)
    print('SHA-256:', digest)


if __name__ == '__main__':
    main()
