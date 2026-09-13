#!/usr/bin/env bash
#
# Run the test suite.  Uses bats from $PATH if present, otherwise fetches a
# pinned copy into tests/.bats (gitignored) so a fresh clone needs nothing but
# bash and git.
#
#   tests/run.sh                      # everything that can run here
#   tests/run.sh tests/unit           # one directory
#   ROCOTO_SYSTEMD_LIVE_TESTS=1 tests/run.sh   # include the systemd tier
#
set -eu

BATS_VERSION="v1.11.1"
HERE="$(cd "$(dirname "$0")" && pwd)"

if command -v bats >/dev/null 2>&1; then
  BATS=bats
else
  BATS="$HERE/.bats/bin/bats"
  if [ ! -x "$BATS" ]; then
    echo "bats not found on PATH; fetching $BATS_VERSION into $HERE/.bats" >&2
    git clone --quiet --depth 1 --branch "$BATS_VERSION" \
      https://github.com/bats-core/bats-core.git "$HERE/.bats"
  fi
fi

if [ "$#" -gt 0 ]; then
  exec "$BATS" --print-output-on-failure "$@"
fi

targets=("$HERE/unit")
if [ "${ROCOTO_SYSTEMD_LIVE_TESTS:-}" = "1" ]; then
  targets+=("$HERE/systemd")
else
  echo "note: skipping the live systemd tier (set ROCOTO_SYSTEMD_LIVE_TESTS=1 to include it)" >&2
fi

exec "$BATS" --print-output-on-failure "${targets[@]}"
