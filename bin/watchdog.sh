#!/usr/bin/env bash
#
# watchdog.sh -- invoked by scrontab every few minutes.
#
#   * (re)writes ~/.config/rocoto-systemd/<instance>.env from the exported vars
#   * starts rocoto-workflow@<instance>.service if it is not running and the
#     workflow is not yet settled
#   * once the workflow has NO Active cycles:
#       - stops the service
#       - `scancel $SLURM_JOB_ID` on itself.  Slurm responds by prepending
#         "#DISABLED: " to this job's lines in the scrontab, so no future cycle runs.
#
# Configuration comes entirely from the scrontab `#SCRON --export=` list:
#   WF, DB, WD                (required)
#   INSTANCE                  (optional; default basename of WD)
#   ROCOTO_MODULE, ROCOTO_MODULEPATH, ROCOTO_BIN, VERBOSITY, INTERVAL,
#   IDLE_LIMIT, MAX_RUNTIME, MEM_SAMPLE_INTERVAL   (optional; passed through to the unit)

set -u

SELF_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck disable=SC1091
. "${SELF_DIR}/common.sh" 2>/dev/null || . "${SELF_DIR}/../lib/common.sh"

# systemctl --user needs this when there is no login session
export XDG_RUNTIME_DIR="${XDG_RUNTIME_DIR:-/run/user/$(id -u)}"

log() { echo "$(date '+%Y-%m-%dT%H:%M:%S')  [watchdog${INSTANCE:+/$INSTANCE}]  $*"; }

for v in WF DB WD; do
  eval "val=\${$v:-}"
  [ -n "$val" ] || { echo "watchdog.sh: $v not set (add it to '#SCRON --export=')" >&2; exit 78; }
done
INSTANCE="${INSTANCE:-$(basename "$WD")}"
UNIT="rocoto-workflow@${INSTANCE}.service"

# --- node isolation --------------------------------------------------------
# If this instance is pinned (PIN_NODE), scron must have landed on that node.
# If it didn't, do NOT start a second copy elsewhere -- fail loudly instead.
if ! node_pin_ok; then
  log "ERROR: scron ran this watchdog on the wrong node."
  log "       Ensure the scrontab entry has:  #SCRON --nodelist=${PIN_NODE%%.*}"
  exit 71
fi

# --- lingering (required; try to enable, fail clearly if we can't) --------
if ! ensure_linger; then
  exit 1
fi
if ! wait_user_manager; then
  log "ERROR: 'systemctl --user' is not responsive even after enabling linger."
  log "       Check: XDG_RUNTIME_DIR=$XDG_RUNTIME_DIR ; loginctl user-status $USER"
  exit 1
fi

ENVDIR="${HOME}/.config/rocoto-systemd"
ENVFILE="${ENVDIR}/${INSTANCE}.env"
mkdir -p "$ENVDIR"

# Sync the EnvironmentFile from whatever the scrontab exported.
{
  echo "# written by watchdog.sh $(date)"
  echo "WF=$WF"
  echo "DB=$DB"
  echo "WD=$WD"
  echo "INSTANCE=$INSTANCE"
  for k in PIN_NODE ROCOTO_MODULE ROCOTO_MODULEPATH ROCOTO_BIN VERBOSITY INTERVAL \
           IDLE_LIMIT MAX_RUNTIME MEM_SAMPLE_INTERVAL SERVICE_LOG MEM_LOG; do
    eval "kv=\${$k:-}"
    [ -n "$kv" ] && echo "$k=$kv"
  done
} > "${ENVFILE}.tmp" && mv "${ENVFILE}.tmp" "$ENVFILE"

load_rocoto_module || { log "WARNING: could not load rocoto module; cannot check settled state"; }

if command -v rocotostat >/dev/null 2>&1 && rocoto_settled "$WF" "$DB"; then
  log "workflow SETTLED -- stopping $UNIT and disabling this scrontab entry"
  systemctl --user stop "$UNIT" 2>/dev/null || true
  systemctl --user reset-failed "$UNIT" 2>/dev/null || true
  if [ -n "${SLURM_JOB_ID:-}" ]; then
    log "scancel $SLURM_JOB_ID  (Slurm will prepend '#DISABLED: ' to the scrontab lines)"
    # do this last; scancel will terminate this job
    scancel "$SLURM_JOB_ID"
  fi
  exit 0
fi

if systemctl --user is-active --quiet "$UNIT"; then
  log "service is active; nothing to do"
  exit 0
fi

log "service not running and workflow not settled -- starting $UNIT"
systemctl --user reset-failed "$UNIT" 2>/dev/null || true
systemctl --user daemon-reload 2>/dev/null || true
if systemctl --user start "$UNIT"; then
  log "started $UNIT"
else
  log "ERROR: failed to start $UNIT  (see: journalctl --user -u $UNIT)"
  exit 1
fi
