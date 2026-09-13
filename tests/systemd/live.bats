#!/usr/bin/env bats
#
# Integration tier: exercises the unit file against a REAL `systemctl --user`.
#
# This is the only tier that can prove the things a stub cannot:
#   * EnvironmentFile=%h/.config/rocoto-systemd/%i.env actually resolves
#   * an ExecCondition skip blocks ExecStart without failing or restarting
#   * RestartPreventExitStatus=78 really does suppress the restart
#   * StandardOutput=append: works (needs systemd >= 240)
#   * MemoryAccounting=yes produces the numbers summarize-mem.sh reports
#   * loop.sh's self-`disable` clears the boot autostart
#
# It installs into the REAL $HOME, because systemd's %h is the manager's idea of
# the home directory and cannot be redirected per-test.  So it is opt-in:
#
#     ROCOTO_SYSTEMD_LIVE_TESTS=1 tests/run.sh
#
# CI and the devcontainer set that; a workstation will skip the whole file.

INSTANCE=citest
UNIT="rocoto-workflow@${INSTANCE}.service"
PINNED_INSTANCE=cipinned
PINNED_UNIT="rocoto-workflow@${PINNED_INSTANCE}.service"

setup_file() {
  export ROCOTO_CI_STUB="$HOME/.cache/rocoto-systemd-citest/bin"
  export ROCOTO_CI_WORK="$HOME/.cache/rocoto-systemd-citest/work"
}

setup() {
  load ../helpers/common
  REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/../.." && pwd)"

  [ "${ROCOTO_SYSTEMD_LIVE_TESTS:-}" = "1" ] \
    || skip "set ROCOTO_SYSTEMD_LIVE_TESTS=1 to run the live systemd tier"
  command -v systemctl >/dev/null 2>&1 || skip "no systemctl on this host"
  systemctl --user show --property=Version >/dev/null 2>&1 \
    || skip "no responsive 'systemctl --user' (needs a user manager + XDG_RUNTIME_DIR)"

  export ROCOTO_CI_STUB="$HOME/.cache/rocoto-systemd-citest/bin"
  export ROCOTO_CI_WORK="$HOME/.cache/rocoto-systemd-citest/work"
}

teardown() {
  [ "${ROCOTO_SYSTEMD_LIVE_TESTS:-}" = "1" ] || return 0
  systemctl --user stop "$UNIT" "$PINNED_UNIT" 2>/dev/null || true
  systemctl --user disable "$UNIT" "$PINNED_UNIT" 2>/dev/null || true
  systemctl --user reset-failed "$UNIT" "$PINNED_UNIT" 2>/dev/null || true
}

# ----------------------------------------------------------------------
# Fixture: a stub rocoto whose settled-ness we control, plus an env file.
# ----------------------------------------------------------------------
make_stub_rocoto() { # make_stub_rocoto Done|Active
  mkdir -p "$ROCOTO_CI_STUB" "$ROCOTO_CI_WORK"
  touch "$ROCOTO_CI_WORK/workflow.xml" "$ROCOTO_CI_WORK/workflow.db"
  cat > "$ROCOTO_CI_STUB/rocotorun" <<'EOF'
#!/usr/bin/env bash
[ "$1" = "--version" ] && { echo "Rocoto 0.0.0 (ci stub)"; exit 0; }
# Burn a little memory so MemoryAccounting has something to report.
python3 -c 'x = bytearray(32 * 1024 * 1024); print(len(x))' >/dev/null 2>&1 || sleep 1
exit 0
EOF
  cat > "$ROCOTO_CI_STUB/rocotostat" <<EOF
#!/usr/bin/env bash
echo "   CYCLE         STATE           ACTIVATED              DEACTIVATED"
echo "202101010000        $1    Jan 01 2021 00:00:00    Jan 02 2021 00:00:00"
EOF
  chmod +x "$ROCOTO_CI_STUB/rocotorun" "$ROCOTO_CI_STUB/rocotostat"
}

write_env() { # write_env INSTANCE [extra lines...]
  local inst="$1"; shift
  mkdir -p "$HOME/.config/rocoto-systemd"
  {
    echo "WF=$ROCOTO_CI_WORK/workflow.xml"
    echo "DB=$ROCOTO_CI_WORK/workflow.db"
    echo "WD=$ROCOTO_CI_WORK"
    echo "INSTANCE=$inst"
    echo "ROCOTO_BIN=$ROCOTO_CI_STUB"
    echo "INTERVAL=1"
    echo "MEM_SAMPLE_INTERVAL=1"
    echo "IDLE_LIMIT=1"
    printf '%s\n' "$@"
  } > "$HOME/.config/rocoto-systemd/${inst}.env"
}

install_and_reload() {
  "$REPO_ROOT/install.sh" </dev/null >/dev/null
  systemctl --user daemon-reload
}

wait_inactive() { # wait_inactive UNIT [seconds]
  local unit="$1" n="${2:-120}"
  while [ "$n" -gt 0 ]; do
    systemctl --user is-active --quiet "$unit" || return 0
    n=$((n - 1))
    sleep 1
  done
  echo "timed out waiting for $unit to stop" >&2
  return 1
}

prop() { systemctl --user show "$1" -p "$2" --value; }

# assert_prop UNIT PROPERTY EXPECTED -- on mismatch, say what systemd reported.
assert_prop() {
  local got
  got="$(prop "$1" "$2")"
  [ "$got" = "$3" ] && return 0
  echo "$1: expected $2=$3, got '$got'" >&2
  systemctl --user status --no-pager "$1" >&2 || true
  return 1
}

# ------------------------------------------------------------------ tests ---

@test "the unit file passes systemd-analyze verify" {
  command -v systemd-analyze >/dev/null 2>&1 || skip "no systemd-analyze"
  install_and_reload
  run systemd-analyze --user verify "$UNIT"
  if [ "$status" -ne 0 ]; then
    echo "$output" >&2
    return 1
  fi
}

@test "the unit loads and resolves its EnvironmentFile" {
  make_stub_rocoto Done
  write_env "$INSTANCE"
  install_and_reload
  [ "$(prop "$UNIT" LoadState)" = "loaded" ]
  run systemctl --user cat "$UNIT"
  assert_status 0
  assert_contains "$output" "EnvironmentFile="
}

@test "a settled workflow runs to a clean stop" {
  make_stub_rocoto Done
  write_env "$INSTANCE"
  install_and_reload
  systemctl --user reset-failed "$UNIT" 2>/dev/null || true
  systemctl --user start "$UNIT"
  wait_inactive "$UNIT"
  [ "$(prop "$UNIT" Result)" = "success" ]
  [ "$(prop "$UNIT" ExecMainStatus)" = "0" ]
  [ "$(prop "$UNIT" NRestarts)" = "0" ]
}

@test "StandardOutput=append: writes the service log the docs point at" {
  log="$HOME/rocoto-systemd/logs/${INSTANCE}.service.log"
  rm -f "$log"
  make_stub_rocoto Done
  write_env "$INSTANCE"
  install_and_reload
  systemctl --user start "$UNIT"
  wait_inactive "$UNIT"
  [ -s "$log" ]
  grep -q "loop.sh START" "$log"
  grep -q "workflow settled" "$log"
}

@test "memory accounting produces a profile summarize-mem.sh can read" {
  memlog="$HOME/rocoto-systemd/logs/${INSTANCE}.mem.log"
  rm -f "$memlog"
  make_stub_rocoto Done
  write_env "$INSTANCE"
  install_and_reload
  systemctl --user start "$UNIT"
  wait_inactive "$UNIT"
  [ -s "$memlog" ]
  grep -q $'\tTOTAL\t' "$memlog"
  # cgroup numbers, not the /proc fallback: proves MemoryAccounting=yes took effect.
  grep -q 'cgroup_current=[0-9]' "$memlog"
  run "$HOME/rocoto-systemd/summarize-mem.sh" "$memlog"
  assert_status 0
  assert_contains "$output" "peakRSS_MB"
}

@test "a finished workflow disables its own boot autostart" {
  make_stub_rocoto Done
  write_env "$INSTANCE"
  install_and_reload
  systemctl --user enable "$UNIT"
  [ "$(systemctl --user is-enabled "$UNIT")" = "enabled" ]
  systemctl --user start "$UNIT"
  wait_inactive "$UNIT"
  [ "$(systemctl --user is-enabled "$UNIT" 2>/dev/null)" != "enabled" ]
}

@test "a wrong-node start is skipped: inactive, not failed, no restart queued" {
  make_stub_rocoto Active
  write_env "$PINNED_INSTANCE" "PIN_NODE=definitely-not-this-host"
  log="$HOME/rocoto-systemd/logs/${PINNED_INSTANCE}.service.log"
  rm -f "$log"
  install_and_reload
  systemctl --user reset-failed "$PINNED_UNIT" 2>/dev/null || true
  systemctl --user start "$PINNED_UNIT" || true
  wait_inactive "$PINNED_UNIT"
  # Not Result=exec-condition: a skipped unit is inactive, and systemd unloads
  # inactive units (CollectMode=inactive, the default), so by the next `show`
  # it reports a freshly loaded unit's defaults.  What does survive: a failed
  # unit stays "failed", and a queued restart holds it in activating /
  # auto-restart for all of RestartSec -- so "inactive" + "dead" rules out both.
  assert_prop "$PINNED_UNIT" ActiveState inactive
  assert_prop "$PINNED_UNIT" SubState dead
  assert_prop "$PINNED_UNIT" NRestarts 0
  # The guard ran and said why; loop.sh never started.
  grep -q "refusing to start" "$log"
  if grep -q "loop.sh START" "$log"; then
    echo "loop.sh ran on the wrong node" >&2
    return 1
  fi
}

@test "a bad EnvironmentFile fails with 78 and does not restart-loop" {
  mkdir -p "$HOME/.config/rocoto-systemd"
  printf 'WF=/nonexistent/workflow.xml\nDB=/tmp/x.db\nWD=/nonexistent\nINSTANCE=%s\n' \
    "$PINNED_INSTANCE" > "$HOME/.config/rocoto-systemd/${PINNED_INSTANCE}.env"
  install_and_reload
  systemctl --user reset-failed "$PINNED_UNIT" 2>/dev/null || true
  systemctl --user start "$PINNED_UNIT" || true
  wait_inactive "$PINNED_UNIT"
  assert_prop "$PINNED_UNIT" ExecMainStatus 78
  # "failed", not "activating (auto-restart)": no restart is queued.
  assert_prop "$PINNED_UNIT" ActiveState failed
  assert_prop "$PINNED_UNIT" NRestarts 0
}
