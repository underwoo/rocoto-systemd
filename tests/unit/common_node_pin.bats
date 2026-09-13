#!/usr/bin/env bats
#
# node_pin_ok -- the check that stops a pinned instance from running a second
# copy on another node.  Pure string logic once `hostname` is stubbed.

setup() {
  load ../helpers/common
  setup_sandbox
  source "$REPO_ROOT/lib/common.sh"
}
teardown() { teardown_sandbox; }

host_is() { # host_is SHORTNAME
  stub hostname <<EOF
echo "$1"
EOF
}

@test "unpinned instance runs anywhere" {
  host_is gaea51
  unset PIN_NODE
  run node_pin_ok
  assert_status 0
}

@test "empty PIN_NODE is treated as unpinned" {
  host_is gaea51
  PIN_NODE=""
  run node_pin_ok
  assert_status 0
}

@test "pin matches this host" {
  host_is gaea51
  PIN_NODE=gaea51
  run node_pin_ok
  assert_status 0
}

@test "pin given as FQDN matches a short hostname" {
  host_is gaea51
  PIN_NODE=gaea51.ncrc.gov
  run node_pin_ok
  assert_status 0
}

@test "pin given as short name matches an FQDN hostname" {
  host_is gaea51.ncrc.gov
  PIN_NODE=gaea51
  run node_pin_ok
  assert_status 0
}

@test "pin to another node fails and says which node" {
  host_is gaea52
  PIN_NODE=gaea51
  run node_pin_ok
  assert_status 1
  assert_contains "$output" "PINNED to node 'gaea51'"
  assert_contains "$output" "this is 'gaea52'"
}

@test "falls back to bare hostname when 'hostname -s' is unsupported" {
  stub hostname <<'EOF'
[ "$1" = "-s" ] && exit 1
echo "gaea51.ncrc.gov"
EOF
  PIN_NODE=gaea51
  run node_pin_ok
  assert_status 0
}
