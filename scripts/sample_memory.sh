#!/bin/zsh
# Samples what Chorus actually costs: the app process plus only the WebKit
# helpers that belong to it. Helpers are XPC services parented to launchd, so
# ownership comes from lsof — a Chorus helper holds a file under the app's own
# Application Support directory. One CSV row per sample.
OUT=${1:?usage: chorus-mem-sample.sh out.csv [interval_seconds]}
INTERVAL=${2:-300}
[[ -f $OUT ]] || print "iso_time,uptime,web_procs,main_mb,webcontent_mb,helpers_mb,total_mb" >> $OUT
while true; do
  MAIN_PID=$(pgrep -f '/Applications/Chorus.app/Contents/MacOS/Chorus' | head -1)
  if [[ -n $MAIN_PID ]]; then
    UP=$(ps -o etime= -p $MAIN_PID | tr -d ' ')
    MAIN_MB=$(( $(ps -o rss= -p $MAIN_PID | tr -d ' ') / 1024 ))
    wc_mb=0; wc_n=0; helper_mb=0
    for pid in $(ps -Ao pid,comm | grep -E 'WebKit.(WebContent|GPU|Networking)' | grep -v grep | awk '{print $1}'); do
      lsof -p $pid 2>/dev/null | grep -q 'com.nicojan.Chorus' || continue
      rss=$(( $(ps -o rss= -p $pid 2>/dev/null | tr -d ' ' || print 0) / 1024 ))
      if ps -o comm= -p $pid | grep -q WebContent; then
        wc_mb=$((wc_mb + rss)); wc_n=$((wc_n + 1))
      else
        helper_mb=$((helper_mb + rss))
      fi
    done
    print "$(date -u +%FT%TZ),$UP,$wc_n,$MAIN_MB,$wc_mb,$helper_mb,$((MAIN_MB + wc_mb + helper_mb))" >> $OUT
  fi
  sleep $INTERVAL
done
