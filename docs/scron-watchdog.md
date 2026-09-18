# Optional: the scron watchdog

**You do not need this** if you use `systemctl --user enable --now` with
lingering ([`reboot-autostart.md`](reboot-autostart.md)). That already gives boot
autostart and crash restart.

The watchdog adds one thing: recovery when the **entire `systemd --user`
manager** stops mid-run *without* a reboot (very rare). It also tidies up after
itself when the workflow finishes.

## What `watchdog.sh` does each tick

1. `export XDG_RUNTIME_DIR=/run/user/$(id -u)`.
2. Node check — if `PIN_NODE` is set and this isn't that node, log and `exit 71`
   (does **not** start a second copy). The `#SCRON --nodelist=` should prevent
   this.
3. Linger check — if not enabled, try `loginctl enable-linger`; if that fails,
   print a clear error and `exit 1`. Then wait up to 15 s for `systemctl --user`
   to respond.
4. Read `WF`/`DB`/`WD`/etc from `~/.config/rocoto-systemd/<instance>.env`
   (falling back to the environment first, for a manual/test invocation), then
   rewrite that same file so it stays current.
5. If the workflow has **no `Active` cycles**: `systemctl --user stop` the unit,
   then `scancel $SLURM_JOB_ID`. Slurm prepends `#DISABLED: ` to this job's
   `scrontab` lines, so it never fires again.
6. Otherwise: if the unit is not active, `systemctl --user start` it.

## Install

`new-workflow.sh` writes `~/.config/rocoto-systemd/<instance>.scrontab` when you
opt in. Review it against `examples/scrontab.example`, then:

```bash
scrontab -e        # paste it
scrontab -l        # verify
```

**This deliberately does not use `#SCRON --export=`.** On at least one Slurm
setup, `--export=` was confirmed to not reach the job's process environment on
scrontab-triggered (re)executions *at all* -- a watchdog installed with it
failed its `WF`/`DB`/`WD` check on every single tick, from the moment it was
installed, silently (`sacct` shows it "running" and exiting non-zero each
time, but nothing surfaces that unless you go looking).

So configuration travels a different way: `new-workflow.sh` (and
`setup_instance.sh`) write `~/.config/rocoto-systemd/<instance>.env` up front,
*before* the watchdog ever ticks, and `watchdog.sh` reads `WF`/`DB`/`WD`/
`PIN_NODE`/the `ROCOTO_*` vars/the tunables from that file. The only thing
that has to reach the watchdog job itself is `INSTANCE`, which is written as a
plain, literal argument on the crontab command line
(`watchdog.sh <instance-name>`, not a variable) -- nothing for scrontab to
substitute or drop.

One consequence: the `<instance>.env` file must exist before the watchdog's
first tick. Going through `new-workflow.sh` this is automatic (it always
writes the `.env` file, whether or not you opt into the watchdog). If you
hand-write a `.scrontab` without ever running `new-workflow.sh` or
`setup_instance.sh` for that instance, create the `.env` file yourself first
(see `examples/instance.env.example`) -- the watchdog can no longer bootstrap
it from nothing.

## Interaction with `enable`

Fine to use both: `enable --now` for boot autostart + the watchdog for
manager-death recovery. On completion `loop.sh` `disable`s the unit and the
watchdog `scancel`s itself — both entry points go quiet.
