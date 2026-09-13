#!/usr/bin/env bash
#
# Run the whole suite -- including the live systemd tier -- inside a throwaway
# container booted with systemd as PID 1.  This is how the systemd tests get
# exercised from a macOS workstation, and how CI runs them.
#
#   .devcontainer/test-in-container.sh
#   .devcontainer/test-in-container.sh --image myimage:tag --no-build
#
# The repository is COPIED into the container, never bind-mounted, so a test run
# cannot touch the working tree.

set -eu

REPO="$(cd "$(dirname "$0")/.." && pwd)"
IMAGE="rocoto-systemd-test:local"
BUILD=1

while [ "$#" -gt 0 ]; do
  case "$1" in
    --image)    IMAGE="$2"; shift 2 ;;
    --no-build) BUILD=0; shift ;;
    -h|--help)  sed -n '2,12p' "$0"; exit 0 ;;
    *)          echo "unknown option: $1" >&2; exit 2 ;;
  esac
done

if [ "$BUILD" -eq 1 ]; then
  echo "==> building $IMAGE"
  docker build -t "$IMAGE" "$REPO/.devcontainer"
fi

echo "==> booting systemd"
CID="$(docker run -d --rm --privileged --cgroupns=host \
        --tmpfs /run --tmpfs /run/lock "$IMAGE")"
cleanup() { docker rm -f "$CID" >/dev/null 2>&1 || true; }
trap cleanup EXIT

# Wait for logind to have built the lingering user's session and runtime dir.
ready=0
for _ in $(seq 1 60); do
  if docker exec -u dev "$CID" \
       env XDG_RUNTIME_DIR=/run/user/1001 \
       systemctl --user show --property=Version >/dev/null 2>&1; then
    ready=1
    break
  fi
  sleep 1
done
if [ "$ready" -ne 1 ]; then
  echo "ERROR: 'systemctl --user' never came up in the container" >&2
  docker exec "$CID" systemctl --no-pager status || true
  docker exec "$CID" journalctl --no-pager -n 50 || true
  exit 1
fi
echo "==> user manager is up: $(docker exec -u dev "$CID" \
      env XDG_RUNTIME_DIR=/run/user/1001 systemctl --user --version | head -1)"

echo "==> copying the repository in"
docker exec "$CID" mkdir -p /home/dev/repo
docker cp "$REPO/." "$CID:/home/dev/repo"
docker exec "$CID" chown -R dev:dev /home/dev/repo
docker exec "$CID" rm -rf /home/dev/repo/.git /home/dev/repo/tests/.bats

echo "==> running the suite"
docker exec -u dev \
  -e ROCOTO_SYSTEMD_LIVE_TESTS=1 \
  -e XDG_RUNTIME_DIR=/run/user/1001 \
  -e HOME=/home/dev \
  "$CID" bash -c 'cd /home/dev/repo && tests/run.sh'
