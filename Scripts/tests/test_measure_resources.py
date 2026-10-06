# Copyright (C) 2026 Li Yuan. SPDX-License-Identifier: GPL-3.0-or-later
import importlib.util
import pathlib
import hashlib
import json
import tempfile
import unittest
path = pathlib.Path(__file__).resolve().parents[1] / 'measure-installed-resources.py'
spec = importlib.util.spec_from_file_location('measure', path)
measure = importlib.util.module_from_spec(spec)
spec.loader.exec_module(measure)

class SummaryTests(unittest.TestCase):
    def sample(self, time_ns, user, system, memory):
        return dict(monotonic_ns=time_ns,user_ticks=user,system_ticks=system,timebase_numer=125,timebase_denom=3,
                    resident_bytes=memory,footprint_bytes=2*memory,idle_wakeups=5,interrupt_wakeups=7,disk_read_bytes=0,disk_write_bytes=0)

    def test_interval_uses_mach_timebase_and_counts_both_cpu_modes(self):
        first = self.sample(100_000_000_000, 900_000_000, 900_000_000, 1048576)
        last = self.sample(101_000_000_000, 906_000_000, 906_000_000, 3*1048576)
        result = measure.summarize([first,last])
        self.assertEqual(result['cpu_percent_one_core'],50)
        self.assertEqual(result['resident_median_mib'],2)
        self.assertEqual(result['footprint_median_mib'],4)
        self.assertEqual(result['footprint_peak_mib'],6)

    def test_parallel_cpu_can_exceed_one_hundred_percent(self):
        result = measure.summarize([self.sample(0,0,0,0),self.sample(1_000_000_000,48_000_000,0,0)])
        self.assertEqual(result['cpu_percent_one_core'],200)

    def test_invalid_interval_or_counter_reset_is_rejected(self):
        with self.assertRaises(RuntimeError):
            measure.summarize([self.sample(0,1,0,0),self.sample(0,2,0,0)])
        with self.assertRaises(RuntimeError):
            measure.summarize([self.sample(0,2,0,0),self.sample(1,1,0,0)])

class ProfileEvidenceTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.root = pathlib.Path(self.temporary.name)
        self.identifier = 'a18930c1-12db-400f-9cfe-86c6e44c7a54'
        self.directory = self.root / '.build/resource-profiles' / self.identifier
        history = self.directory / 'Data/Clipboard/history.json'
        history.parent.mkdir(parents=True)
        history.write_bytes(b'{"history":[],"pinnedItems":[],"groups":[]}')
        self.hash = hashlib.sha256(history.read_bytes()).hexdigest()
        self.manifest = self.directory / 'profile.json'
        self.write('profile.json', dict(schemaVersion=1,id=self.identifier,clipboardItems=0))
        self.write('runtime.json', dict(schemaVersion=1,id=self.identifier,clipboardItems=0,pid=42))
        self.write('fixture.json', dict(schemaVersion=1,clipboardItems=0,historySHA256=self.hash))

    def write(self, name, value):
        (self.directory / name).write_text(json.dumps(value))

    def evidence(self):
        return measure.profile_evidence(self.manifest,42,self.root)

    def test_fixture_hash_and_live_pid_are_recorded(self):
        result = self.evidence()
        self.assertEqual(result['history_sha256'],self.hash)
        self.assertEqual(result['clipboard_items'],0)
        self.assertEqual(result['id'],self.identifier)

    def test_stale_runtime_or_different_workload_is_rejected(self):
        for values in [dict(pid=43),dict(id='different'),dict(clipboardItems=1),dict(schemaVersion=2)]:
            self.write('runtime.json',dict(schemaVersion=1,id=self.identifier,clipboardItems=0,pid=42) | values)
            with self.assertRaises(RuntimeError):
                self.evidence()

    def test_modified_archive_is_rejected(self):
        (self.directory / 'Data/Clipboard/history.json').write_bytes(b'{}')
        with self.assertRaises(RuntimeError):
            self.evidence()

    def test_linked_archive_is_rejected_before_read(self):
        archive = self.directory / 'Data/Clipboard/history.json'
        archive.unlink()
        archive.symlink_to(self.root / 'missing')
        with self.assertRaises(RuntimeError):
            self.evidence()

    def test_non_profile_path_is_rejected_before_read(self):
        with self.assertRaises(RuntimeError):
            measure.profile_evidence(self.root / 'history.json',42,self.root)

if __name__ == '__main__':
    unittest.main()
