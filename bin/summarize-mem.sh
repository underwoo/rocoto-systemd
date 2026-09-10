#!/usr/bin/env bash
#
# Summarize a <instance>.mem.log produced by loop.sh:
#   peak RSS / PSS / thread count per process, peak whole-service cgroup.
#
# usage: summarize-mem.sh path/to/<instance>.mem.log

set -u
f="${1:?usage: summarize-mem.sh <instance>.mem.log}"
[ -r "$f" ] || { echo "cannot read $f" >&2; exit 1; }

awk -F'\t' '
  $3 == "PROC" {
    comm=$8; rss=$6+0; pss=$7+0; thr=$5+0
    if (rss > mr[comm]) mr[comm]=rss
    if (pss > mp[comm]) mp[comm]=pss
    if (thr > mt[comm]) mt[comm]=thr
    seen[comm]=1
  }
  $3 == "TOTAL" {
    if ($6+0 > sr) sr=$6+0
    if ($7+0 > sp) sp=$7+0
    n=split($9,a,"="); if (a[n]+0 > cp) cp=a[n]+0     # cgroup_peak=NNN
  }
  $3 == "SERVICE" {
    # e.g. MemoryPeak=123456789
    if (match($0,/MemoryPeak=[0-9]+/)) {
      v=substr($0,RSTART+11,RLENGTH-11)+0; if (v>svc) svc=v
    }
  }
  END {
    printf "%-20s %12s %12s %9s\n", "process", "peakRSS_MB", "peakPSS_MB", "peakThr"
    printf "%-20s %12s %12s %9s\n", "--------------------", "----------", "----------", "--------"
    for (c in seen)
      printf "%-20s %12.1f %12.1f %9d\n", c, mr[c]/1024, mp[c]/1024, mt[c]
    print  ""
    printf "%-20s %12.1f %12.1f\n", "sum-of-procs (peak)", sr/1024, sp/1024
    if (cp  > 0) printf "%-20s %12.1f   (cgroup.memory.peak)\n",   "service cgroup peak", cp/1048576
    if (svc > 0) printf "%-20s %12.1f   (systemd MemoryPeak)\n",   "service peak", svc/1048576
  }
' "$f"
