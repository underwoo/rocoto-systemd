#!/usr/bin/env bats
#
# load_rocoto_module -- the ROCOTO_BIN / Lmod resolution order.
#
# `module` is a shell function on real HPC systems, so the tests define one and
# record what it was asked to do.  The one branch that cannot be covered
# hermetically is the fallback that sources /etc/profile.d/lmod.sh: those paths
# are absolute and unfakeable (see docs/testing.md, "known coverage gaps").

setup() {
  load ../helpers/common
  setup_sandbox
  source "$REPO_ROOT/lib/common.sh"
}
teardown() { teardown_sandbox; }

# Put working rocoto executables in DIR.
fake_rocoto_in() {
  mkdir -p "$1"
  for exe in rocotorun rocotostat; do
    printf '#!/usr/bin/env bash\necho "%s stub"\n' "$exe" > "$1/$exe"
    chmod +x "$1/$exe"
  done
}

@test "no-op when rocoto is already on PATH" {
  fake_rocoto_in "$SANDBOX/already"
  PATH="$SANDBOX/already:$PATH"
  module() { echo "module $*" >> "$STUB_LOG"; }
  run load_rocoto_module
  assert_status 0
  [ ! -s "$STUB_LOG" ]
}

@test "ROCOTO_BIN is prepended to PATH and wins over modules" {
  fake_rocoto_in "$SANDBOX/rocotobin"
  ROCOTO_BIN="$SANDBOX/rocotobin"
  module() { echo "module $*" >> "$STUB_LOG"; }
  load_rocoto_module
  [ "$?" -eq 0 ]
  refute_stub_called "module load"
  case "$PATH" in "$SANDBOX/rocotobin":*) ;; *) return 1 ;; esac
}

@test "falls through to the module when ROCOTO_BIN has no rocotorun" {
  ROCOTO_BIN="$SANDBOX/empty"
  mkdir -p "$ROCOTO_BIN"
  module() {
    echo "module $*" >> "$STUB_LOG"
    [ "$1" = load ] && fake_rocoto_in "$SANDBOX/frommodule" && PATH="$SANDBOX/frommodule:$PATH"
    return 0
  }
  run load_rocoto_module
  assert_status 0
  assert_stub_called "module load rocoto"
}

@test "module load uses ROCOTO_MODULE and ROCOTO_MODULEPATH" {
  ROCOTO_MODULE=rocoto/1.3.7
  ROCOTO_MODULEPATH=/contrib/modulefiles
  module() {
    echo "module $*" >> "$STUB_LOG"
    [ "$1" = load ] && fake_rocoto_in "$SANDBOX/frommodule" && PATH="$SANDBOX/frommodule:$PATH"
    return 0
  }
  run load_rocoto_module
  assert_status 0
  assert_stub_called "module use /contrib/modulefiles"
  assert_stub_called "module load rocoto/1.3.7"
}

@test "reports failure when module load fails" {
  module() { echo "module $*" >> "$STUB_LOG"; [ "$1" = load ] && return 1; return 0; }
  run load_rocoto_module
  assert_status 1
  assert_contains "$output" "'module load rocoto' failed"
}

@test "reports failure when module load succeeds but rocotorun never appears" {
  module() { echo "module $*" >> "$STUB_LOG"; return 0; }
  run load_rocoto_module
  assert_status 1
}

@test "reports failure when there is no module system and no ROCOTO_BIN" {
  # Only meaningful on a host with no Lmod/Environment Modules init scripts.
  for f in /etc/profile.d/lmod.sh /etc/profile.d/modules.sh \
           /usr/share/lmod/lmod/init/bash /usr/share/Modules/init/bash \
           /opt/cray/pe/lmod/lmod/init/bash; do
    [ -r "$f" ] && skip "host provides $f"
  done
  run load_rocoto_module
  assert_status 1
  assert_contains "$output" "'module' not available and ROCOTO_BIN not set"
}
