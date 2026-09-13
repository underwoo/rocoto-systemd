#!/usr/bin/env bats
#
# Static assertions about rocoto-workflow@.service.
#
# These are grep-level checks, not systemd semantics -- the live tier proves the
# behaviour.  What they guard is the seams: the unit hardcodes paths and exit
# codes that four separate shell scripts also hardcode, and nothing else in the
# repo notices when one side moves.

setup() {
  load ../helpers/common
  setup_sandbox
  UNITFILE="$REPO_ROOT/systemd/rocoto-workflow@.service"
}
teardown() { teardown_sandbox; }

@test "it is a template unit with an Install section" {
  [ -f "$UNITFILE" ]
  grep -q '^\[Install\]' "$UNITFILE"
  grep -q '^WantedBy=default.target' "$UNITFILE"
}

@test "the EnvironmentFile path is the one new-workflow.sh and watchdog.sh write" {
  grep -q '^EnvironmentFile=%h/.config/rocoto-systemd/%i.env' "$UNITFILE"
  grep -q 'ENVDIR="\${HOME}/.config/rocoto-systemd"' "$REPO_ROOT/bin/new-workflow.sh"
  grep -q 'ENVDIR="\${HOME}/.config/rocoto-systemd"' "$REPO_ROOT/bin/watchdog.sh"
  grep -q 'ENVDIR="\${HOME}/.config/rocoto-systemd"' "$REPO_ROOT/install.sh"
}

@test "the log path is the one install.sh creates and the README documents" {
  grep -q '^StandardOutput=append:%h/rocoto-systemd/logs/%i.service.log' "$UNITFILE"
  grep -q '^StandardError=append:%h/rocoto-systemd/logs/%i.service.log' "$UNITFILE"
  grep -q 'mkdir -p "\$DEST/logs"' "$REPO_ROOT/install.sh"
}

@test "a clean exit leaves the service stopped" {
  # Restart=always here would relaunch a finished workflow forever.
  grep -q '^Restart=on-failure' "$UNITFILE"
}

@test "both deliberate failure codes are exempt from restart" {
  # 70 = node-guard.sh wrong node, 78 = loop.sh bad config.  Restarting either
  # just repeats the same failure until StartLimitBurst trips.
  line="$(grep '^RestartPreventExitStatus=' "$UNITFILE")"
  assert_contains "$line" "70"
  assert_contains "$line" "78"
  grep -q 'exit 70' "$REPO_ROOT/libexec/node-guard.sh"
  grep -q 'exit 78' "$REPO_ROOT/libexec/loop.sh"
}

@test "accounting is on, so the memory profile has cgroup numbers" {
  grep -q '^MemoryAccounting=yes' "$UNITFILE"
  grep -q '^TasksAccounting=yes' "$UNITFILE"
}

@test "resource backstops are set and MemoryHigh is below MemoryMax" {
  high="$(sed -n 's/^MemoryHigh=\([0-9]*\)G/\1/p' "$UNITFILE")"
  max="$(sed -n 's/^MemoryMax=\([0-9]*\)G/\1/p' "$UNITFILE")"
  [ -n "$high" ] && [ -n "$max" ]
  [ "$high" -lt "$max" ]
}

@test "every executable the unit names is installed by install.sh" {
  DEST="$(install_tree)"
  while read -r path; do
    script="${path##*/}"
    [ -x "$DEST/$script" ] || { echo "unit runs $path but install.sh never places $script" >&2; return 1; }
  done < <(sed -n 's/^Exec[A-Za-z]*=\(%h[^ ]*\).*/\1/p' "$UNITFILE")
}
