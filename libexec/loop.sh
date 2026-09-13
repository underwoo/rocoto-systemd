#!/usr/bin/env bash
#
# loop.sh -- ExecStart for the rocoto-workflow@<instance>.service systemd user unit.
#
# Drives ONE Rocoto workflow with verbose rocotorun on a fixed interval, profiling
# memory of rocotorun + every helper daemon on each pass, and EXITS cleanly once
# the workflow has no Active cycles (or a hard time cap is hit).  A clean exit +
# Restart=on-failure means the service then stays stopped.
#
# Required environment (supplied by EnvironmentFile = ~/.config/rocoto-systemd/<instance>.env):
#   WF  path to the workflow XML
#   DB  path to the workflow sqlite database
#   WD  working directory to cd into before running rocotorun
#
# Optional environment:
#   INSTANCE            nickname for logs/unit     (default: basename of WD)
#   ROCOTO_MODULE       module to load             (default: rocoto)
#   ROCOTO_MODULEPATH   extra `module use` path
#   ROCOTO_BIN          dir with rocoto exes       (bypasses module load)
#   VERBOSITY           rocotorun -v level         (default: 10)
#   INTERVAL            seconds between passes     (default: 300)
#   IDLE_LIMIT          consecutive settled passes before exit (default: 3)
#   MAX_RUNTIME         seconds; exit for cleanup even if not settled (default: 259200 = 3d)
#   MEM_SAMPLE_INTERVAL seconds between memory samples during a pass  (default: 3)
#   SERVICE_LOG         override service log path
#   MEM_LOG            override memory-profile log path

set -u

# cron, scron and `docker exec` can start a script with USER unset; under
# `set -u` the first bare $USER would abort it.
USER="${USER:-$(id -un)}"

SELF_DIR="$(cd "$(dirname "$0")" && pwd)"

fail() { echo "loop.sh: $*" >&2; exit 78; }   # 78 = EX_CONFIG

# --- required vars -----------------------------------------------------
for v in WF DB WD; do
  eval "val=\${$v:-}"
  [ -n "$val" ] || fail "$v is not set (check the EnvironmentFile / --export list)"
done
[ -f "$WF" ] || fail "WF file does not exist: $WF"
[ -d "$WD" ] || fail "WD directory does not exist: $WD"

INSTANCE="${INSTANCE:-$(basename "$WD")}"
VERBOSITY="${VERBOSITY:-10}"
INTERVAL="${INTERVAL:-300}"
IDLE_LIMIT="${IDLE_LIMIT:-3}"
MAX_RUNTIME="${MAX_RUNTIME:-259200}"
MEM_SAMPLE_INTERVAL="${MEM_SAMPLE_INTERVAL:-3}"

LOGDIR="${SELF_DIR}/logs"
mkdir -p "$LOGDIR"
SERVICE_LOG="${SERVICE_LOG:-${LOGDIR}/${INSTANCE}.service.log}"
MEM_LOG="${MEM_LOG:-${LOGDIR}/${INSTANCE}.mem.log}"

# If systemd is NOT already sending our stdout to a regular file (older systemd
# without StandardOutput=append:), append to the service log ourselves.
if [ ! -f /proc/self/fd/1 ]; then
  exec >>"$SERVICE_LOG" 2>&1
fi

# shellcheck disable=SC1091
. "${SELF_DIR}/common.sh" 2>/dev/null || . "${SELF_DIR}/../lib/common.sh"

echo "======================================================================"
echo "$(date)  loop.sh START  instance=$INSTANCE  host=$(hostname)  pid=$$"

# --- node isolation: refuse to run on the wrong node ---------------------
if ! node_pin_ok; then
  fail "instance '$INSTANCE' is pinned to node '${PIN_NODE%%.*}'. Start it there, or clear PIN_NODE in $HOME/.config/rocoto-systemd/${INSTANCE}.env"
fi
[ -n "${PIN_NODE:-}" ] && echo "  PIN_NODE=$PIN_NODE (ok, running on $(hostname -s))"

# --- linger note (non-fatal here; the watchdog enforces it) -------------
if [ "$(linger_state)" != "yes" ]; then
  echo "  NOTE: user lingering is not enabled -- this service will NOT survive logout."
  echo "        Run: loginctl enable-linger $USER"
fi
echo "  WF=$WF"
echo "  DB=$DB"
echo "  WD=$WD"
echo "  VERBOSITY=$VERBOSITY  INTERVAL=$INTERVAL  IDLE_LIMIT=$IDLE_LIMIT  MAX_RUNTIME=$MAX_RUNTIME"
echo "  SERVICE_LOG=$SERVICE_LOG"
echo "  MEM_LOG=$MEM_LOG"

load_rocoto_module || fail "could not put rocoto on PATH"
command -v rocotorun  >/dev/null || fail "rocotorun not found after module load"
command -v rocotostat >/dev/null || fail "rocotostat not found after module load"
echo "  rocotorun  = $(command -v rocotorun)"
echo "  rocotostat = $(command -v rocotostat)"
rocotorun --version 2>&1 | sed 's/^/  /'

cd "$WD" || fail "cd $WD failed"

# cgroup dir for this service (cgroup v2 unified hierarchy)
CG="/sys/fs/cgroup$(awk -F: '{print $3}' /proc/self/cgroup 2>/dev/null)"
echo "  cgroup     = $CG"

if [ ! -e "$MEM_LOG" ]; then
  printf '# ts\ttag\tkind\tpid\tthreads\trss_kb\tpss_kb\tcomm\targs|cgroupinfo\n' >> "$MEM_LOG"
fi

start=$(date +%s)
idle=0
ITER=0

while true; do
  ITER=$((ITER + 1))
  echo "----------------------------------------------------------------------"
  echo "$(date)  iteration $ITER  (idle streak $idle/$IDLE_LIMIT)"

  # best-effort: reset cgroup peak so each pass's peak is meaningful (kernel >= 6.8)
  [ -w "${CG}/memory.peak" ] && echo 0 > "${CG}/memory.peak" 2>/dev/null

  # background memory sampler for the duration of this pass
  SAMPLE_FLAG="$(mktemp "${TMPDIR:-/tmp}/rocoto-mem.${INSTANCE}.XXXXXX")"
  (
    n=0
    while [ -e "$SAMPLE_FLAG" ]; do
      mem_sample "iter${ITER}+$((n * MEM_SAMPLE_INTERVAL))s" "$MEM_LOG" "$CG"
      n=$((n + 1))
      sleep "$MEM_SAMPLE_INTERVAL"
    done
  ) &
  MW=$!

  echo "$(date)  >>> rocotorun -w \"$WF\" -d \"$DB\" -v $VERBOSITY"
  rocotorun -w "$WF" -d "$DB" -v "$VERBOSITY"
  rc=$?
  echo "$(date)  <<< rocotorun exit=$rc"

  # keep sampling a little longer to catch daemons that linger after rocotorun returns
  sleep $((MEM_SAMPLE_INTERVAL * 3))
  rm -f "$SAMPLE_FLAG"
  wait "$MW" 2>/dev/null

  # one authoritative cgroup number from systemd's own accounting
  systemctl --user show "rocoto-workflow@${INSTANCE}.service" \
      -p MemoryCurrent -p MemoryPeak -p TasksCurrent 2>/dev/null \
    | paste -sd' ' - \
    | sed "s#^#$(date '+%Y-%m-%dT%H:%M:%S')\titer${ITER}\tSERVICE\t#" >> "$MEM_LOG" || true

  if rocoto_settled "$WF" "$DB"; then
    idle=$((idle + 1))
    echo "$(date)  workflow appears settled ($idle/$IDLE_LIMIT)"
  else
    idle=0
  fi

  if [ "$idle" -ge "$IDLE_LIMIT" ]; then
    echo "$(date)  workflow settled for $IDLE_LIMIT consecutive checks -- exiting 0"
    rocotostat -w "$WF" -d "$DB" -c ALL -s 2>&1 | sed 's/^/  /' || true
    # If this instance was `enable`d for boot autostart, disable it so a finished
    # workflow does not get relaunched after a reboot.
    if systemctl --user is-enabled --quiet "rocoto-workflow@${INSTANCE}.service" 2>/dev/null; then
      systemctl --user disable "rocoto-workflow@${INSTANCE}.service" 2>/dev/null \
        && echo "$(date)  disabled rocoto-workflow@${INSTANCE}.service (workflow complete)"
    fi
    exit 0
  fi

  now=$(date +%s)
  if [ $((now - start)) -ge "$MAX_RUNTIME" ]; then
    echo "$(date)  MAX_RUNTIME ${MAX_RUNTIME}s reached, workflow NOT settled -- exiting 0 for cleanup"
    rocotostat -w "$WF" -d "$DB" -c ALL -s 2>&1 | sed 's/^/  /' || true
    exit 0
  fi

  echo "$(date)  sleeping ${INTERVAL}s"
  sleep "$INTERVAL"
done
