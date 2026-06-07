#!/bin/sh
# Example --custom-script for alpine-anywhere.
#
# This runs INSIDE the image chroot during build, as root, with working
# network (apk, wget, curl, git all work). Whatever you write to the
# filesystem here ends up baked into the immutable squashfs root.
#
# Usage:
#   alpine-anywhere --install --custom-script ./examples/custom-script.sh root@host
#
# Keep it POSIX sh and fail loud — a non-zero exit aborts the build.
set -e

# 1. Install extra packages
apk add --no-cache git tmux htop

# 2. Fetch a project into /usr/local/share
#    (git is installed above; or use wget/curl for a tarball)
rm -rf /usr/local/share/myos
git clone --depth 1 https://github.com/aya/myos /usr/local/share/myos

# Tarball alternative (no git dependency):
#   mkdir -p /usr/local/share/myos
#   wget -qO- https://github.com/aya/myos/archive/refs/heads/main.tar.gz \
#     | tar -xz --strip-components=1 -C /usr/local/share/myos

# 3. Drop a config / enable a service, etc.
#   cp -r /usr/local/share/myos/etc/* /etc/
#   rc-update add myservice default

echo "custom-script: done"
