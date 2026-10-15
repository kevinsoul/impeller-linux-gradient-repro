#!/usr/bin/env python3
"""对比 Impeller / Skia 两份复现日志的每帧光栅耗时。

用法: python3 repro_compare.py <impeller.log> <skia.log>
"""
import re
import statistics
import sys
from collections import OrderedDict

LINE = re.compile(r'^\[FT\] (\S+) ([\d.]+) ([\d.]+) ([\d.]+) ([\d.]+)\s*$')
WARMUP = 30          # 每个场景丢弃前 N 帧（着色器/管线编译等预热）


def parse(path):
    data = OrderedDict()
    for line in open(path, errors='ignore'):
        if '[REPRO] DONE' in line:
            break          # 其后为退出阶段帧，不计入
        m = LINE.match(line.strip())
        if not m:
            continue
        name, b, r, v, t = m.group(1), *(float(m.group(i)) for i in range(2, 6))
        data.setdefault(name, []).append((b, r, v, t))
    return data


def pct(xs, q):
    s = sorted(xs)
    return s[min(len(s) - 1, int(len(s) * q))]


def describe(frames):
    f = frames[WARMUP:]
    if not f:
        f = frames
    r = [x[1] for x in f]
    b = [x[0] for x in f]
    t = [x[3] for x in f]
    return dict(
        n=len(f),
        build=statistics.median(b),
        raster=statistics.median(r),
        raster_p90=pct(r, 0.9),
        over=100.0 * sum(1 for x in r if x > 16) / len(r),
        total=statistics.median(t),
    )


def main():
    imp, ski = parse(sys.argv[1]), parse(sys.argv[2])
    order = list(imp.keys()) or list(ski.keys())
    print(f"{'scenario':16s} {'Renderer':10s} {'frames':>6s} {'build中位':>9s} {'raster中位':>10s} "
          f"{'raster p90':>10s} {'raster>16ms':>11s} {'total中位':>9s} {'raster 倍率':>10s}")
    print('-' * 108)
    for name in order:
        if name == 'warmup':
            continue
        ai = describe(imp[name]) if name in imp else None
        ak = describe(ski[name]) if name in ski else None
        ratio = f"{ai['raster'] / ak['raster']:.2f}x" if ai and ak and ak['raster'] else '-'
        for tag, a in (('Impeller', ai), ('Skia', ak)):
            if not a:
                print(f"{name:16s} {tag:10s} {'(无数据)':>6s}")
                continue
            print(f"{name:16s} {tag:10s} {a['n']:6d} {a['build']:9.2f} {a['raster']:10.2f} "
                  f"{a['raster_p90']:10.2f} {a['over']:10.0f}% {a['total']:9.2f} "
                  f"{(ratio if tag == 'Skia' else ''):>10s}")
        print()


if __name__ == '__main__':
    main()
