#!/usr/bin/env bash
#
# ExecCondition guard for rocoto-workflow@<instance>.service.
#
# The EnvironmentFile is already loaded by the time ExecCondition runs, so
# PIN_NODE (if any) is in our environment.  If it names a different node than
# this one, exit 70: systemd treats any ExecCondition exit of 1-254 as "skip"
# -- the unit stays inactive and is never restarted -- and the message below
# lands in the service log, so whoever ran
#     systemctl --user start rocoto-workflow@<instance>
# on the wrong node can see why.  Never exit 255: that marks the unit failed.

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
