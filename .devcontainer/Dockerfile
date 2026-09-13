# A Linux box with a REAL systemd user manager, which is the one thing a macOS
# workstation cannot provide and this project is built entirely around.
#
# systemd runs as PID 1 and user `dev` is set up as a *lingering* user, so
# `systemctl --user` behaves the way it does on a login node after
# `loginctl enable-linger`.
#
# Deliberately NO Slurm and NO Rocoto: the test suite stubs both, and shipping
# fake `sinfo`/`scancel` on PATH would mask the "what if the tool is missing"
# branches the suite checks.  See docs/testing.md for adding real ones.

FROM ubuntu:24.04

ENV DEBIAN_FRONTEND=noninteractive \
    container=docker \
    LANG=C.UTF-8

RUN apt-get update && apt-get install -y --no-install-recommends \
      bash bash-completion ca-certificates curl git less sudo vim-tiny \
      systemd systemd-sysv dbus dbus-user-session libpam-systemd \
      bats shellcheck \
      python3 python3-venv pipx \
      gawk procps psmisc sqlite3 \
    && rm -rf /var/lib/apt/lists/*

# pre-commit, on PATH for every user.
ENV PIPX_HOME=/opt/pipx PIPX_BIN_DIR=/usr/local/bin
RUN pipx install pre-commit

# Boot faster and quieter: none of this is reachable in a container anyway.
RUN for u in systemd-udevd.service systemd-udev-trigger.service \
             systemd-modules-load.service systemd-machine-id-commit.service \
             sys-kernel-debug.mount sys-kernel-tracing.mount \
             getty.target console-getty.service getty-static.service; do \
      ln -sf /dev/null "/etc/systemd/system/$u"; \
    done

# The unprivileged user the tests run as.  Writing the linger marker directly is
# what `loginctl enable-linger dev` does; it cannot be run at build time because
# there is no systemd running yet.
RUN useradd --create-home --uid 1001 --shell /bin/bash dev \
    && echo 'dev ALL=(ALL) NOPASSWD:ALL' > /etc/sudoers.d/90-dev \
    && chmod 0440 /etc/sudoers.d/90-dev \
    && mkdir -p /var/lib/systemd/linger \
    && touch /var/lib/systemd/linger/dev

# The live tier is always welcome in here -- that is the point of the container.
ENV ROCOTO_SYSTEMD_LIVE_TESTS=1 \
    XDG_RUNTIME_DIR=/run/user/1001

STOPSIGNAL SIGRTMIN+3
ENTRYPOINT ["/sbin/init"]
