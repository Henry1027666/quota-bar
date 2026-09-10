#!/bin/bash
# QuotaBar 内存监控 v3：每 10 秒记录 RSS/CPU/子进程数；RSS 超阈值自动抓 sample。
# 用法: nohup ./monitor.sh >/dev/null 2>&1 &
LOG=/tmp/quotabar-mem.log
THRESHOLD_MB=${1:-600}
echo "监控启动 v3 threshold=${THRESHOLD_MB}MB $(date '+%Y-%m-%d %H:%M:%S')" >> "$LOG"
while true; do
  PID=$(pgrep -f "\.build/release/QuotaBar" | head -1)
  if [ -n "$PID" ]; then
    RSS_KB=$(ps -o rss= -p "$PID" | tr -d ' ')
    CPU=$(ps -o %cpu= -p "$PID" | tr -d ' ')
    RSS_MB=$((RSS_KB / 1024))
    CHILDREN=$(pgrep -P "$PID" | wc -l | tr -d ' ')
    echo "$(date '+%H:%M:%S') pid=$PID rss=${RSS_MB}MB cpu=${CPU}% children=$CHILDREN" >> "$LOG"
    if [ "$RSS_MB" -gt "$THRESHOLD_MB" ]; then
      SAMPLE="/tmp/quotabar-sample-$(date +%m%d-%H%M%S).txt"
      sample "$PID" 5 -file "$SAMPLE" 2>/dev/null
      echo "!! 超阈值已抓 sample pid=$PID -> $SAMPLE" >> "$LOG"
      sleep 60
    fi
  else
    echo "$(date '+%H:%M:%S') (无进程)" >> "$LOG"
  fi
  sleep 10
done
