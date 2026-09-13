# Reboot autostart, no scheduler

The goal: a workflow that keeps itself running with **no** cron/scron/batch
component, and comes back on its own after a node reboot.

## How it works

1. **User lingering** (`loginctl enable-linger $USER`) makes systemd start your
   per-user manager (`user@<uid>.service`) at boot, whether or not you log in.
2. The unit has `[Install] WantedBy=default.target`. `systemctl --user enable`
   links it into that target, so the user manager starts it when it comes up.
3. `Restart=on-failure` in the unit restarts `loop.sh` if it crashes (non-zero
   exit). A clean exit (workflow finished, exit 0) is **not** restarted.
4. When the workflow settles, `loop.sh` runs
   `systemctl --user disable rocoto-workflow@<instance>` on itself, so a
   completed workflow is not relaunched at the next boot.

## Use

```bash
loginctl enable-linger "$USER"                       # once
systemctl --user enable --now rocoto-workflow@<instance>
```

Check:

```bash
systemctl --user is-enabled rocoto-workflow@<instance>   # enabled
systemctl --user status     rocoto-workflow@<instance>
```

Stop for good before completion:

```bash
systemctl --user disable --now rocoto-workflow@<instance>
```

## On a shared `$HOME`, pin the instance

The `enable` symlink lives in `~/.config/systemd/user/`, but lingering is set
per node. Where `$HOME` is shared (as on most HPCs), every node on which you
have enabled lingering sees the same enabled unit and starts it at boot. Pin the
instance (`PIN_NODE`; see [`node-isolation.md`](node-isolation.md)) so only one
node runs it: on the others the unit's `ExecCondition=` guard skips the start,
and the unit stays inactive without retrying.

## What this does NOT cover

* If the **entire user manager** dies mid-run without a reboot (rare), nothing
  restarts the service until the next login or reboot. The optional
  [scron watchdog](scron-watchdog.md) covers that.
* A hung node. Same as any long-running process.
* `RuntimeMaxSec` is left unset so long realtime workflows are not SIGKILLed;
  `loop.sh`'s `MAX_RUNTIME` is the soft equivalent (clean exit for cleanup).
  Add a hard cap with `systemctl --user edit rocoto-workflow@<instance>` if you
  want one.
