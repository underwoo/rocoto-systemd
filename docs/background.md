# Background: why a `systemd --user` service

## Rocoto's normal model

`cron` runs `rocotorun` every few minutes. On the first run Rocoto forks and
daemonizes three helpers over DRb:

* `rocotobqserver` — all batch-scheduler interaction (`sbatch`/`squeue`/`sacct`/
  `scancel`); submissions run in a thread pool and their job ids are retrieved by
  a **later** `rocotorun` invocation;
* `rocotoioserver` — filesystem `stat`s for `<datadep>`, with hang isolation;
* `rocotodbserver` — serialized access to the SQLite workflow DB.

`rocotobqserver` is *designed to outlive* the `rocotorun` that spawned it: it
double-forks, `setsid`s, and is reparented to init. Under `crond` (a plain system
daemon) that orphan just keeps running until the next `rocotorun` collects its
results. The SQLite DB on shared storage is the source of truth between runs.

## Why that breaks without a cron node

Running `rocotorun` from a batch or `scron` job:

1. **The helper daemons are killed at step teardown.** `setsid` detaches a
   process from its session but **not** from its cgroup. `slurmstepd` tracks the
   job by cgroup membership and SIGKILLs everything in it when the batch step
   ends. The "daemonized" `rocotobqserver` dies seconds after `rocotorun`
   returns — every invocation. The next `rocotorun` then can't retrieve the job
   id of an in-flight submission, assumes failure, and **resubmits** — duplicate
   jobs, which for some tasks corrupts the run.

2. **Even if it survived, it may be unreachable.** The daemon serves on
   `druby://<host>:<port>`. If the next job lands on a different node and the
   site blocks arbitrary node-to-node TCP (Gaea does), the hand-off fails the
   same way.

Turning the daemons off (`rocotorc`) makes submission synchronous but keeps an
in-process thread pool, and has its own failure modes under a time-boxed job
step; it also loses the filesystem-hang isolation the ioserver provides.

## What this repo does

Run **one persistent process per workflow** — `while true; do rocotorun; sleep; done`
— as a `systemd --user` service.

* The service runs under `user@<uid>.service` in `user.slice`, **not** any job
  cgroup. Nothing tears it down when a batch step ends.
* `rocotorun` and all three helper daemons are children of that persistent
  process on one node for its whole life — every DRb hand-off is loopback.
* Rocoto runs in its **normal daemon mode**, unmodified.
* With user **lingering**, the user manager starts at boot, so an `enable`d
  service resumes automatically after a reboot — no scheduler needed.

The remaining role for `cron`/`scron` is a thin optional *watchdog* that restarts
the service if the entire user manager dies without a reboot
([`scron-watchdog.md`](scron-watchdog.md)).

## Memory

The whole footprint (driver + 3 daemons + transient `squeue`/`sacct`) is low
hundreds of MB for a typical workflow, spiking briefly once per pass. `loop.sh`
records it every pass; see [`memory-profiling.md`](memory-profiling.md).
