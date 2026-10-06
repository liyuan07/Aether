# Copyright (C) 2026 Li Yuan. SPDX-License-Identifier: GPL-3.0-or-later
import hashlib
import importlib.util
import json
from pathlib import Path
import tempfile
import unittest

spec = importlib.util.spec_from_file_location('resource_profile_creator', Path(__file__).resolve().parents[1] / 'create-resource-profile.py')
creator = importlib.util.module_from_spec(spec)
spec.loader.exec_module(creator)


class ResourceProfileCreationTests(unittest.TestCase):
    def test_fresh_profiles_and_fixture_integrity(self):
        with tempfile.TemporaryDirectory() as temporary:
            repository = Path(temporary)
            first = creator.create_profile(repository, 3)
            original = first.read_bytes()
            second = creator.create_profile(repository, 3)
            self.assertNotEqual(first, second)
            self.assertEqual(first.read_bytes(), original)
            manifest = json.loads(original)
            payload = (first.parent / 'Data' / 'Clipboard' / 'history.json').read_bytes()
            history = json.loads(payload)['history']
            self.assertEqual(len(history), manifest['clipboardItems'])
            self.assertEqual(len({item['id'] for item in history}), 3)
            self.assertTrue(all(item['stringData'].startswith('Synthetic') for item in history))
            fixture = json.loads((first.parent / 'fixture.json').read_text())
            self.assertEqual(fixture['historySHA256'], hashlib.sha256(payload).hexdigest())
            self.assertEqual(first.parent.name, manifest['id'])

    def test_invalid_size_does_not_create_directories(self):
        with tempfile.TemporaryDirectory() as temporary:
            repository = Path(temporary)
            for count in [-1, 100_001]:
                with self.assertRaises(ValueError):
                    creator.create_profile(repository, count)
            self.assertEqual(list(repository.iterdir()), [])


if __name__ == '__main__':
    unittest.main()
