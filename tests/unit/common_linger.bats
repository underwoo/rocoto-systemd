#!/usr/bin/env bats
#
# linger_state / ensure_linger / wait_user_manager.
#
# Lingering is the single prerequisite for unattended operation: without it the
# user manager (and the service) dies at logout.  These tests stub `loginctl`
# and `systemctl` so the decision logic is exercised on any OS.

setup() {
  load ../helpers/common
  setup_sandbox
  source "$REPO_ROOT/lib/common.sh"
  export USER=testuser
}
teardown() { teardown_sandbox; }

@test "linger_state reports yes" {
  stub loginctl <<'EOF'
echo "Linger=yes"
EOF
  run linger_state
  assert_status 0
  [ "$output" = "yes" ]
}

@test "linger_state reports no" {
  stub loginctl <<'EOF'
echo "Linger=no"
EOF
  run linger_state
  [ "$output" = "no" ]
}

@test "linger_state is empty when loginctl fails" {
  stub_exit loginctl 1
  run linger_state
  [ "$output" = "" ]
}

@test "ensure_linger succeeds without touching anything when already lingering" {
  stub loginctl <<'EOF'
echo "Linger=yes"
EOF
  run ensure_linger
  assert_status 0
  refute_stub_called "loginctl enable-linger"
}

@test "ensure_linger enables lingering when it can" {
  # First show-user says no; after enable-linger, say yes.
  stub loginctl <<'EOF'
flag="$SANDBOX/linger-enabled"
case "$1" in
  enable-linger) : > "$flag" ;;
  show-user)     [ -e "$flag" ] && echo "Linger=yes" || echo "Linger=no" ;;
esac
EOF
  run ensure_linger
  assert_status 0
  assert_stub_called "loginctl enable-linger testuser"
  assert_contains "$output" "linger enabled for testuser"
}

@test "ensure_linger fails loudly with remediation when it cannot enable" {
  stub loginctl <<'EOF'
case "$1" in
  enable-linger) exit 1 ;;
  show-user)     echo "Linger=no" ;;
esac
EOF
  run ensure_linger
  assert_status 1
  assert_contains "$output" "user lingering is NOT enabled"
  assert_contains "$output" "loginctl enable-linger testuser"
}

@test "ensure_linger fails when loginctl is absent (non-systemd host)" {
  stub_exit loginctl 127
  run ensure_linger
  assert_status 1
  assert_contains "$output" "NOT enabled"
}

@test "wait_user_manager returns as soon as systemctl answers" {
  stub_exit systemctl 0
  run wait_user_manager
  assert_status 0
  assert_stub_called "systemctl --user show --property=Version"
}

@test "wait_user_manager gives up when the user manager never comes up" {
  stub_exit systemctl 1
  # Neutralise the retry backoff so the give-up path is fast.
  sleep() { :; }
  run wait_user_manager
  assert_status 1
  [ "$(grep -c '^systemctl' "$STUB_LOG")" -eq 15 ]
}
