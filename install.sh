#!/usr/bin/env bash
#
# Install rocoto-systemd for the current user.  Idempotent -- safe to re-run.
#
#   repo layout            ->  installed layout
#   -----------------------    -------------------------------------------
#   bin/ libexec/ lib/     ->  ~/rocoto-systemd/           (flattened)
#   systemd/*.service      ->  ~/.config/systemd/user/
#   (instances live in)        ~/.config/rocoto-systemd/<instance>.env
#
# Usage: ./install.sh [--uninstall]

set -eu

SRC="$(cd "$(dirname "$0")" && pwd)"
DEST="${HOME}/rocoto-systemd"
UNITDIR="${HOME}/.config/systemd/user"
ENVDIR="${HOME}/.config/rocoto-systemd"
UNIT="rocoto-workflow@.service"

if [ "${1:-}" = "--uninstall" ]; then
  echo "removing $DEST and $UNITDIR/$UNIT (leaving $ENVDIR and logs)"
  rm -f "$UNITDIR/$UNIT"
  rm -rf "$DEST"/{loop.sh,node-guard.sh,common.sh,watchdog.sh,summarize-mem.sh,new-workflow.sh}
  command -v systemctl >/dev/null 2>&1 && systemctl --user daemon-reload || true
  echo "done"
  exit 0
fi

echo "source : $SRC"
echo "scripts: $DEST"
echo "unit   : $UNITDIR/$UNIT"
echo "envdir : $ENVDIR"
echo

mkdir -p "$DEST/logs" "$UNITDIR" "$ENVDIR"

# Flatten bin/ + libexec/ + lib/ into one runtime dir (scripts find common.sh
# next to themselves there).
for d in bin libexec lib; do
  for f in "$SRC/$d"/*; do
    [ -e "$f" ] || continue
    cp "$f" "$DEST/$(basename "$f")"
    chmod +x "$DEST/$(basename "$f")" 2>/dev/null || true
  done
done
cp "$SRC/systemd/$UNIT" "$UNITDIR/$UNIT"

command -v systemctl >/dev/null 2>&1 && systemctl --user daemon-reload || true

# Lingering -- required for ANY unattended use (reboot autostart or scron watchdog).
linger=$(loginctl show-user "$USER" -p Linger 2>/dev/null | sed -n 's/^Linger=//p')
if [ "$linger" != "yes" ]; then
  echo "lingering is not enabled; trying: loginctl enable-linger $USER"
  loginctl enable-linger "$USER" >/dev/null 2>&1 || true
  linger=$(loginctl show-user "$USER" -p Linger 2>/dev/null | sed -n 's/^Linger=//p')
fi
echo "linger : Linger=${linger:-unknown}"
[ "$linger" = "yes" ] || echo "  !! an admin must enable it:  loginctl enable-linger $USER"
echo

cat <<EOF
Done.

Next
----
1. If linger is not 'yes' above, get it enabled (needed for unattended use).

2. Register a workflow (interactive; asks about node isolation):
       $DEST/new-workflow.sh
   -> writes ~/.config/rocoto-systemd/<instance>.env
             ~/.config/rocoto-systemd/<instance>.scrontab   (only if you want scron)

3. Choose how it runs:

   a) One-off (no scheduler, does not survive reboot):
        systemctl --user start  rocoto-workflow@<instance>

   b) Survive reboots (recommended; needs linger):
        systemctl --user enable --now rocoto-workflow@<instance>
        # loop.sh disables it again automatically once the workflow finishes

   c) Add a scron watchdog on top (optional; restarts if the whole user
      manager dies, and auto-clears its own scrontab entry on completion):
        scrontab -e     # paste ~/.config/rocoto-systemd/<instance>.scrontab

4. Watch / inspect:
       tail -f $DEST/logs/<instance>.service.log
       $DEST/summarize-mem.sh $DEST/logs/<instance>.mem.log
EOF

if [ -t 0 ] && [ -x "$DEST/new-workflow.sh" ]; then
  echo
  read -r -p "Run new-workflow.sh now? (y/N): " a || true
  case "${a:-N}" in [Yy]*) exec "$DEST/new-workflow.sh";; esac
fi
