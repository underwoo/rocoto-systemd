#!/usr/bin/env bats
#
# loop.sh -- the unit's ExecStart.
#
# Two groups:
#   * config validation (exit 78 = EX_CONFIG, also in RestartPreventExitStatus)
#   * one full pass of the drive loop against a stubbed rocotorun/rocotostat
#
# No systemd and no Slurm involved: every systemctl call in loop.sh is either
# guarded or `|| true`, so a recording stub is enough.

setup() {
  load ../helpers/common
  setup_sandbox
  DEST="$(install_tree)"
  LOOP="$DEST/loop.sh"

  export WD="$SANDBOX/work"
  export WF="$WD/workflow.xml"
  export DB="$WD/workflow.db"
  mkdir -p "$WD"
  touch "$WF" "$DB"
  export INSTANCE=testwf

  # loop.sh reopens stdout onto SERVICE_LOG whenever fd 1 is not a regular file
  # (which is always the case under a test harness), so assert on the file.
  export SERVICE_LOG="$SANDBOX/service.log"
  export MEM_LOG="$SANDBOX/mem.log"

  # Keep a pass short: sampler tick, then the 3x settle wait after rocotorun.
  export INTERVAL=1 MEM_SAMPLE_INTERVAL=1 IDLE_LIMIT=1

  stub hostname <<'EOF'
echo gaea51
EOF
  stub loginctl <<'EOF'
echo "Linger=yes"
EOF
}
teardown() { teardown_sandbox; }

svclog() { cat "$SERVICE_LOG" 2>/dev/null; }

# rocoto_is <state>  -- install stub rocotorun/rocotostat reporting one cycle.
rocoto_is() {
  export ROCOTO_BIN="$SANDBOX/rocotobin"
  mkdir -p "$ROCOTO_BIN"
  cat > "$ROCOTO_BIN/rocotorun" <<EOF
#!/usr/bin/env bash
printf '%s\n' "rocotorun \$*" >> "\$STUB_LOG"
[ "\$1" = "--version" ] && echo "Rocoto 1.3.7 (stub)"
exit 0
EOF
  cat > "$ROCOTO_BIN/rocotostat" <<EOF
#!/usr/bin/env bash
printf '%s\n' "rocotostat \$*" >> "\$STUB_LOG"
echo "   CYCLE         STATE           ACTIVATED              DEACTIVATED"
echo "202101010000        $1    Jan 01 2021 00:00:00    Jan 02 2021 00:00:00"
exit 0
EOF
  chmod +x "$ROCOTO_BIN/rocotorun" "$ROCOTO_BIN/rocotostat"
}

# ---------------------------------------------------------------- config ----

@test "missing WF exits 78" {
  unset WF
  run "$LOOP"
  assert_status 78
  assert_contains "$output" "WF is not set"
}

@test "missing DB exits 78" {
  unset DB
  run "$LOOP"
  assert_status 78
  assert_contains "$output" "DB is not set"
}

@test "missing WD exits 78" {
  unset WD
  run "$LOOP"
  assert_status 78
  assert_contains "$output" "WD is not set"
}

@test "nonexistent workflow XML exits 78" {
  export WF="$SANDBOX/nope.xml"
  run "$LOOP"
  assert_status 78
  assert_contains "$output" "WF file does not exist"
}

@test "nonexistent working directory exits 78" {
  export WD="$SANDBOX/nodir"
  run "$LOOP"
  assert_status 78
  assert_contains "$output" "WD directory does not exist"
}

@test "exit 78 is the code the unit refuses to restart on" {
  grep -q 'RestartPreventExitStatus=.*\b78\b' "$REPO_ROOT/systemd/rocoto-workflow@.service"
}

@test "refuses to run when pinned to another node" {
  stub hostname <<'EOF'
echo gaea52
EOF
  export PIN_NODE=gaea51
  run "$LOOP"
  assert_status 78
  assert_contains "$(svclog)" "pinned to node 'gaea51'"
}

@test "exits 78 when rocoto cannot be put on PATH" {
  export ROCOTO_BIN="$SANDBOX/empty"
  mkdir -p "$ROCOTO_BIN"
  run "$LOOP"
  assert_status 78
  assert_contains "$(svclog)" "could not put rocoto on PATH"
}

@test "warns but continues when lingering is off" {
  stub loginctl <<'EOF'
echo "Linger=no"
EOF
  rocoto_is Done
  stub_exit systemctl 1
  run "$LOOP"
  assert_status 0
  assert_contains "$(svclog)" "lingering is not enabled"
}

@test "the lingering warning survives an unset USER" {
  stub loginctl <<'EOF'
echo "Linger=no"
EOF
  rocoto_is Done
  stub_exit systemctl 1
  run env -u USER "$LOOP"
  assert_status 0
  assert_contains "$(svclog)" "loginctl enable-linger $(id -un)"
}

# ------------------------------------------------------------------ loop ----

@test "settled workflow: one pass, clean exit, rocotorun actually called" {
  rocoto_is Done
  stub_exit systemctl 1          # is-enabled says "not enabled"
  run "$LOOP"
  assert_status 0
  assert_stub_called "rocotorun -w $WF -d $DB -v 10"
  assert_contains "$(svclog)" "workflow settled for 1 consecutive checks"
  refute_stub_called "systemctl --user disable"
}

@test "settled workflow disables an enabled unit so a reboot does not relaunch it" {
  rocoto_is Done
  stub systemctl <<'EOF'
[ "$2" = "is-enabled" ] && exit 0
exit 0
EOF
  run "$LOOP"
  assert_status 0
  assert_stub_called "systemctl --user disable rocoto-workflow@testwf.service"
  assert_contains "$(svclog)" "workflow complete"
}

@test "active workflow keeps looping until MAX_RUNTIME" {
  rocoto_is Active
  stub_exit systemctl 1
  export MAX_RUNTIME=0
  run "$LOOP"
  assert_status 0
  assert_contains "$(svclog)" "MAX_RUNTIME 0s reached, workflow NOT settled"
}

@test "IDLE_LIMIT requires consecutive settled passes" {
  # Settled, then active, then settled: must not exit on the first observation.
  export IDLE_LIMIT=2 MAX_RUNTIME=0
  rocoto_is Done
  stub_exit systemctl 1
  run "$LOOP"
  assert_status 0
  assert_contains "$(svclog)" "workflow appears settled (1/2)"
  assert_contains "$(svclog)" "MAX_RUNTIME"
}

@test "writes a memory log with a header and a TOTAL row" {
  rocoto_is Done
  stub_exit systemctl 1
  run "$LOOP"
  assert_status 0
  [ -s "$MEM_LOG" ]
  assert_contains "$(head -1 "$MEM_LOG")" "rss_kb"
  grep -q $'\tTOTAL\t' "$MEM_LOG"
}

@test "INSTANCE defaults to the basename of WD" {
  unset INSTANCE
  rocoto_is Done
  stub_exit systemctl 1
  run "$LOOP"
  assert_status 0
  assert_contains "$(svclog)" "instance=work"
}
