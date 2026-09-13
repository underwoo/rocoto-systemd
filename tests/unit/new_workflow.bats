#!/usr/bin/env bats
#
# new-workflow.sh -- interactive registration.
#
# Driven by feeding one answer per prompt on stdin, which also pins the prompt
# ORDER: the generated .env and .scrontab are the contract between this script,
# the unit file and watchdog.sh, so a reordered prompt that silently writes the
# database path into WD= must fail here.
#
# Answers are spelled out one array element per prompt, in order, because blank
# lines (= "accept the default") are load-bearing and impossible to count by eye
# in a here-document.

setup() {
  load ../helpers/common
  setup_sandbox
  NEWWF="$REPO_ROOT/bin/new-workflow.sh"
  export WD="$SANDBOX/work"
  mkdir -p "$WD"
  export WF="$WD/workflow.xml"
  touch "$WF"
  ENVDIR="$HOME/.config/rocoto-systemd"
}
teardown() { teardown_sandbox; }

# answer_with "${ANSWERS[@]}" -- run new-workflow.sh with one line per element.
answer_with() {
  run "$NEWWF" <<< "$(printf '%s\n' "$@")"
}

@test "all defaults: writes an env file and no scrontab" {
  answer_with \
    "$WF" \
    ""   `# WD        -> dirname of WF` \
    ""   `# DB        -> <WD>/workflow.db` \
    ""   `# INSTANCE  -> basename of WD` \
    ""   `# MODULEPATH` \
    ""   `# MODULE    -> rocoto` \
    ""   `# ROCOTO_BIN` \
    ""   `# pin?      -> N` \
    ""   `# VERBOSITY -> 10` \
    ""   `# INTERVAL  -> 300` \
    ""   `# MAX_RUNTIME -> 259200` \
    ""   `# scron?    -> N`
  assert_status 0
  ENVFILE="$ENVDIR/work.env"
  [ -f "$ENVFILE" ]
  body="$(cat "$ENVFILE")"
  assert_contains "$body" "WF=$WF"
  assert_contains "$body" "WD=$WD"
  assert_contains "$body" "DB=$WD/workflow.db"
  assert_contains "$body" "INSTANCE=work"
  assert_contains "$body" "ROCOTO_MODULE=rocoto"
  assert_contains "$body" "VERBOSITY=10"
  assert_contains "$body" "INTERVAL=300"
  assert_contains "$body" "MAX_RUNTIME=259200"
  refute_contains "$body" "PIN_NODE="
  [ ! -e "$ENVDIR/work.scrontab" ]
}

@test "the next-steps hint survives an unset USER" {
  # WF, then accept every default (11 prompts), no scron.
  run env -u USER "$NEWWF" <<< "$(printf '%s\n' "$WF" "" "" "" "" "" "" "" "" "" "" "")"
  assert_status 0
  assert_contains "$output" "loginctl enable-linger $(id -un)"
}

@test "explicit values are written through verbatim" {
  answer_with \
    "$WF" "$WD" "$WD/custom.db" "myinst" \
    "/contrib/modulefiles" "rocoto/1.3.7" "" \
    "n" "5" "60" "3600" "n"
  assert_status 0
  body="$(cat "$ENVDIR/myinst.env")"
  assert_contains "$body" "DB=$WD/custom.db"
  assert_contains "$body" "INSTANCE=myinst"
  assert_contains "$body" "ROCOTO_MODULEPATH=/contrib/modulefiles"
  assert_contains "$body" "ROCOTO_MODULE=rocoto/1.3.7"
  assert_contains "$body" "VERBOSITY=5"
  assert_contains "$body" "INTERVAL=60"
  assert_contains "$body" "MAX_RUNTIME=3600"
}

@test "ROCOTO_BIN is recorded when given instead of a module" {
  answer_with \
    "$WF" "" "" "bininst" \
    "" "" "/apps/rocoto/bin" \
    "n" "" "" "" "n"
  assert_status 0
  assert_contains "$(cat "$ENVDIR/bininst.env")" "ROCOTO_BIN=/apps/rocoto/bin"
}

@test "a nonexistent workflow XML warns and can be overridden" {
  answer_with \
    "$SANDBOX/missing.xml" "y" `# WF, then "continue anyway?"` \
    "$WD" "" "ghost" \
    "" "" "" \
    "n" "" "" "" "n"
  assert_status 0
  assert_contains "$output" "not found: $SANDBOX/missing.xml"
  assert_contains "$(cat "$ENVDIR/ghost.env")" "WF=$SANDBOX/missing.xml"
}

@test "a nonexistent workflow XML can be refused" {
  answer_with "$SANDBOX/missing.xml" "n"
  assert_status 1
  [ ! -e "$ENVDIR" ] || [ -z "$(ls -A "$ENVDIR")" ]
}

@test "pinning lists nodes from sinfo and defaults to the first" {
  stub sinfo <<'EOF'
echo "gaea51"
echo "gaea52"
EOF
  answer_with \
    "$WF" "" "" "pinned" \
    "" "" "" \
    "y" "cron_c6" ""  `# pin? / partition / node -> first from sinfo` \
    "" "" "" "n"
  assert_status 0
  assert_contains "$output" "nodes in 'cron_c6': gaea51 gaea52"
  assert_contains "$(cat "$ENVDIR/pinned.env")" "PIN_NODE=gaea51"
  assert_stub_called "sinfo -h -p cron_c6 -N -o %N"
}

@test "pinning works with no sinfo on PATH" {
  answer_with \
    "$WF" "" "" "manual" \
    "" "" "" \
    "y" "" "gaea77" \
    "" "" "" "n"
  assert_status 0
  assert_contains "$(cat "$ENVDIR/manual.env")" "PIN_NODE=gaea77"
}

@test "scrontab carries the full export list the watchdog needs" {
  answer_with \
    "$WF" "" "" "scr" \
    "" "rocoto/1.3.7" "" \
    "n" "" "" "" \
    "y" "cron_c6" "myacct" "*/5 * * * *" "2G" "00:03:00"
  assert_status 0
  CRON="$ENVDIR/scr.scrontab"
  [ -f "$CRON" ]
  body="$(cat "$CRON")"
  assert_contains "$body" "#SCRON --partition=cron_c6"
  assert_contains "$body" "#SCRON --account=myacct"
  assert_contains "$body" "#SCRON --time=00:03:00"
  assert_contains "$body" "#SCRON --mem=2G"
  assert_contains "$body" "#SCRON --job-name=rocoto_wd_scr"
  assert_contains "$body" "#SCRON --dependency=singleton"
  assert_contains "$body" "WF=$WF"
  assert_contains "$body" "INSTANCE=scr"
  assert_contains "$body" "ROCOTO_MODULE=rocoto/1.3.7"
  assert_contains "$body" "*/5 * * * * $HOME/rocoto-systemd/watchdog.sh"
}

@test "a pinned instance gets a matching --nodelist in the scrontab" {
  # Without this the scron job can land on another node, where node_pin_ok
  # refuses to start the service -- silently, every five minutes.
  answer_with \
    "$WF" "" "" "both" \
    "" "" "" \
    "y" "" "gaea51" \
    "" "" "" \
    "y" "cron_c6" "" "*/5 * * * *" "" ""
  assert_status 0
  body="$(cat "$ENVDIR/both.scrontab")"
  assert_contains "$body" "#SCRON --nodelist=gaea51"
  assert_contains "$body" "PIN_NODE=gaea51"
}

@test "every variable exported by the scrontab is one watchdog.sh reads" {
  answer_with \
    "$WF" "" "" "exp" \
    "" "" "" \
    "n" "" "" "" \
    "y" "cron_c6" "" "*/5 * * * *" "" ""
  assert_status 0
  exports="$(sed -n 's/^#SCRON --export=//p' "$ENVDIR/exp.scrontab" | tr ',' '\n' | cut -d= -f1)"
  [ -n "$exports" ]
  for v in $exports; do
    grep -q "[^A-Z_]$v[^A-Z_]" "$REPO_ROOT/bin/watchdog.sh" \
      || { echo "scrontab exports $v but watchdog.sh never reads it" >&2; return 1; }
  done
}
