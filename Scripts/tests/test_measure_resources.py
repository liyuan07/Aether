# Copyright (C) 2026 Li Yuan. SPDX-License-Identifier: GPL-3.0-or-later
import importlib.util
import pathlib
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

if __name__ == '__main__':
    unittest.main()
