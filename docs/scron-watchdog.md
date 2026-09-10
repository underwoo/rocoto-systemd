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
4. Rewrite `~/.config/rocoto-systemd/<instance>.env` from the `#SCRON --export=`
   list.
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

All configuration travels in `#SCRON --export=` (comma-separated, no spaces):
`WF,DB,WD,INSTANCE`, optional `PIN_NODE`, the `ROCOTO_*` vars, and the tunables.
`watchdog.sh` turns that into the `EnvironmentFile` the service reads.

## Interaction with `enable`

Fine to use both: `enable --now` for boot autostart + the watchdog for
manager-death recovery. On completion `loop.sh` `disable`s the unit and the
watchdog `scancel`s itself — both entry points go quiet.
