#!/usr/bin/env bats
#
# node-guard.sh -- the unit's ExecCondition, which skips a start on the wrong
# node.  The exit code matters: systemd reads 1-254 as "skip" (inactive, never
# restarted) but 255 as "failed", so a wrong node must stay inside 1-254.

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

@test "the wrong-node exit is one ExecCondition treats as a skip" {
  host_is gaea52
  PIN_NODE=gaea51 run "$GUARD"
  [ "$status" -ge 1 ]
  [ "$status" -le 254 ]
  grep -q '^ExecCondition=%h/rocoto-systemd/node-guard.sh' "$REPO_ROOT/systemd/rocoto-workflow@.service"
}
