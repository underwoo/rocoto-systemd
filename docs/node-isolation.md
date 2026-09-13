# Node isolation

Each node runs its **own** `systemd --user` manager, and on some HPCs (Gaea)
those managers cannot reach each other over the network. If an unattended
instance can be started on more than one node, you can end up with two `loop.sh`
processes on two nodes driving the same workflow DB.

Two `rocotorun` loops against one workflow is not automatically safe: Rocoto's
workflow lock has a stale-lock path that `ssh`es the lock holder to check
liveness; if that `ssh` can't cross nodes, one loop declares the other's lock
stale, steals it, and you get concurrent DB writes.

## Pinning

`new-workflow.sh` asks *"Pin this instance to a single node?"*. If yes, the node
name is written as `PIN_NODE=<node>` in `<instance>.env` (and, if you generate a
scron watchdog, into its `--export` list and `#SCRON --nodelist=`).

It is then enforced in three places:

| Where | Mechanism | On the wrong node |
|---|---|---|
| systemd service | `ExecCondition=.../node-guard.sh` reads `PIN_NODE` from the env file | start is skipped: the unit stays inactive (not failed) and is never restarted; the reason goes to the service log |
| `loop.sh` | same check at startup (backstop) | exits 78 with a message naming the correct node; 78 is in `RestartPreventExitStatus` |
| `watchdog.sh` (scron only) | same check | logs the error, exits 71, does **not** start a second copy |
| `#SCRON --nodelist=<node>` | Slurm | scron always runs the watchdog on that node |

So a user who runs `systemctl --user start rocoto-workflow@<instance>` from the
wrong login node gets no error from `systemctl` itself: the start is skipped.
`systemctl --user status rocoto-workflow@<instance>` shows the skip, and the
service log (`~/rocoto-systemd/logs/<instance>.service.log`) says why:

```
This workflow instance is PINNED to node '<node>', but this is '<this-node>'.
node-guard: refusing to start '<instance>' here.
node-guard: pinned to '<node>' -- start the service on that node,
node-guard: or clear PIN_NODE in ~/.config/rocoto-systemd/<instance>.env
```

Skipping rather than failing is deliberate. `systemctl --user enable` links the
unit under `~/.config/systemd/user/`, so on a shared `$HOME` **every** node
where you have lingering tries to start it at boot. The nodes it is not pinned
to should quietly stand down, not show a failed unit or retry every minute.
(`RestartPreventExitStatus=` cannot do this: systemd applies it only to the main
process, never to `ExecStartPre=` or `ExecCondition=`.)

## Choosing / changing the node

* List candidates: `sinfo -p <partition> -N -o '%N' | sort -u`
  (`new-workflow.sh` does this for you when a partition is given).
* To move a pinned instance: edit `PIN_NODE` in `<instance>.env`; if a scron
  watchdog exists, also update `--nodelist=` and `PIN_NODE=` in
  `<instance>.scrontab` and re-`scrontab -e`.
* Not pinning is fine when only one node can ever host the instance (single-node
  partition, or you always start it by hand on the same login node).
