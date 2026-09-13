# Testing

Three tiers, split by what infrastructure they need. The split matters because
this project's whole job is to glue together three things that are awkward to
have on a laptop — Rocoto, a systemd user manager, and Slurm — and only one of
them is actually hard to fake.

| Tier | Needs | Where it runs | How long |
|---|---|---|---|
| 1. hermetic | bash + bats | anywhere, incl. macOS | seconds |
| 2. systemd integration | systemd as PID 1, a lingering user | devcontainer, CI, a Linux box | ~1 min |
| 3. real-iron | a Slurm cluster with scron, a real Rocoto | a login node, by hand | a workflow's lifetime |

Tiers 1 and 2 are automated. Tier 3 is a checklist, deliberately.

```sh
tests/run.sh                                  # tier 1
tests/run.sh tests/unit/watchdog.bats         # one file
ROCOTO_SYSTEMD_LIVE_TESTS=1 tests/run.sh      # tiers 1 + 2, on a Linux host
.devcontainer/test-in-container.sh            # tiers 1 + 2, from macOS
```

`tests/run.sh` uses `bats` from `$PATH` if you have it and otherwise clones a
pinned copy into `tests/.bats/` (gitignored), so a fresh clone needs only bash
and git.

---

## How much infrastructure do we actually need?

Short answer: far less than it looks, for everything except the unit file.

**Slurm is a three-symbol dependency.** Grep the whole repo and Slurm appears as
`sinfo` (offer a node list during registration), `scancel` (the watchdog
retiring its own scron job) and `$SLURM_JOB_ID`. None of the decision logic
talks to a controller. A recording stub on `$PATH` covers every branch, and
`tests/unit/watchdog.bats` asserts on exactly which `scancel` the watchdog
would have issued. Standing up slurmctld would not test one additional line.

What a real Slurm *would* add is the one thing stubs cannot model: that
`scancel` on a scron job makes Slurm rewrite the scrontab with `#DISABLED: `
prepended, which is the mechanism the whole teardown design rests on. That is
tier 3, item 1 below.

**Rocoto is a two-command dependency.** `rocotorun` (fire and forget) and
`rocotostat -c ALL -s`, whose tabular output is parsed by exactly one awk
program in `rocoto_settled`. The parser is tested against captured output
shapes; the rest is stubs. Installing a real Rocoto would not help without a
batch system underneath it, since Rocoto needs a scheduler to drive — worth
checking whether any Rocoto release has a fork/local scheduler before investing
in this, as that would make a cheap tier-2.5 possible.

**systemd is the real dependency.** The unit file is a genuine piece of the
program, and none of it can be stubbed: whether `%h` expands, whether
`EnvironmentFile=` is read before `ExecCondition` runs, whether a wrong-node
skip really leaves no restart queued, whether `RestartPreventExitStatus=78`
actually suppresses the restart,
whether `StandardOutput=append:` is supported by the systemd on the target,
whether `MemoryAccounting=yes` produces the cgroup numbers `summarize-mem.sh`
reports. That is what tier 2 exists for, and it is the reason the devcontainer
boots systemd as PID 1 instead of being a plain Ubuntu box.

---

## Tier 1 — hermetic (`tests/unit/`)

Every test gets a throwaway `$HOME` and a stub directory at the front of
`$PATH` (`tests/helpers/common.bash`). Stubs record their arguments, so tests
assert on *what the script decided to do*, not on prose in the log.

| File | What it pins down |
|---|---|
| `common_node_pin.bats` | `node_pin_ok`: FQDN/short-name matching both directions, the unpinned case, the `hostname -s` fallback |
| `common_rocoto_settled.bats` | the settled/not-settled decision, including every "exit 1 on doubt" case: no cycles yet, empty output, `rocotostat` failure |
| `common_linger.bats` | `linger_state`, `ensure_linger`'s enable-then-recheck, the remediation message, `wait_user_manager`'s give-up |
| `common_module.bats` | `ROCOTO_BIN` vs `ROCOTO_MODULE` vs already-on-`PATH` precedence, and the failure messages |
| `node_guard.bats` | the `ExecCondition` guard: exit 0 when allowed, 70 (a skip, never 255) on the wrong node |
| `loop.bats` | config validation (exit 78), plus a full drive-loop pass against a stubbed rocoto: settled exit, `MAX_RUNTIME` exit, `IDLE_LIMIT` needing *consecutive* passes, the self-`disable` |
| `watchdog.bats` | the whole decision matrix — start / leave alone / tear down — plus EnvironmentFile syncing |
| `install.bats` | flattened layout, idempotency, and that uninstall keeps instance configs and logs |
| `new_workflow.bats` | the generated `.env` and `.scrontab`, driven by feeding answers on stdin |
| `summarize_mem.bats` | peak-picking arithmetic against a fixture, and a round trip against a `mem.log` that `loop.sh` just wrote |
| `unit_file.bats` | the seams: paths and exit codes the unit file and four shell scripts each hardcode separately |

Two conventions worth keeping:

* **Cross-checks over restatement.** `unit_file.bats` does not assert
  "`RestartPreventExitStatus` is 78"; it asserts that the code in the unit file
  is the code `loop.sh` actually exits with, and `node_guard.bats` that the
  guard's wrong-node exit is one `ExecCondition` treats as a skip. Same for
  the env-file path, the log path, and the scrontab export list versus the
  variables `watchdog.sh` reads. These are the couplings nothing else notices.
* **Answers as arrays, not here-documents.** In `new_workflow.bats` a blank
  line means "accept the default", so a here-doc with a miscounted blank line
  silently shifts every later answer by one and still passes. One array element
  per prompt, commented.

## Tier 2 — systemd integration (`tests/systemd/live.bats`)

Skipped unless `ROCOTO_SYSTEMD_LIVE_TESTS=1` *and* `systemctl --user` answers.
It installs into the real `$HOME`, because systemd's `%h` is the manager's idea
of the home directory and cannot be redirected per-test — so run it in the
devcontainer or in CI, not on a login node where you have a live instance.

It covers: `systemd-analyze verify` on the template; the EnvironmentFile
resolving; a settled workflow reaching `Result=success` with `NRestarts=0`;
`StandardOutput=append:` producing the log the docs point at; cgroup accounting
producing a profile `summarize-mem.sh` can read; a finished workflow disabling
its own boot autostart; a wrong-node start being *skipped*
(`Result=exec-condition`, no restart queued); and a bad-config exit 78 failing
*without* a restart loop.

That last pair is the highest-value test in the repo, and it has already paid
for itself. It caught the original design -- the guard as an `ExecStartPre`
exiting 70 under `RestartPreventExitStatus=70` -- retrying every 60 seconds
forever: systemd applies `RestartPreventExitStatus=` to the main process only.
At `RestartSec=60` that is 5 starts per 300 s, under `StartLimitBurst=10`, so
the start limit never trips either.

## Tier 3 — real iron (manual checklist)

Not automatable, and not worth pretending otherwise. Run on a login node when
touching the scron or node-isolation paths:

1. **`scancel` really disables the scrontab entry.** Register an instance with a
   watchdog, let the workflow finish, confirm Slurm has prepended `#DISABLED: `
   to the lines in `scrontab -l`. The entire teardown design depends on this
   Slurm behaviour and nothing else verifies it.
2. **Lingering survives a real logout.** Start an instance, log out, log back in
   an hour later, confirm the service is still running. This is the failure the
   project exists to prevent.
3. **Reboot autostart.** `systemctl --user enable --now`, get the node rebooted,
   confirm the instance comes back.
4. **The wrong-node path under scron.** Pin an instance, remove
   `#SCRON --nodelist=` from the scrontab, confirm the watchdog exits 71 rather
   than starting a second copy.
5. **A real memory profile.** Run a real workflow for a day and check
   `summarize-mem.sh` output against `MemoryHigh=1G` / `MemoryMax=2G` in the
   unit. The caps are guesses until real numbers exist.

---

## Known coverage gaps

Each of these is a branch the suite cannot reach as the code stands, with the
change that would make it reachable. None is urgent.

* **`load_rocoto_module`'s module-init fallback.** It sources a hardcoded list
  of absolute paths (`/etc/profile.d/lmod.sh` and friends); absolute paths
  cannot be faked. `common_module.bats` skips that one test on a host that has
  any of them. Injecting the list (`MODULE_INIT_FILES=${MODULE_INIT_FILES:-...}`)
  would close it.
* **`mem_sample`'s `/proc` reader.** It reads `/proc/<pid>/status` and
  `smaps_rollup` directly, so it only does real work on Linux; elsewhere the
  loop body is skipped and only the TOTAL row is written. Tier 2 covers it for
  real. A `PROC_ROOT=${PROC_ROOT:-/proc}` indirection would make the per-process
  arithmetic testable everywhere, including the PSS summing and the cgroup
  fallback path.
* **`loop.sh`'s older-systemd branch.** The `[ ! -f /proc/self/fd/1 ]` check that
  reopens stdout onto `SERVICE_LOG` is always *taken* under a test harness and
  never taken under a modern unit, so the "systemd is already appending" path
  is only exercised in tier 2.
* **Concurrency.** Nothing tests two watchdog invocations overlapping, which
  scron makes possible if a pass outlives its interval. `#SCRON
  --dependency=singleton` is supposed to prevent it; that is an assumption, not
  a tested property.

## Backlog

Roughly in value order, none written yet:

1. `mem_sample` unit tests behind a `PROC_ROOT` indirection — the most complex
   untested code in the repo, and the code that produces the numbers people use
   to justify resource caps.
2. A `rocotostat` output-shape corpus. The parser assumes column 2 is the state
   and that a header occupies row 1. Capturing real output from a few Rocoto
   versions into `tests/fixtures/` would turn an assumption into a test.
3. Log rotation / growth. `loop.sh` appends to `mem.log` forever, once per
   sample interval per process, for workflows that can run for days. There is
   no test and, currently, no rotation.
4. `install.sh` upgrade-in-place over an older layout.
5. A shfmt formatting hook, if the repo ever wants enforced formatting — it
   currently reflows the aligned `ask`/prompt columns in `new-workflow.sh`, so
   adopting it means a one-time repo-wide reformat.
