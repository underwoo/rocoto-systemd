#!/usr/bin/env bash
#
# watchdog.sh -- invoked by scrontab every few minutes.
#
#   * (re)writes ~/.config/rocoto-systemd/<instance>.env from whatever this
#     tick's environment/persisted config resolves to
#   * starts rocoto-workflow@<instance>.service if it is not running and the
#     workflow is not yet settled
#   * once the workflow has NO Active cycles:
#       - stops the service
#       - `scancel $SLURM_JOB_ID` on itself.  Slurm responds by prepending
#         "#DISABLED: " to this job's lines in the scrontab, so no future cycle runs.
#
# Configuration:
#   INSTANCE  passed as $1 on the crontab command line -- a literal value
#             baked into the job command by new-workflow.sh, or hand-written
#             in a .scrontab file (see examples/scrontab.example). Falls back
#             to $INSTANCE / the basename of $WD if no arg is given, which is
#             what a manual/test invocation typically uses.
#   WF, DB, WD, and everything else (ROCOTO_MODULE, ROCOTO_MODULEPATH,
#             ROCOTO_BIN, VERBOSITY, INTERVAL, IDLE_LIMIT, MAX_RUNTIME,
#             MEM_SAMPLE_INTERVAL, PIN_NODE) come from the environment when
#             present (e.g. a manual `WF=... DB=... WD=... ./watchdog.sh`
#             run), else from ~/.config/rocoto-systemd/<instance>.env -- the
#             file new-workflow.sh/setup_instance.sh write up front, which
#             this script also rewrites on every successful tick.
#
# NOTE: this deliberately does NOT rely on '#SCRON --export=' for anything.
# On at least one Slurm/scrontab setup, --export was observed to NOT
# propagate into the job's process environment on scrontab-triggered
# (re)executions AT ALL -- every exported variable silently missing, every
# tick, from install onward (see docs/scron-watchdog.md). So INSTANCE is
# passed as a plain literal argument (nothing for scrontab to substitute),
# and everything else comes from the persisted .env file, which must already
# exist before the first tick.

set -u

# cron, scron and `docker exec` can start a script with USER unset; under
# `set -u` the first bare $USER would abort it.
USER="${USER:-$(id -un)}"

SELF_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck disable=SC1091
. "${SELF_DIR}/common.sh" 2>/dev/null || . "${SELF_DIR}/../lib/common.sh"

# systemctl --user needs this when there is no login session
export XDG_RUNTIME_DIR="${XDG_RUNTIME_DIR:-/run/user/$(id -u)}"

log() { echo "$(date '+%Y-%m-%dT%H:%M:%S')  [watchdog${INSTANCE:+/$INSTANCE}]  $*"; }

# INSTANCE arrives as a literal $1 (see header). Fall back to $INSTANCE in
# the environment, then the basename of $WD, for manual/test invocation.
INSTANCE="${1:-${INSTANCE:-}}"
[ -n "$INSTANCE" ] || INSTANCE="$(basename "${WD:-}" 2>/dev/null || true)"

ENVDIR="${HOME}/.config/rocoto-systemd"
ENVFILE="${ENVDIR}/${INSTANCE:-unknown}.env"

# WF/DB/WD are not expected to be in the environment at all in the normal
# (scrontab) case -- read them from the persisted EnvironmentFile for this
# instance. An explicit environment (e.g. a manual test run) still wins if
# present.
if [ -z "${WF:-}" ] || [ -z "${DB:-}" ] || [ -z "${WD:-}" ]; then
  # shellcheck disable=SC1090
  [ -f "$ENVFILE" ] && . "$ENVFILE"
fi

[ -n "${INSTANCE:-}" ] || { echo "watchdog.sh: INSTANCE not set (pass it as \$1 on the crontab command line)" >&2; exit 78; }
for v in WF DB WD; do
  eval "val=\${$v:-}"
  [ -n "$val" ] || { echo "watchdog.sh: $v not set, and no fallback found at $ENVFILE (run new-workflow.sh or setup_instance.sh to create it)" >&2; exit 78; }
done
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

mkdir -p "$ENVDIR"

# Rewrite the EnvironmentFile from whatever this tick resolved (environment
# override if present, otherwise the file's own last-known-good contents).
# Keeps it self-correcting even if it's ever hand-edited.
{
  echo "# written by watchdog.sh $(date)"
  echo "WF=$WF"
  echo "DB=$DB"
  echo "WD=$WD"
  echo "INSTANCE=$INSTANCE"
  for k in PIN_NODE ROCOTO_MODULE ROCOTO_MODULEPATH ROCOTO_BIN VERBOSITY INTERVAL \
           IDLE_LIMIT MAX_RUNTIME MEM_SAMPLE_INTERVAL SERVICE_LOG MEM_LOG; do
    eval "kv=\${$k:-}"
    # `if`, not `[ ] &&`: this is the last command in the group, and a false
    # test would make the group exit non-zero and skip the `mv` below.
    if [ -n "$kv" ]; then echo "$k=$kv"; fi
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
