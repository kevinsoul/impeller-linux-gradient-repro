#!/bin/bash
# 真实应用（pressure）在模拟采集下逐渲染器抓取 timeline
# 用法: bash capture_real.sh
set -u
REPO=/home/vc/projects/visionox/pressure-sensor-12x4-mask
CAP=/tmp/opencode/vm_capture

run_one() {
  local tag=$1; shift
  local log=/tmp/opencode/real_${tag}.log
  rm -f "$log"
  cd "$REPO" || exit 1

  PRESSURE_FRAME_TIMINGS=1 PRESSURE_AUTOSIM=60 PRESSURE_AUTOSIM_SECONDS=0 \
    script -qec "flutter run -d linux $*" "$log" &
  local runner=$!

  # 1) 等 VM Service URI
  local uri=""
  for _ in $(seq 1 150); do
    uri=$(grep -a -o 'ws://127\.0\.0\.1:[0-9]*/[^ ]*/ws' "$log" 2>/dev/null | tail -1)
    [ -n "$uri" ] && break
    sleep 2
  done
  echo "[$tag] vm_service=$uri"

  # 2) 等进入模拟采集
  for _ in $(seq 1 60); do
    grep -aq '\[AUTOSIM\] collecting' "$log" && break
    sleep 2
  done
  sleep 4   # 让采集与界面进入稳态

  # 3) 抓 10s timeline
  if [ -n "$uri" ]; then
    (cd "$CAP" && dart run bin/capture.dart "$uri" 10 "/tmp/opencode/timeline_real_${tag}.json")
  else
    echo "[$tag] 未取到 VM Service，跳过抓取"
  fi

  # 4) 清理该轮进程
  pkill -f 'debug/bundle/pressure$' 2>/dev/null
  pkill -f 'bin/flutte[r] run -d linux' 2>/dev/null
  sleep 3
  pkill -f 'debug/bundle/pressure$' 2>/dev/null
  wait "$runner" 2>/dev/null
  echo "[$tag] done"
}

run_one impeller --enable-impeller
run_one skia
echo "ALL DONE"
