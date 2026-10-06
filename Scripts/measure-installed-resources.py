#!/usr/bin/env python3
# Copyright (C) 2026 Li Yuan. SPDX-License-Identifier: GPL-3.0-or-later
"""Read aggregate counters only; never launch Aether or inspect user content."""
import argparse
import datetime
import hashlib
import json
import math
import pathlib
import platform
import statistics
import subprocess
import time

ROOT = pathlib.Path(__file__).resolve().parent.parent
INSTALLED = pathlib.Path('/Applications/Aether.app/Contents/MacOS/Aether')

def command(*args):
    return subprocess.check_output(args, cwd=ROOT, text=True).strip()

def sole_pid():
    pids = command('pgrep', '-x', 'Aether').splitlines()
    if len(pids) != 1:
        raise RuntimeError('Exactly one Aether process is required.')
    return int(pids[0])

def summarize(samples):
    first, last = samples[0], samples[-1]
    elapsed = last['monotonic_ns'] - first['monotonic_ns']
    ticks = last['user_ticks'] + last['system_ticks'] - first['user_ticks'] - first['system_ticks']
    if elapsed <= 0 or ticks < 0:
        raise RuntimeError('Invalid interval counters.')
    return {
        'duration_seconds': elapsed / 1e9,
        'cpu_percent_one_core': 100 * ticks * first['timebase_numer'] / first['timebase_denom'] / elapsed,
        'resident_median_mib': statistics.median(s['resident_bytes'] for s in samples) / 1048576,
        'footprint_median_mib': statistics.median(s['footprint_bytes'] for s in samples) / 1048576,
        'footprint_peak_mib': max(s['footprint_bytes'] for s in samples) / 1048576,
        'idle_wakeups_delta': last['idle_wakeups'] - first['idle_wakeups'],
        'interrupt_wakeups_delta': last['interrupt_wakeups'] - first['interrupt_wakeups'],
        'disk_read_bytes_delta': last['disk_read_bytes'] - first['disk_read_bytes'],
        'disk_write_bytes_delta': last['disk_write_bytes'] - first['disk_write_bytes'],
    }

def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--scenario', required=True, choices=['settings-closed','general-visible','ports-visible','general-after-ports'])
    parser.add_argument('--duration', type=float, default=30)
    parser.add_argument('--interval', type=float, default=1)
    parser.add_argument('--output', type=pathlib.Path, required=True)
    args = parser.parse_args()
    if not all(math.isfinite(v) for v in [args.duration,args.interval]) or not 1 <= args.duration <= 3600 or not .1 <= args.interval <= args.duration:
        parser.error('Use duration 1...3600 and interval 0.1...duration seconds.')
    if args.output.exists():
        parser.error('Output already exists; preserve prior measurements.')
    helper = ROOT / '.build/benchmarks/sample-installed-resources'
    helper.parent.mkdir(parents=True, exist_ok=True)
    subprocess.run(['xcrun','clang','-std=c11','-Wall','-Wextra','-Werror','-O2',str(ROOT/'Scripts/sample-installed-resources.c'),'-o',str(helper)],check=True)
    subprocess.run(['codesign','--verify','--deep','--strict','/Applications/Aether.app'],check=True)
    binary_hash = hashlib.sha256(INSTALLED.read_bytes()).hexdigest()
    loaded_uuids = {line.split()[1].lower() for line in command('xcrun','dwarfdump','--uuid',str(INSTALLED)).splitlines() if line.startswith('UUID: ')}
    if not loaded_uuids:
        raise RuntimeError('Cannot verify installed Mach-O UUID.')
    pid = sole_pid()
    samples = []
    start = None
    deadline = None
    while True:
        before = time.monotonic_ns()
        sample = json.loads(command(str(helper),str(pid)))
        after = time.monotonic_ns()
        if sample['executable_uuid'].lower() not in loaded_uuids:
            raise RuntimeError('Running executable does not match the installed Mach-O UUID.')
        sample['monotonic_ns'] = (before + after) // 2
        sample['read_duration_ns'] = after - before
        if start is None:
            start = sample['monotonic_ns'] / 1e9
            deadline = start + args.duration
        if sole_pid() != pid or (samples and any(sample[k] != samples[0][k] for k in ['start_ticks','timebase_numer','timebase_denom'])):
            raise RuntimeError('Process changed during measurement.')
        samples.append(sample)
        now = time.monotonic()
        if now >= deadline:
            break
        time.sleep(max(0,min(start + len(samples) * args.interval,deadline) - now))
    if hashlib.sha256(INSTALLED.read_bytes()).hexdigest() != binary_hash:
        raise RuntimeError('Installed binary changed during measurement.')
    result = {'schema_version':1,'scenario_operator_label':args.scenario,'captured_utc':datetime.datetime.now(datetime.timezone.utc).isoformat(),
              'git_revision':command('git','rev-parse','HEAD'),'worktree_dirty':bool(command('git','status','--porcelain')),
              'installed_sha256':binary_hash,'machine':platform.machine(),'macos':command('sw_vers','-productVersion'),
              'time_unit':'Mach ticks converted using recorded timebase','summary':summarize(samples),'samples':samples}
    args.output.parent.mkdir(parents=True,exist_ok=True)
    with args.output.open('x') as stream:
        json.dump(result,stream,ensure_ascii=False,indent=2)
    print(json.dumps(result['summary'],ensure_ascii=False))

if __name__ == '__main__':
    main()
