# shellcheck shell=bash
#
# Shared bats helpers.  Source from a test with:
#     load ../helpers/common
#
# The model here is "hermetic sandbox": every test gets a throwaway $HOME and a
# stub directory at the front of $PATH, so nothing touches the real machine and
# no test needs Slurm, systemd or Rocoto to be installed.

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
export REPO_ROOT

# ----------------------------------------------------------------------
# setup_sandbox
#   Fresh $HOME, fresh stub bin dir on the front of $PATH, fresh stub call log.
#   Call from bats setup().
# ----------------------------------------------------------------------
setup_sandbox() {
  SANDBOX="$(mktemp -d "${BATS_TMPDIR:-/tmp}/rocoto-systemd.XXXXXX")"
  export SANDBOX
  export HOME="$SANDBOX/home"
  export STUB_BIN="$SANDBOX/bin"
  export STUB_LOG="$SANDBOX/stub.log"
  mkdir -p "$HOME" "$STUB_BIN"
  : > "$STUB_LOG"
  export PATH="$STUB_BIN:$PATH"

  # Nothing in the suite may inherit a real instance's configuration.
  unset WF DB WD INSTANCE PIN_NODE ROCOTO_BIN ROCOTO_MODULE ROCOTO_MODULEPATH
  unset VERBOSITY INTERVAL IDLE_LIMIT MAX_RUNTIME MEM_SAMPLE_INTERVAL
  unset SERVICE_LOG MEM_LOG SLURM_JOB_ID
}

teardown_sandbox() {
  [ -n "${SANDBOX:-}" ] && rm -rf "$SANDBOX"
  return 0
}

# ----------------------------------------------------------------------
# stub NAME            (script body on stdin)
#   Install an executable NAME in front of $PATH.  Every invocation appends
#   "NAME <args>" to $STUB_LOG before running the body, so a test can assert
#   on what the script under test actually called.
#
#   stub rocotostat <<'EOF'
#   echo "CYCLE  STATE"
#   EOF
# ----------------------------------------------------------------------
stub() {
  local name="$1"
  {
    echo '#!/usr/bin/env bash'
    # shellcheck disable=SC2016  # this is a script body, not an expansion
    printf 'printf "%%s\\n" "%s $*" >> "$STUB_LOG"\n' "$name"
    cat
  } > "$STUB_BIN/$name"
  chmod +x "$STUB_BIN/$name"
}

# stub_exit NAME CODE -- a stub that only records the call and exits CODE.
stub_exit() {
  stub "$1" <<EOF
exit ${2:-0}
EOF
}

# ----------------------------------------------------------------------
# Assertions.  Kept deliberately tiny so the suite has no bats-assert
# dependency to vendor.
# ----------------------------------------------------------------------
# $status and $output below are set by bats' `run`, not by this file.
# shellcheck disable=SC2154
assert_status() { # assert_status EXPECTED
  if [ "$status" -ne "$1" ]; then
    printf 'expected exit %s, got %s\n--- output ---\n%s\n' "$1" "$status" "$output" >&2
    return 1
  fi
}

assert_contains() { # assert_contains HAYSTACK NEEDLE
  case "$1" in
    *"$2"*) return 0 ;;
    *) printf 'expected to find:\n  %s\nin:\n%s\n' "$2" "$1" >&2; return 1 ;;
  esac
}

refute_contains() { # refute_contains HAYSTACK NEEDLE
  case "$1" in
    *"$2"*) printf 'did NOT expect to find:\n  %s\nin:\n%s\n' "$2" "$1" >&2; return 1 ;;
    *) return 0 ;;
  esac
}

# assert_stub_called "systemctl --user start rocoto-workflow@x.service"
assert_stub_called() {
  if ! grep -Fqx -- "$1" "$STUB_LOG"; then
    printf 'expected stub call:\n  %s\nrecorded calls:\n%s\n' "$1" "$(cat "$STUB_LOG")" >&2
    return 1
  fi
}

refute_stub_called() {
  if grep -Fq -- "$1" "$STUB_LOG"; then
    printf 'did NOT expect stub call matching:\n  %s\nrecorded calls:\n%s\n' \
      "$1" "$(cat "$STUB_LOG")" >&2
    return 1
  fi
}

# ----------------------------------------------------------------------
# install_tree -- run install.sh into the sandbox $HOME and echo the dest dir.
#   Gives tests the flattened runtime layout the systemd unit actually uses.
# ----------------------------------------------------------------------
install_tree() {
  stub_exit loginctl 1
  stub_exit systemctl 0
  "$REPO_ROOT/install.sh" </dev/null >/dev/null 2>&1
  echo "$HOME/rocoto-systemd"
}
