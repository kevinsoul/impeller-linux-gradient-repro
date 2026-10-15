#!/usr/bin/env python3
"""二分结果汇总：解析 bisect_imp_*.log / bisect_skia_*.log 的逐帧 FrameTiming。

用法: python3 bisect_report.py "tag=path" ...
"""
import re
import statistics
import sys

FT = re.compile(
    r'buildDuration: ([\d.]+)ms, rasterDuration: ([\d.]+)ms, '
    r'vsyncOverhead: ([\d.]+)ms, totalSpan: ([\d.]+)ms')
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


def main():
    base_raster = None
    print(f"{'tag':22s} {'n':>5s} {'build中位':>9s} {'raster中位':>10s} {'raster p90':>10s} "
          f"{'vsync中位':>9s} {'total中位':>9s} {'raster/基线':>11s}")
    for arg in sys.argv[1:]:
        tag, path = arg.split('=', 1)
        f = parse(path)
        if not f:
            print(f'{tag:22s} 无数据')
            continue
        b = [x[0] for x in f]; r = [x[1] for x in f]; v = [x[2] for x in f]; t = [x[3] for x in f]
        rm = statistics.median(r)
        if 'baseline' in tag:
            base_raster = rm
        ratio = f'{rm / base_raster:.2f}x' if base_raster else '-'
        print(f'{tag:22s} {len(f):5d} {statistics.median(b):9.2f} {rm:10.2f} {pct(r,.9):10.2f} '
              f'{statistics.median(v):9.2f} {statistics.median(t):9.2f} {ratio:>11s}')


if __name__ == '__main__':
    main()
