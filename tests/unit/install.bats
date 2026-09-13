#!/usr/bin/env bats
#
# install.sh -- flattens bin/ libexec/ lib/ into ~/rocoto-systemd and drops the
# unit into ~/.config/systemd/user.  Must be re-runnable (the README says so)
# and must not eat an existing instance config or its logs on uninstall.

setup() {
  load ../helpers/common
  setup_sandbox
  stub_exit systemctl 0
  stub loginctl <<'EOF'
echo "Linger=yes"
EOF
  DEST="$HOME/rocoto-systemd"
  UNITDIR="$HOME/.config/systemd/user"
  ENVDIR="$HOME/.config/rocoto-systemd"
}
teardown() { teardown_sandbox; }

install_now() { run "$REPO_ROOT/install.sh" </dev/null; }

@test "installs every script flat and executable" {
  install_now
  assert_status 0
  for s in loop.sh node-guard.sh common.sh watchdog.sh summarize-mem.sh new-workflow.sh; do
    [ -x "$DEST/$s" ] || { echo "missing or not executable: $DEST/$s" >&2; return 1; }
  done
}

@test "installs the unit template and creates the log and env directories" {
  install_now
  [ -f "$UNITDIR/rocoto-workflow@.service" ]
  [ -d "$DEST/logs" ]
  [ -d "$ENVDIR" ]
}

@test "the installed layout matches the paths the unit hardcodes" {
  install_now
  # ExecStartPre / ExecStart use %h/rocoto-systemd/<script>
  grep -q 'ExecStartPre=%h/rocoto-systemd/node-guard.sh' "$UNITDIR/rocoto-workflow@.service"
  grep -q 'ExecStart=%h/rocoto-systemd/loop.sh' "$UNITDIR/rocoto-workflow@.service"
  [ -x "$DEST/node-guard.sh" ]
  [ -x "$DEST/loop.sh" ]
}

@test "scripts find common.sh next to themselves in the flattened layout" {
  install_now
  [ -f "$DEST/common.sh" ]
  # loop.sh's sibling-first source must resolve without the repo's lib/ dir.
  run bash -c "SELF_DIR='$DEST'; . \"\$SELF_DIR/common.sh\" && type -t rocoto_settled"
  assert_status 0
  [ "$output" = "function" ]
}

@test "reloads the user manager" {
  install_now
  assert_stub_called "systemctl --user daemon-reload"
}

@test "is idempotent" {
  install_now
  assert_status 0
  install_now
  assert_status 0
  [ -x "$DEST/loop.sh" ]
  [ -f "$UNITDIR/rocoto-workflow@.service" ]
}

@test "warns when lingering is not enabled" {
  stub loginctl <<'EOF'
case "$1" in
  enable-linger) exit 1 ;;
  show-user)     echo "Linger=no" ;;
esac
EOF
  install_now
  assert_status 0
  assert_contains "$output" "an admin must enable it"
}

@test "survives a host with no loginctl at all" {
  stub_exit loginctl 127
  install_now
  assert_status 0
  assert_contains "$output" "Linger=unknown"
}

@test "uninstall removes the scripts and the unit" {
  install_now
  run "$REPO_ROOT/install.sh" --uninstall
  assert_status 0
  [ ! -e "$DEST/loop.sh" ]
  [ ! -e "$UNITDIR/rocoto-workflow@.service" ]
}

@test "uninstall keeps instance configuration and logs" {
  install_now
  echo "WF=/some/wf.xml" > "$ENVDIR/prod.env"
  echo "a log line" > "$DEST/logs/prod.service.log"
  run "$REPO_ROOT/install.sh" --uninstall
  assert_status 0
  [ -f "$ENVDIR/prod.env" ]
  [ -f "$DEST/logs/prod.service.log" ]
}
