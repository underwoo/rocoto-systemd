#!/usr/bin/env bash
#
# ExecStartPre guard for rocoto-workflow@<instance>.service.
#
# The EnvironmentFile is already loaded by the time ExecStartPre runs, so PIN_NODE
# (if any) is in our environment.  If it names a different node than this one,
# fail the unit with a clear message so a user who runs
#     systemctl --user start rocoto-workflow@<instance>
# on the wrong node gets told why instead of a silent second copy.

set -u
SELF_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck disable=SC1091
. "${SELF_DIR}/common.sh" 2>/dev/null || . "${SELF_DIR}/../lib/common.sh"

if node_pin_ok; then
  exit 0
fi

echo "node-guard: refusing to start '${INSTANCE:-?}' here." >&2
echo "node-guard: pinned to '${PIN_NODE%%.*}' -- start the service on that node," >&2
echo "node-guard: or clear PIN_NODE in ~/.config/rocoto-systemd/${INSTANCE:-<instance>}.env" >&2
exit 70
