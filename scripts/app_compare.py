#!/usr/bin/env python3
"""真实应用（pressure）Impeller / Skia 逐帧对照。

用法: python3 app_compare.py <impeller.log> <skia.log>
自动丢弃启动帧（前 SKIP 帧），只统计模拟采集稳态。
"""
import re
import statistics
import sys
from collections import OrderedDict

FT = re.compile(
    r'buildDuration: ([\d.]+)ms, rasterDuration: ([\d.]+)ms, '
    r'vsyncOverhead: ([\d.]+)ms, totalSpan: ([\d.]+)ms')
# 采集开始标记：只统计 [AUTOSIM] collecting 之后的帧
START = '[AUTOSIM] collecting'
SKIP = 20


def parse(path):
    frames = []
    started = False
    for line in open(path, errors='ignore'):
        if START in line:
            started = True
            continue
        if not started or '[FrameTiming]' not in line:
            continue
        m = FT.search(line)
        if m:
            frames.append(tuple(float(m.group(i)) for i in range(1, 5)))
    return frames[SKIP:]


def pct(xs, q):
    s = sorted(xs)
    return s[min(len(s) - 1, int(len(s) * q))]


def stat(tag, frames):
    if not frames:
        print(f'{tag}: 无数据')
        return None
    b = [f[0] for f in frames]
    r = [f[1] for f in frames]
    v = [f[2] for f in frames]
    t = [f[3] for f in frames]
    print(f'{tag:10s} n={len(frames):4d} | build 中位={statistics.median(b):6.2f} p90={pct(b,.9):6.2f} | '
          f'raster 中位={statistics.median(r):6.2f} p90={pct(r,.9):6.2f} | '
          f'vsync 中位={statistics.median(v):6.2f} p90={pct(v,.9):6.2f} | '
          f'total 中位={statistics.median(t):6.2f} p90={pct(t,.9):6.2f} | raster>16ms={100*sum(1 for x in r if x>16)//len(r)}%')
    return statistics.median(r)


def main():
    imp, ski = parse(sys.argv[1]), parse(sys.argv[2])
    print('=== 真实应用（模拟采集稳态，逐帧 FrameTiming）===')
    ri = stat('Impeller', imp)
    rs = stat('Skia', ski)
    if ri and rs:
        print(f'\nraster 倍率: {ri/rs:.2f}x   (Impeller {ri:.2f}ms vs Skia {rs:.2f}ms)')
        b_ratio = statistics.median([f[0] for f in imp]) / statistics.median([f[0] for f in ski])
        print(f'build  倍率: {b_ratio:.2f}x')


if __name__ == '__main__':
    main()
