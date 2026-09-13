#!/usr/bin/env bats
#
# node-guard.sh -- the ExecStartPre that stops `systemctl --user start` on the
# wrong node.  Exit 70 matters: the unit lists it in RestartPreventExitStatus,
# so a wrong-node start must not turn into a restart loop.

setup() {
  load ../helpers/common
  setup_sandbox
  DEST="$(install_tree)"
  GUARD="$DEST/node-guard.sh"
  export INSTANCE=testwf
}
teardown() { teardown_sandbox; }

host_is() {
  stub hostname <<EOF
echo "$1"
EOF
}

@test "unpinned instance is allowed" {
  host_is gaea51
  run "$GUARD"
  assert_status 0
}

@test "pinned to this node is allowed" {
  host_is gaea51
  PIN_NODE=gaea51 run "$GUARD"
  assert_status 0
}

@test "pinned elsewhere exits 70 with remediation" {
  host_is gaea52
  PIN_NODE=gaea51 run "$GUARD"
  assert_status 70
  assert_contains "$output" "refusing to start 'testwf' here"
  assert_contains "$output" "pinned to 'gaea51'"
  assert_contains "$output" "testwf.env"
}

@test "exit 70 is the code the unit refuses to restart on" {
  # Guards the pairing between node-guard.sh and RestartPreventExitStatus.
  grep -q 'RestartPreventExitStatus=.*\b70\b' "$REPO_ROOT/systemd/rocoto-workflow@.service"
}
