#!/usr/bin/env python3
# Copyright (C) 2026 Li Yuan. SPDX-License-Identifier: GPL-3.0-or-later
"""Verify shipped notices against every locked registry dependency in Cargo metadata."""
import json
import pathlib
import sys

notices = pathlib.Path(sys.argv[1])
metadata = json.load(sys.stdin)
count = 0
for package in metadata['packages']:
    if package['source'] is None:
        continue
    root = pathlib.Path(package['manifest_path']).parent
    licenses = [file for file in root.iterdir() if file.is_file()
                and (file.name.startswith('LICENSE') or file.name.startswith('COPYRIGHT'))]
    if not licenses:
        raise SystemExit('No license files found for ' + package['name'])
    for source in licenses:
        shipped = notices / ('Rust-' + package['name'] + '-' + package['version'] + '-' + source.name)
        if not shipped.is_file() or shipped.read_bytes() != source.read_bytes():
            raise SystemExit('Missing or stale Rust notice: ' + shipped.name)
    count += 1
print('RUST_DEPENDENCY_LICENSES_OK crates=' + str(count))
