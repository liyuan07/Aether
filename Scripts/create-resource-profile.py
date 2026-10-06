#!/usr/bin/env python3
# Copyright (C) 2026 Li Yuan. SPDX-License-Identifier: GPL-3.0-or-later
"""Create a fresh synthetic workload; never copy user data or overwrite a profile."""
import argparse
import datetime
import hashlib
import json
from pathlib import Path
import uuid


def create_profile(repository: Path, count: int) -> Path:
    if not 0 <= count <= 100_000:
        raise ValueError('clipboard item count outside supported range')
    identifier = str(uuid.uuid4())
    directory = repository / '.build' / 'resource-profiles' / identifier
    directory.mkdir(parents=True, exist_ok=False)
    data = directory / 'Data'
    clipboard = data / 'Clipboard'
    shortcuts = data / 'Shortcuts'
    clipboard.mkdir(parents=True)
    shortcuts.mkdir()
    reference = datetime.datetime(2001, 1, 1, tzinfo=datetime.timezone.utc)
    now = (datetime.datetime.now(datetime.timezone.utc) - reference).total_seconds()
    history = [{'id': str(uuid.UUID(int=index + 1)).upper(), 'type': 'text',
                'timestamp': now - index * .001, 'preview': f'Synthetic clipboard item {index}',
                'isPinned': False, 'stringData': f'Synthetic clipboard item {index} 中文 cafe\u0301'}
               for index in range(count)]
    archive = {'history': history, 'pinnedItems': [], 'groups': []}
    payload = json.dumps(archive, ensure_ascii=False, separators=(',', ':')).encode()
    (clipboard / 'history.json').write_bytes(payload)
    (shortcuts / 'preferences.json').write_text(json.dumps({'schemaVersion': 9,
        'app': {'launchAtLogin': False, 'blockAutomaticABC': False, 'showModifierButtons': False}}))
    manifest = directory / 'profile.json'
    manifest.write_text(json.dumps({'schemaVersion': 1, 'id': identifier, 'clipboardItems': count}, indent=2))
    (directory / 'fixture.json').write_text(json.dumps({'schemaVersion': 1, 'clipboardItems': count,
        'historySHA256': hashlib.sha256(payload).hexdigest()}, indent=2))
    return manifest


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--clipboard-items', type=int, default=0)
    args = parser.parse_args()
    repository = Path(__file__).resolve().parent.parent
    print(create_profile(repository, args.clipboard_items))


if __name__ == '__main__':
    main()
