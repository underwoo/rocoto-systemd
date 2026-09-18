#!/usr/bin/env bats
#
# watchdog.sh -- the optional scron entry point.
#
# Its whole job is a decision: sync the env file, then start / leave alone /
# tear down.  Slurm only ever appears as `scancel $SLURM_JOB_ID`, so a recording
# stub covers it; no Slurm controller is needed to test any of this.

setup() {
  load ../helpers/common
  setup_sandbox
  DEST="$(install_tree)"
  WATCHDOG="$DEST/watchdog.sh"

  export WD="$SANDBOX/work"
  export WF="$WD/workflow.xml"
  export DB="$WD/workflow.db"
  mkdir -p "$WD"
  touch "$WF" "$DB"
  export INSTANCE=testwf
  ENVFILE="$HOME/.config/rocoto-systemd/testwf.env"

  stub hostname <<'EOF'
echo gaea51
EOF
  stub loginctl <<'EOF'
echo "Linger=yes"
EOF
  systemctl_service_is inactive
  rocoto_is Done
}
teardown() { teardown_sandbox; }

# systemctl_service_is active|inactive  -- and record every call.
systemctl_service_is() {
  local state="$1"
  stub systemctl <<EOF
case "\$2" in
  is-active) [ "$state" = active ] && exit 0 || exit 3 ;;
  start)     exit \${SYSTEMCTL_START_RC:-0} ;;
  *)         exit 0 ;;
esac
EOF
}

rocoto_is() {
  export ROCOTO_BIN="$SANDBOX/rocotobin"
  mkdir -p "$ROCOTO_BIN"
  cat > "$ROCOTO_BIN/rocotostat" <<EOF
#!/usr/bin/env bash
printf '%s\n' "rocotostat \$*" >> "\$STUB_LOG"
echo "   CYCLE         STATE           ACTIVATED              DEACTIVATED"
echo "202101010000        $1    Jan 01 2021 00:00:00    Jan 02 2021 00:00:00"
EOF
  printf '#!/usr/bin/env bash\nexit 0\n' > "$ROCOTO_BIN/rocotorun"
  chmod +x "$ROCOTO_BIN/rocotostat" "$ROCOTO_BIN/rocotorun"
}

# --------------------------------------------------------- preconditions ----

@test "missing WF exits 78 and names the fallback env file" {
  unset WF
  run "$WATCHDOG"
  assert_status 78
  assert_contains "$output" "WF not set"
  assert_contains "$output" "$ENVFILE"
}

@test "missing WF recovers from a pre-existing env file (no --export needed)" {
  mkdir -p "$(dirname "$ENVFILE")"
  {
    echo "WF=$WF"
    echo "DB=$DB"
    echo "WD=$WD"
  } > "$ENVFILE"
  unset WF DB WD
  rocoto_is Active
  run "$WATCHDOG"
  assert_status 0
  assert_stub_called "systemctl --user start rocoto-workflow@testwf.service"
}

@test "an explicit WF/DB survives even when WD is missing and the file disagrees" {
  mkdir -p "$(dirname "$ENVFILE")"
  {
    echo "WF=/stale/from-file.xml"
    echo "DB=/stale/from-file.db"
    echo "WD=$WD"
  } > "$ENVFILE"
  unset WD
  rocoto_is Active
  run "$WATCHDOG"
  assert_status 0
  assert_contains "$(cat "$ENVFILE")" "WF=$WF"
  assert_contains "$(cat "$ENVFILE")" "DB=$DB"
  refute_contains "$(cat "$ENVFILE")" "/stale/from-file"
}

@test "PIN_NODE from the persisted file is honored even when WF/DB/WD are already set" {
  mkdir -p "$(dirname "$ENVFILE")"
  echo "PIN_NODE=gaea51" > "$ENVFILE"
  stub hostname <<'EOF'
echo gaea52
EOF
  run "$WATCHDOG"
  assert_status 71
  assert_contains "$output" "wrong node"
  refute_stub_called "systemctl --user start"
}

@test "a shell metacharacter in the persisted file is never executed" {
  mkdir -p "$(dirname "$ENVFILE")"
  MARKER="$SANDBOX/pwned"
  {
    printf 'WF=$(touch %s)\n' "$MARKER"
    echo "DB=$DB"
    echo "WD=$WD"
  } > "$ENVFILE"
  unset WF DB WD
  rocoto_is Active
  run "$WATCHDOG"
  [ ! -e "$MARKER" ]
  assert_contains "$(cat "$ENVFILE")" 'WF=$(touch'
}

@test "wrong node exits 71 and suggests --nodelist" {
  stub hostname <<'EOF'
echo gaea52
EOF
  export PIN_NODE=gaea51
  run "$WATCHDOG"
  assert_status 71
  assert_contains "$output" "wrong node"
  assert_contains "$output" "#SCRON --nodelist=gaea51"
  refute_stub_called "systemctl --user start"
}

@test "gives up when lingering cannot be enabled" {
  stub loginctl <<'EOF'
case "$1" in
  enable-linger) exit 1 ;;
  show-user)     echo "Linger=no" ;;
esac
EOF
  run "$WATCHDOG"
  assert_status 1
  refute_stub_called "systemctl --user start"
}

@test "gives up when the user manager never becomes responsive" {
  stub sleep <<'EOF'
exit 0
EOF
  stub_exit systemctl 1
  run "$WATCHDOG"
  assert_status 1
  assert_contains "$output" "not responsive"
}

@test "the not-responsive hint survives an unset USER" {
  stub sleep <<'EOF'
exit 0
EOF
  stub_exit systemctl 1
  run env -u USER "$WATCHDOG"
  assert_status 1
  assert_contains "$output" "loginctl user-status $(id -un)"
}

# ------------------------------------------------------------- env file ----

@test "writes the EnvironmentFile from the exported variables" {
  export PIN_NODE=gaea51 VERBOSITY=5 INTERVAL=120
  rocoto_is Active
  run "$WATCHDOG"
  assert_status 0
  [ -f "$ENVFILE" ]
  assert_contains "$(cat "$ENVFILE")" "WF=$WF"
  assert_contains "$(cat "$ENVFILE")" "DB=$DB"
  assert_contains "$(cat "$ENVFILE")" "WD=$WD"
  assert_contains "$(cat "$ENVFILE")" "INSTANCE=testwf"
  assert_contains "$(cat "$ENVFILE")" "PIN_NODE=gaea51"
  assert_contains "$(cat "$ENVFILE")" "VERBOSITY=5"
  assert_contains "$(cat "$ENVFILE")" "INTERVAL=120"
}

@test "omits optional variables that are not exported" {
  rocoto_is Active
  run "$WATCHDOG"
  assert_status 0
  [ -f "$ENVFILE" ]
  refute_contains "$(cat "$ENVFILE")" "PIN_NODE="
  refute_contains "$(cat "$ENVFILE")" "VERBOSITY="
}

@test "leaves no temporary env file behind" {
  rocoto_is Active
  run "$WATCHDOG"
  [ -f "$ENVFILE" ]
  [ ! -e "${ENVFILE}.tmp" ]
}

@test "rewrites a stale env file on every pass" {
  mkdir -p "$(dirname "$ENVFILE")"
  echo "WF=/old/stale.xml" > "$ENVFILE"
  rocoto_is Active
  run "$WATCHDOG"
  assert_status 0
  refute_contains "$(cat "$ENVFILE")" "/old/stale.xml"
}

# ------------------------------------------------------------- decision ----

@test "not running and not settled -> starts the unit" {
  rocoto_is Active
  run "$WATCHDOG"
  assert_status 0
  assert_stub_called "systemctl --user start rocoto-workflow@testwf.service"
  assert_contains "$output" "started rocoto-workflow@testwf.service"
}

@test "already running -> does nothing" {
  rocoto_is Active
  systemctl_service_is active
  run "$WATCHDOG"
  assert_status 0
  assert_contains "$output" "nothing to do"
  refute_stub_called "systemctl --user start"
}

@test "failing start is reported as an error" {
  rocoto_is Active
  export SYSTEMCTL_START_RC=1
  run "$WATCHDOG"
  assert_status 1
  assert_contains "$output" "failed to start"
}

@test "settled -> stops the unit and scancels its own scron job" {
  systemctl_service_is active
  export SLURM_JOB_ID=12345
  stub_exit scancel 0
  run "$WATCHDOG"
  assert_status 0
  assert_contains "$output" "workflow SETTLED"
  assert_stub_called "systemctl --user stop rocoto-workflow@testwf.service"
  assert_stub_called "systemctl --user reset-failed rocoto-workflow@testwf.service"
  assert_stub_called "scancel 12345"
  refute_stub_called "systemctl --user start"
}

@test "settled outside Slurm -> stops the unit but does not scancel" {
  unset SLURM_JOB_ID
  stub_exit scancel 0
  run "$WATCHDOG"
  assert_status 0
  assert_stub_called "systemctl --user stop rocoto-workflow@testwf.service"
  refute_stub_called "scancel"
}

@test "unreadable rocoto state never counts as settled" {
  # A broken module load must leave the workflow running, not tear it down.
  export ROCOTO_BIN="$SANDBOX/empty"
  mkdir -p "$ROCOTO_BIN"
  stub_exit scancel 0
  run "$WATCHDOG"
  refute_stub_called "scancel"
  assert_stub_called "systemctl --user start rocoto-workflow@testwf.service"
}
