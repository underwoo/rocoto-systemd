# Memory profiling

`loop.sh` samples memory every `MEM_SAMPLE_INTERVAL` seconds (default 3) for the
duration of each `rocotorun` pass, plus a few samples after (to catch daemons
that linger), and writes to `~/rocoto-systemd/logs/<instance>.mem.log`.

## Log format (tab separated)

```
# ts  tag        kind     pid    threads rss_kb  pss_kb  comm            args|cgroupinfo
...   iter3+0s   PROC     12345  11      121344  99820   ruby            .../sbin/rocotorun -w ...
...   iter3+0s   PROC     12377  9       86232   63110   rocotobqserver  ...
...   iter3+0s   TOTAL    -      -       ...     ...     cgroup_current=... cgroup_peak=...
...   iter3      SERVICE  MemoryCurrent=...  MemoryPeak=...  TasksCurrent=...
```

* `PROC` — one per process in the service cgroup: `rss_kb` from
  `/proc/<pid>/status`, `pss_kb` from `/proc/<pid>/smaps_rollup` (blank if the
  kernel lacks it), `threads` count.
* `TOTAL` — summed RSS/PSS across those processes, plus the cgroup's
  `memory.current` / `memory.peak`.
* `SERVICE` — systemd's own accounting for the whole unit.

`memory.peak` is reset at the start of each pass where the kernel allows
(≥ 6.8); otherwise it is cumulative for the service's life.

## Summarize

```bash
~/rocoto-systemd/summarize-mem.sh ~/rocoto-systemd/logs/<instance>.mem.log
```

```
process               peakRSS_MB   peakPSS_MB   peakThr
--------------------   ----------   ----------   --------
ruby                        118.4         96.1         11
rocotobqserver               84.2         61.7          9
rocotoioserver               41.0         33.5          4
rocotodbserver               47.3         38.9          4

sum-of-procs (peak)         291.0        230.2
service cgroup peak         305.7   (cgroup.memory.peak)
service peak                305.7   (systemd MemoryPeak)
```

`service cgroup peak` / `service peak` is the number for capacity planning —
everything the workflow touched, deduplicated.

## Expected footprint

* Steady state between passes: often near zero (helper daemons exit once
  submissions are harvested).
* Peak per pass: **low hundreds of MB** for a workflow with ~15–20 tasks/cycle
  and `cyclethrottle` 3, for a few seconds while `rocotorun` + `squeue`/`sacct`
  run.
* Inflators: a large `sacct` history (use `ROCOTO_SACCT_CACHE`), a much larger
  workflow XML (REXML parse scales ~linearly), a bqserver that has lived for days.

## Caps

The unit sets `MemoryHigh=1G`, `MemoryMax=2G`, `TasksMax=256` — a runaway is
throttled/OOM-killed, the node is not. Ask admins to also set `MemoryMax` /
`TasksMax` on `user-<uid>.slice` for a per-user ceiling across all services.
Tune the unit values with `systemctl --user edit rocoto-workflow@<instance>`.
