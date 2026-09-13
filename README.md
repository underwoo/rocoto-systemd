# rocoto-systemd

Run a [Rocoto](https://github.com/christopherwharrop/rocoto) workflow as a
long-lived **`systemd --user` service**, on machines where you cannot use `cron`
to poll `rocotorun`.

Rocoto's normal model expects a cron daemon to run `rocotorun` every few minutes;
between runs, Rocoto's helper daemons (`rocotobqserver`, `rocotoioserver`,
`rocotodbserver`) stay alive to hand state to the next invocation. On an HPC with
no cron node that model breaks:

* running `rocotorun` from a batch/`scron` job puts the helper daemons in the
  job's cgroup, so the scheduler kills them when the job step ends;
* a batch job that lands on a different node next time cannot reach a daemon left
  on the previous node.

`rocoto-systemd` instead runs one persistent process per workflow — a `while`
loop calling `rocotorun` — as a `systemd --user` service. That service lives in
`user.slice`, not any job cgroup, so it and its Rocoto daemons survive; with user
**lingering** enabled it also starts automatically at boot. A clean `rocotorun`
(daemon) setup runs inside it, unchanged.

See [`docs/background.md`](docs/background.md) for the full reasoning.

---

## Requirements

* `systemd` with per-user instances (`systemctl --user`), **v243+** for the
  unit's `ExecCondition=` node guard (v240+ for `StandardOutput=append:`; see
  the unit's comments for older versions).
* **User lingering** for any unattended use (boot autostart, or the scron
  watchdog):

  ```bash
  loginctl enable-linger "$USER"
  loginctl show-user "$USER" -p Linger      # -> Linger=yes
  ```

  `install.sh` attempts this; if your site's polkit denies self-service, an admin
  must do it.
* Rocoto on `PATH`, or loadable via an environment module, or a known bin dir.
* Rocoto in its **default (daemon) mode** — no `~/.rocoto/<ver>/rocotorc`
  disabling the servers.

---

## Install

```bash
./install.sh
```

Flattens `bin/ libexec/ lib/` into `~/rocoto-systemd/`, installs
`systemd/rocoto-workflow@.service` to `~/.config/systemd/user/`, tries to enable
lingering, and offers to run `new-workflow.sh`.

`./install.sh --uninstall` removes the scripts and unit (keeps your env files and
logs).

---

## Register a workflow

```bash
~/rocoto-systemd/new-workflow.sh
```

Prompts for `WF` (workflow XML), `DB` (workflow database), `WD` (working dir to
`cd` into), the Rocoto module, node isolation, and a few tunables. Writes:

* `~/.config/rocoto-systemd/<instance>.env` — the systemd `EnvironmentFile`
* `~/.config/rocoto-systemd/<instance>.scrontab` — only if you opt into the scron
  watchdog

`WF`, `DB`, `WD` are mandatory; the service refuses to start if any is unset.

---

## Run it

Pick one. `<instance>` is the nickname you chose.

| Mode | Command | Survives logout | Survives reboot |
|---|---|---|---|
| One-off | `systemctl --user start rocoto-workflow@<instance>` | with linger | no |
| **Autostart** | `systemctl --user enable --now rocoto-workflow@<instance>` | with linger | **yes** |
| + scron watchdog | autostart, plus paste `<instance>.scrontab` into `scrontab -e` | with linger | yes |

In every mode `loop.sh` runs `rocotorun -v` on `INTERVAL`, and **exits by itself
once the workflow has no `Active` cycles** (`Restart=on-failure` keeps it
stopped; if it was `enable`d, `loop.sh` also `disable`s it so a finished workflow
is not relaunched at the next boot).

The scron watchdog ([`docs/scron-watchdog.md`](docs/scron-watchdog.md)) is
**optional** — it only adds recovery for the case where the whole user manager
dies without a reboot, and it auto-clears its own `scrontab` entry when the
workflow finishes.

---

## Logs

| File | Contents |
|---|---|
| `~/rocoto-systemd/logs/<instance>.service.log` | `loop.sh` + verbose `rocotorun` (and its daemons). Appended across restarts. |
| `~/rocoto-systemd/logs/<instance>.mem.log` | per-pass memory profile of `rocotorun` + every helper daemon. `~/rocoto-systemd/summarize-mem.sh <file>` reduces it. See [`docs/memory-profiling.md`](docs/memory-profiling.md). |
| `$HOME/.rocoto/<ver>/<workflow>/log` and the `<log>` path in the XML | Rocoto's own logging (unchanged). |
| `journalctl --user -u rocoto-workflow@<instance>` | unit start failures. |

---

## Docs

* [`docs/background.md`](docs/background.md) — why `systemd --user`, the cgroup
  and cross-node reasoning, and what environment each script inherits.
* [`docs/reboot-autostart.md`](docs/reboot-autostart.md) — how `enable` + linger
  gives boot autostart with no scheduler.
* [`docs/node-isolation.md`](docs/node-isolation.md) — pinning an instance to one
  node and the three places it is enforced.
* [`docs/memory-profiling.md`](docs/memory-profiling.md) — reading `*.mem.log`,
  expected footprint, resource caps.
* [`docs/scron-watchdog.md`](docs/scron-watchdog.md) — the optional scron add-on.
* [`docs/testing.md`](docs/testing.md) — the three test tiers, what each one can
  and cannot prove, and the manual checklist for the rest.

---

## Repo layout

```
bin/         user-facing commands  (new-workflow.sh, watchdog.sh, summarize-mem.sh)
libexec/     invoked by systemd    (loop.sh = ExecStart, node-guard.sh = ExecCondition)
lib/         sourced helpers       (common.sh)
systemd/     rocoto-workflow@.service
examples/    instance.env.example, scrontab.example
docs/        the above
tests/       bats suite (run.sh, unit/ = hermetic, systemd/ = needs a user manager)
.devcontainer/  Ubuntu + systemd-as-PID-1 image for developing on macOS
.github/     pre-commit and test workflows
install.sh   flattens bin+libexec+lib into ~/rocoto-systemd/ and installs the unit
```

---

## Development

```sh
pip install pre-commit          # or: brew install pre-commit
pre-commit install              # lint + hygiene on every `git commit`
pre-commit run --all-files      # check the whole tree once
tests/run.sh                    # the hermetic test suite (needs only bash)
```

`SKIP=shellcheck git commit ...` skips one hook; `git commit --no-verify` skips
all of them.

The suite is tiered by what infrastructure it needs — see
[`docs/testing.md`](docs/testing.md):

* **hermetic** (`tests/unit/`) — stubs stand in for Rocoto, systemd and Slurm,
  so it runs anywhere including macOS. This is what `tests/run.sh` runs.
* **systemd integration** (`tests/systemd/`) — needs a real `systemctl --user`,
  and is the only tier that can test the unit file itself. Opt in with
  `ROCOTO_SYSTEMD_LIVE_TESTS=1`.
* **real iron** — a manual checklist for the Slurm and reboot behaviour that
  cannot be faked.

### Devcontainer

`.devcontainer/` is an Ubuntu image with **systemd running as PID 1** and a
lingering unprivileged user, which is the one thing a macOS workstation cannot
provide. Open the repo in a devcontainer and `systemctl --user` behaves the way
it does on a login node.

To run both automated tiers from macOS without opening an editor:

```sh
.devcontainer/test-in-container.sh
```

CI runs the hermetic tier on Linux and macOS, and the systemd tier inside that
same container image.
