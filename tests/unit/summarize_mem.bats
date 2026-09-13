#!/usr/bin/env bats
#
# summarize-mem.sh -- pure awk over a mem.log.  The numbers it prints are what a
# user quotes when asking for a MemoryMax bump, so the peak-picking arithmetic
# is worth pinning down.
#
# Fixture: rocotorun peaks at 102400 kB RSS / 51200 kB PSS / 8 threads,
#          ruby      peaks at 409600 kB RSS / 204800 kB PSS / 16 threads,
#          in samples deliberately ordered so the peak is NOT the last row.

setup() {
  load ../helpers/common
  setup_sandbox
  SUMMARIZE="$REPO_ROOT/bin/summarize-mem.sh"
  FIXTURE="$REPO_ROOT/tests/fixtures/sample.mem.log"
}
teardown() { teardown_sandbox; }

@test "usage error without an argument" {
  run "$SUMMARIZE"
  [ "$status" -ne 0 ]
}

@test "clear error for an unreadable log" {
  run "$SUMMARIZE" "$SANDBOX/nope.log"
  assert_status 1
  assert_contains "$output" "cannot read"
}

@test "reports peak RSS per process, not the last sample" {
  run "$SUMMARIZE" "$FIXTURE"
  assert_status 0
  assert_contains "$output" "rocotorun                   100.0         50.0         8"
  assert_contains "$output" "ruby                        400.0        200.0        16"
}

@test "reports the peak sum-of-processes row" {
  run "$SUMMARIZE" "$FIXTURE"
  assert_contains "$output" "sum-of-procs (peak)         450.0        225.0"
}

@test "reports the cgroup peak from the TOTAL rows" {
  run "$SUMMARIZE" "$FIXTURE"
  assert_contains "$output" "service cgroup peak         400.0   (cgroup.memory.peak)"
}

@test "reports systemd's own MemoryPeak from the SERVICE row" {
  run "$SUMMARIZE" "$FIXTURE"
  assert_contains "$output" "service peak                500.0   (systemd MemoryPeak)"
}

@test "handles a log with a header only" {
  head -1 "$FIXTURE" > "$SANDBOX/empty.mem.log"
  run "$SUMMARIZE" "$SANDBOX/empty.mem.log"
  assert_status 0
  assert_contains "$output" "peakRSS_MB"
}

@test "round-trips a log produced by loop.sh itself" {
  # Guards the mem_sample writer against the summarize reader.
  DEST="$(install_tree)"
  export WD="$SANDBOX/work" INSTANCE=rt
  export WF="$WD/wf.xml" DB="$WD/wf.db"
  mkdir -p "$WD"; touch "$WF" "$DB"
  export SERVICE_LOG="$SANDBOX/svc.log" MEM_LOG="$SANDBOX/rt.mem.log"
  export INTERVAL=1 MEM_SAMPLE_INTERVAL=1 IDLE_LIMIT=1
  export ROCOTO_BIN="$SANDBOX/rocotobin"
  mkdir -p "$ROCOTO_BIN"
  printf '#!/usr/bin/env bash\nexit 0\n' > "$ROCOTO_BIN/rocotorun"
  cat > "$ROCOTO_BIN/rocotostat" <<'EOF'
#!/usr/bin/env bash
echo "   CYCLE         STATE           ACTIVATED              DEACTIVATED"
echo "202101010000        Done    Jan 01 2021 00:00:00    Jan 02 2021 00:00:00"
EOF
  chmod +x "$ROCOTO_BIN"/*
  stub hostname <<'EOF'
echo gaea51
EOF
  stub loginctl <<'EOF'
echo "Linger=yes"
EOF
  stub_exit systemctl 1
  "$DEST/loop.sh"
  run "$SUMMARIZE" "$MEM_LOG"
  assert_status 0
  assert_contains "$output" "peakRSS_MB"
}
