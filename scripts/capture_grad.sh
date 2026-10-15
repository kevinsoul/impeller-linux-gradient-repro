#!/bin/bash
# 抓取复现工程单场景（渐光）的 Impeller timeline，用于检查每帧纹理上传
set -u
REPRO=/tmp/opencode/impeller_repro
CAP=/tmp/opencode/vm_capture
LOG=/tmp/opencode/grad_timeline.log
rm -f "$LOG"

cd "$REPRO" || exit 1
REPRO_ONLY=grad_aurora_like REPRO_SECONDS=45 \
  script -qec "flutter run -d linux --enable-impeller" "$LOG" &
runner=$!

uri=""
for _ in $(seq 1 120); do
  uri=$(grep -a -o 'ws://127\.0\.0\.1:[0-9]*/[^ ]*/ws' "$LOG" 2>/dev/null | tail -1)
  [ -n "$uri" ] && break
  sleep 2
done
echo "vm_service=$uri"

for _ in $(seq 1 60); do
  grep -a -q '\[SCENARIO\] start grad_aurora_like' "$LOG" && break
  sleep 2
done
sleep 3

if [ -n "$uri" ]; then
  (cd "$CAP" && dart run bin/capture.dart "$uri" 12 /tmp/opencode/timeline_grad_impeller.json)
fi

pkill -f 'debug/bundle/pressure$' 2>/dev/null
pkill -f 'bin/flutte[r] run -d linux' 2>/dev/null
sleep 3
pkill -f 'debug/bundle/pressure$' 2>/dev/null
wait "$runner" 2>/dev/null
echo "GRAD TIMELINE DONE"
