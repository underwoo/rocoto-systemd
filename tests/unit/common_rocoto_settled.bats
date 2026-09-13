#!/usr/bin/env bats
#
# rocoto_settled -- decides when a workflow is finished.  Everything downstream
# hangs off it: loop.sh exits, the unit gets disabled, the watchdog scancels its
# own scrontab entry.  A false "settled" silently abandons a live workflow, so
# the contract is "exit 1 on any doubt".

setup() {
  load ../helpers/common
  setup_sandbox
  source "$REPO_ROOT/lib/common.sh"
}
teardown() { teardown_sandbox; }

rocotostat_says() { # rocotostat_says <<< output   (stdin becomes stdout of the stub)
  local body; body="$(cat)"
  stub rocotostat <<EOF
cat <<'ROCOTOSTAT_EOF'
${body}
ROCOTOSTAT_EOF
EOF
}

@test "all cycles Done -> settled" {
  rocotostat_says <<'EOF'
   CYCLE         STATE           ACTIVATED              DEACTIVATED
202101010000        Done    Jan 01 2021 00:00:00    Jan 02 2021 00:00:00
202101020000        Done    Jan 02 2021 00:00:00    Jan 03 2021 00:00:00
EOF
  run rocoto_settled /tmp/wf.xml /tmp/wf.db
  assert_status 0
}

@test "one Active cycle -> not settled" {
  rocotostat_says <<'EOF'
   CYCLE         STATE           ACTIVATED              DEACTIVATED
202101010000        Done    Jan 01 2021 00:00:00    Jan 02 2021 00:00:00
202101020000      Active    Jan 02 2021 00:00:00                       -
EOF
  run rocoto_settled /tmp/wf.xml /tmp/wf.db
  assert_status 1
}

@test "every cycle Active -> not settled" {
  rocotostat_says <<'EOF'
   CYCLE         STATE           ACTIVATED              DEACTIVATED
202101010000      Active    Jan 01 2021 00:00:00                       -
EOF
  run rocoto_settled /tmp/wf.xml /tmp/wf.db
  assert_status 1
}

@test "no cycles yet (header only) -> not settled" {
  # A workflow that has not been crank-started must never look finished.
  rocotostat_says <<'EOF'
   CYCLE         STATE           ACTIVATED              DEACTIVATED
EOF
  run rocoto_settled /tmp/wf.xml /tmp/wf.db
  assert_status 1
}

@test "completely empty output -> not settled" {
  rocotostat_says </dev/null
  run rocoto_settled /tmp/wf.xml /tmp/wf.db
  assert_status 1
}

@test "rocotostat failing -> not settled" {
  stub rocotostat <<'EOF'
echo "could not open database" >&2
exit 1
EOF
  run rocoto_settled /tmp/wf.xml /tmp/wf.db
  assert_status 1
}

@test "terminal non-Active states (Dead) count as settled" {
  rocotostat_says <<'EOF'
   CYCLE         STATE           ACTIVATED              DEACTIVATED
202101010000        Dead    Jan 01 2021 00:00:00    Jan 02 2021 00:00:00
EOF
  run rocoto_settled /tmp/wf.xml /tmp/wf.db
  assert_status 0
}

@test "passes the workflow and database through to rocotostat" {
  rocotostat_says <<'EOF'
   CYCLE         STATE           ACTIVATED              DEACTIVATED
202101010000        Done    Jan 01 2021 00:00:00    Jan 02 2021 00:00:00
EOF
  run rocoto_settled /path/to/wf.xml /path/to/wf.db
  assert_status 0
  assert_stub_called "rocotostat -w /path/to/wf.xml -d /path/to/wf.db -c ALL -s"
}
