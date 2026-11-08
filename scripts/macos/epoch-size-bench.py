#!/usr/bin/env python3
"""Compare epoch revisions with the same ops harness, compiler and object sizes."""
import argparse
import json
import os
from pathlib import Path
import platform
import shutil
import statistics
import subprocess


def run(*args, cwd=None, env=None):
    return subprocess.check_output(args, cwd=cwd, env=env, text=True)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--baseline', required=True, help='immutable baseline commit')
    parser.add_argument('--zig', default='zig')
    parser.add_argument('--output', type=Path, required=True)
    parser.add_argument('--sizes', default='40,256,264,512,1024,4096,4104')
    parser.add_argument('--live', type=int, default=4096)
    parser.add_argument('--n', type=int, default=100000)
    parser.add_argument('--rounds', type=int, default=5)
    args = parser.parse_args()
    root = Path(__file__).resolve().parents[2]
    zig = shutil.which(args.zig)
    if zig is None:
        parser.error('Zig executable not found')
    if min(args.n, args.rounds, args.live) < 1 or args.live & (args.live - 1):
        parser.error('positive N/rounds and a power-of-two live count are required')
    sizes = [int(s) for s in args.sizes.split(',')]
    if min(sizes) < 40:
        parser.error('object sizes must be at least 40 bytes')
    sha = run('git', 'rev-parse', args.baseline + '^{commit}', cwd=root).strip()
    out = args.output.resolve()
    # Never reuse old snapshots or mix measurements with a previous experiment.
    out.mkdir(parents=True, exist_ok=False)
    snapshots = {}
    for variant in ('baseline', 'candidate'):
        snapshot = out / variant
        snapshots[variant] = snapshot
        sources = run('git', 'ls-tree', '-r', '--name-only', sha, 'src', cwd=root).splitlines()
        for name in sources:
            dest = snapshot / name
            dest.parent.mkdir(parents=True, exist_ok=True)
            if variant == 'baseline':
                dest.write_text(run('git', 'show', sha + ':' + name, cwd=root))
            else:
                shutil.copy2(root / name, dest)
        # Both revisions use exactly the same benchmark and build settings.
        for name in ('build.zig', 'build.zig.zon', 'bench/native/ops.zig', 'tests/native/suite.zig'):
            dest = snapshot / name
            dest.parent.mkdir(parents=True, exist_ok=True)
            shutil.copy2(root / name, dest)
    env = {k: v for k, v in os.environ.items() if not k.startswith('KX_GC_')}
    result = dict(baseline=sha, candidate_head=run('git', 'rev-parse', 'HEAD', cwd=root).strip(),
                  zig=run(zig, 'version').strip(), platform=platform.platform(),
                  n=args.n, live=args.live, rounds=args.rounds, samples=[], summary=[])
    (out / 'candidate.patch').write_text(run('git', 'diff', '--', 'src', 'build.zig', 'bench/native/ops.zig', cwd=root))
    for size in sizes:
        bins = {}
        for variant, snapshot in snapshots.items():
            subprocess.run([zig, 'build', '--release=fast', '-Dgc=epoch',
                            f'-Dbench-object-size={size}', f'-Dbench-live={args.live}'],
                           cwd=snapshot, env=env, check=True)
            binary = snapshot / f'gc-ops-{size}'
            shutil.copy2(snapshot / 'zig-out/bin/gc-ops-epoch', binary)
            bins[variant] = binary
            run(str(binary), str(args.n), env=env)  # unrecorded warm-up
        measurements = {v: [] for v in bins}
        for rep in range(args.rounds):
            order = ('baseline', 'candidate') if rep % 2 == 0 else ('candidate', 'baseline')
            for variant in order:
                text = run(str(bins[variant]), str(args.n), env=env)
                values = {}
                for line in text.splitlines():
                    gc, metric, value = line.split()
                    if gc != 'epoch':
                        raise ValueError(line)
                    values[metric] = float(value)
                measurements[variant].append(values)
                result['samples'].append(dict(size=size, round=rep, variant=variant, **values))
        summary = dict(size=size)
        for metric in measurements['baseline'][0]:
            before = statistics.median(m[metric] for m in measurements['baseline'])
            after = statistics.median(m[metric] for m in measurements['candidate'])
            summary[metric] = dict(before=before, after=after, reduction_pct=100 * (1 - after / before) if before else None)
        result['summary'].append(summary)
        (out / 'results.json').write_text(json.dumps(result, indent=2) + '\n')
        print(json.dumps(summary), flush=True)


if __name__ == '__main__':
    main()
