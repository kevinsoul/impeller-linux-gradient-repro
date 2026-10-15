#!/usr/bin/env python3
"""分析复现工程 Impeller timeline：纹理上传 / 着色器 / 渐变相关事件。

用法: python3 analyze_grad.py <timeline.json>
"""
import collections
import json
import re
import sys

PAT = re.compile(r'Texture|Image|Glyph|Gradient|Shader|Program|RuntimeEffect|Blend|Save|Clip|Pass|Draw|Buffer|Atlas|Sampler|SDF|Cache', re.I)


def main():
    d = json.load(open(sys.argv[1]))
    evs = d['traceEvents']
    tid2name = {}
    for e in evs:
        if e.get('name') == 'thread_name' and 'tid' in e:
            tid2name[e['tid']] = (e.get('args') or {}).get('name', '?')
    tevs = [e for e in evs if 'ts' in e and 'tid' in e]
    span = (max(e['ts'] for e in tevs) - min(e['ts'] for e in tevs)) / 1000.0
    stack = collections.defaultdict(list)
    agg = collections.defaultdict(lambda: [0, 0.0])
    for e in sorted(tevs, key=lambda x: x['ts']):
        k = (e['tid'], e.get('name'))
        if e.get('ph') == 'B':
            stack[k].append(e['ts'])
        elif e.get('ph') == 'E' and stack.get(k):
            dur = e['ts'] - stack[k].pop()
            # 事件名同时按线程类型分组
            tname = tid2name.get(e['tid'], '')
            tag = 'Raster' if 'raster' in tname.lower() else ('UI' if 'ui' in tname.lower() else tname)
            a = agg[(tag, e.get('name'))]
            a[0] += 1
            a[1] += dur
    frames = agg[('Raster', 'GPURasterizer::Draw')][0] or 1
    print(f'timeline {span/1000:.1f}s, {len(evs)} events, raster frames={frames}')
    print(f"\n=== 光栅线程匹配事件（按累计耗时）===")
    rows = sorted([kv for kv in agg.items() if kv[0][0] == 'Raster' and PAT.search(kv[0][1])],
                  key=lambda kv: -kv[1][1])
    for (tag, name), (c, tot) in rows:
        print(f'  {name[:52]:52s} n={c:6d} ({c/frames:7.1f}/帧) 累计={tot/1000:8.2f}ms 均值={tot/c/1000:6.3f}ms')
    print(f"\n=== UI 线程匹配事件 top 12 ===")
    rows = sorted([kv for kv in agg.items() if kv[0][0] == 'UI' and PAT.search(kv[0][1])],
                  key=lambda kv: -kv[1][1])[:12]
    for (tag, name), (c, tot) in rows:
        print(f'  {name[:52]:52s} n={c:6d} 累计={tot/1000:8.2f}ms')


if __name__ == '__main__':
    main()
