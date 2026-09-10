# shellcheck shell=bash
#
# Shared helpers for loop.sh (systemd ExecStart) and watchdog.sh (scron).
# Source this file; it defines functions only.

# ----------------------------------------------------------------------
# load_rocoto_module
#   Make `rocotorun` / `rocotostat` available on PATH.
#   Honors (in priority order):
#     ROCOTO_BIN        - dir containing the rocoto executables (skips modules)
#     ROCOTO_MODULEPATH - extra `module use` path
#     ROCOTO_MODULE     - module name to load (default: rocoto)
# ----------------------------------------------------------------------
load_rocoto_module() {
  if command -v rocotorun >/dev/null 2>&1 && command -v rocotostat >/dev/null 2>&1; then
    return 0
  fi

  if [ -n "${ROCOTO_BIN:-}" ]; then
    PATH="${ROCOTO_BIN}:${PATH}"
    export PATH
    command -v rocotorun >/dev/null 2>&1 && return 0
  fi

  # Make the `module` function available if it isn't already.
  if ! command -v module >/dev/null 2>&1; then
    for f in /etc/profile.d/lmod.sh /etc/profile.d/modules.sh \
             /usr/share/lmod/lmod/init/bash /usr/share/Modules/init/bash \
             /opt/cray/pe/lmod/lmod/init/bash; do
      # shellcheck disable=SC1090
      [ -r "$f" ] && . "$f" && break
    done
  fi
  if ! command -v module >/dev/null 2>&1; then
    echo "common.sh: 'module' not available and ROCOTO_BIN not set" >&2
    return 1
  fi

  [ -n "${ROCOTO_MODULEPATH:-}" ] && module use "$ROCOTO_MODULEPATH"
  module load "${ROCOTO_MODULE:-rocoto}" || {
    echo "common.sh: 'module load ${ROCOTO_MODULE:-rocoto}' failed" >&2
    return 1
  }
  command -v rocotorun >/dev/null 2>&1
}

# ----------------------------------------------------------------------
# linger_state  -> prints "yes" / "no" / "" (unknown)
# ----------------------------------------------------------------------
linger_state() {
  loginctl show-user "${USER:-$(id -un)}" -p Linger 2>/dev/null | sed -n 's/^Linger=//p'
}

# ----------------------------------------------------------------------
# ensure_linger
#   Return 0 if user lingering is (or becomes) enabled.
#   Otherwise print a clear error and return 1.
# ----------------------------------------------------------------------
ensure_linger() {
  local u="${USER:-$(id -un)}" st
  st="$(linger_state)"
  [ "$st" = "yes" ] && return 0

  echo "linger is not enabled for $u; attempting: loginctl enable-linger $u" >&2
  loginctl enable-linger "$u" >/dev/null 2>&1 || true
  st="$(linger_state)"
  if [ "$st" = "yes" ]; then
    echo "linger enabled for $u" >&2
    return 0
  fi

  cat >&2 <<EOF

ERROR: user lingering is NOT enabled for $u and could not be enabled automatically.

  Without lingering, the systemd --user service is killed when the session that
  started it ends -- exactly the failure this setup exists to avoid.

  Enable it (may require administrator approval on this system):

      loginctl enable-linger $u
      loginctl show-user $u -p Linger        # expect: Linger=yes

EOF
  return 1
}

# ----------------------------------------------------------------------
# wait_user_manager  -> 0 once `systemctl --user` is responsive, else 1
#   (the per-user manager can take a moment to come up after enable-linger)
# ----------------------------------------------------------------------
wait_user_manager() {
  local i
  for i in $(seq 1 15); do
    systemctl --user show --property=Version >/dev/null 2>&1 && return 0
    sleep 1
  done
  return 1
}

# ----------------------------------------------------------------------
# node_pin_ok
#   0 if PIN_NODE is unset/empty, or matches this host's short name.
#   1 (with a message on stderr) if pinned to a different node.
# ----------------------------------------------------------------------
node_pin_ok() {
  local want="${PIN_NODE:-}" here
  [ -z "$want" ] && return 0
  want="${want%%.*}"
  here="$(hostname -s 2>/dev/null || hostname)"; here="${here%%.*}"
  [ "$here" = "$want" ] && return 0
  echo "This workflow instance is PINNED to node '$want', but this is '$here'." >&2
  return 1
}

# ----------------------------------------------------------------------
# rocoto_settled WF DB
#   Exit 0 (true) when at least one cycle exists and NONE are Active,
#   i.e. nothing more will happen without human intervention.
#   Exit 1 on any doubt (rocotostat error, no cycles yet, an Active cycle).
# ----------------------------------------------------------------------
rocoto_settled() {
  local wf="$1" db="$2" out
  out=$(rocotostat -w "$wf" -d "$db" -c ALL -s 2>/dev/null) || return 1
  printf '%s\n' "$out" | awk '
    NR > 1 && NF >= 2 { seen++; if ($2 == "Active") active++ }
    END { if (seen + 0 == 0) exit 1; exit (active + 0 > 0) ? 1 : 0 }'
}

# ----------------------------------------------------------------------
# mem_sample TAG MEM_LOG CGROUP_DIR
#   Append one memory snapshot (one PROC line per process, one TOTAL line)
#   for every process in the service cgroup: RSS, PSS, thread count.
#   Columns (tab separated):
#     ts  tag  PROC   pid       threads rss_kb pss_kb comm    args
#     ts  tag  TOTAL  -         -       rss_kb pss_kb cgroup_current=..  cgroup_peak=..
# ----------------------------------------------------------------------
mem_sample() {
  local tag="$1" mlog="$2" cg="$3"
  local ts pid comm args rss pss nlwp sum_rss=0 sum_pss=0 procs
  ts=$(date '+%Y-%m-%dT%H:%M:%S')

  if [ -r "${cg}/cgroup.procs" ]; then
    procs=$(cat "${cg}/cgroup.procs" 2>/dev/null)
  else
    procs=$(pgrep -u "$(id -u)" -f 'rocoto(run|bqserver|ioserver|dbserver)' 2>/dev/null)
  fi

  for pid in $procs; do
    [ -d "/proc/$pid" ] || continue
    comm=$(cat "/proc/$pid/comm" 2>/dev/null) || continue
    args=$(tr '\0' ' ' < "/proc/$pid/cmdline" 2>/dev/null | sed 's/[[:space:]]*$//' | cut -c1-160)
    [ -n "$args" ] || args="$comm"
    rss=$(awk '/^VmRSS:/{print $2}'   "/proc/$pid/status" 2>/dev/null)
    nlwp=$(awk '/^Threads:/{print $2}' "/proc/$pid/status" 2>/dev/null)
    pss=$(awk '/^Pss:/{s+=$2} END{print s+0}' "/proc/$pid/smaps_rollup" 2>/dev/null)
    [ -n "$rss" ] || continue
    sum_rss=$((sum_rss + rss))
    sum_pss=$((sum_pss + ${pss:-0}))
    printf '%s\t%s\tPROC\t%s\t%s\t%s\t%s\t%s\t%s\n' \
      "$ts" "$tag" "$pid" "${nlwp:-0}" "$rss" "${pss:-0}" "$comm" "$args" >> "$mlog"
  done

  local cur peak
  cur=$(cat "${cg}/memory.current" 2>/dev/null)
  peak=$(cat "${cg}/memory.peak"    2>/dev/null)
  printf '%s\t%s\tTOTAL\t-\t-\t%s\t%s\tcgroup_current=%s\tcgroup_peak=%s\n' \
    "$ts" "$tag" "$sum_rss" "$sum_pss" "${cur:-NA}" "${peak:-NA}" >> "$mlog"
}
