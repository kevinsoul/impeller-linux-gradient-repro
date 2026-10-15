#!/usr/bin/env python3
"""对比真实应用 Impeller / Skia 的引擎 timeline（光栅/UI 线程构成）。

用法: python3 analyze_real.py <impeller.json> <skia.json>
"""
import collections
import json
import sys
import statistics


def load(path):
    d = json.load(open(path))
    evs = d['traceEvents']
    tid2name = {}
    for e in evs:
        if e.get('name') == 'thread_name' and 'tid' in e:
            tid2name[e['tid']] = (e.get('args') or {}).get('name', '?')
    tevs = [e for e in evs if 'ts' in e and 'tid' in e]
    span = (max(e['ts'] for e in tevs) - min(e['ts'] for e in tevs)) / 1000.0
    agg = collections.defaultdict(lambda: [0, 0.0])
    stack = collections.defaultdict(list)
    for e in sorted(tevs, key=lambda x: x['ts']):
        k = (e['tid'], e.get('name'))
        if e.get('ph') == 'B':
            stack[k].append(e['ts'])
        elif e.get('ph') == 'E' and stack.get(k):
            dur = e['ts'] - stack[k].pop()
            a = agg[k]
            a[0] += 1
            a[1] += dur
    return tid2name, agg, span, len(evs)


def label(tid2name, tid):
    n = tid2name.get(tid, '')
    if 'raster' in n.lower():
        return 'Raster'
    if 'ui' in n.lower():
        return 'UI'
    return n or f'tid{tid}'


def report(path, tag):
    tid2name, agg, span, nev = load(path)
    per = collections.defaultdict(float)
    for (tid, name), (c, tot) in agg.items():
        per[label(tid2name, tid)] += tot
    print(f"\n===== {tag} ===== timeline {span/1000:.1f}s, {nev} events")
    for th, tot in sorted(per.items(), key=lambda kv: -kv[1])[:4]:
        print(f'  {th:26s} 累计 {tot/1000:8.1f}ms')
    for want in ('Raster', 'UI'):
        rows = sorted([kv for kv in agg.items() if label(tid2name, kv[0][0]) == want],
                      key=lambda kv: -kv[1][1])[:12]
        tot_all = sum(v[1] for k, v in agg.items() if label(tid2name, k[0]) == want)
        print(f'  --- {want} top12（线程累计 {tot_all/1000:.0f}ms）---')
        for (tid, name), (c, tot) in rows:
            print(f'    {name[:50]:50s} n={c:6d} 累计={tot/1000:8.1f}ms 均值={tot/c/1000:6.2f}ms')
    return dict(agg=agg, tid2name=tid2name, span=span)


def main():
    imp = report(sys.argv[1], 'IMPELLER')
    ski = report(sys.argv[2], 'SKIA')
    # 关键事件对照
    keys = ['GPURasterizer::Draw', 'Rasterizer::DoDraw', 'Rasterizer::DrawToSurfaces',
            'ReactorGLES::React', 'FlushOps', 'ReactorGLES::Operation',
            'FlutterCompositorPresentLayers', 'CreateGlyphAtlas',
            'EmbedderExternalView::Render', 'Animator::BeginFrame', 'VsyncProcessCallback',
            'BUILD', 'LAYOUT', 'PAINT', 'Engine::DispatchPointerDataPacket']
    print('\n===== 关键事件对照 =====')
    print(f"{'event':42s} {'Impeller n':>10s} {'Imp均值ms':>9s} {'Skia n':>8s} {'Skia均值ms':>10s}")
    for k in keys:
        ri = [(tid, n, v) for (tid, n), v in imp['agg'].items() if n == k]
        rs = [(tid, n, v) for (tid, n), v in ski['agg'].items() if n == k]
        i_n = sum(x[2][0] for x in ri); i_t = sum(x[2][1] for x in ri)
        s_n = sum(x[2][0] for x in rs); s_t = sum(x[2][1] for x in rs)
        print(f'{k:42s} {i_n:10d} {(i_t/i_n/1000 if i_n else 0):9.2f} {s_n:8d} {(s_t/s_n/1000 if s_n else 0):10.2f}')


if __name__ == '__main__':
    main()
