#!/usr/bin/env bash
# Build a Linux bundle inside a glibc 2.28 (manylinux_2_28, AlmaLinux 8) container.
#
#   scripts/build-linux.sh [aarch64|x86_64]     # default: the Docker host's arch
#
# The repo is bind-mounted at /work; sources are cached in .build/sources and
# the build tree in .build/<target>-unknown-linux-gnu, exactly as for a native
# build. Output: dist/pg-<pg>-pgch-<pgch>-<arch>-unknown-linux-gnu.tar.gz.
# A non-native arch runs under emulation (binfmt/QEMU) and is slow.
#
# Environment: JOBS, PGB_CLEAN, PGB_KEEP_INCLUDE are passed through to build.sh.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

host_arch() { case "$(uname -m)" in arm64|aarch64) echo aarch64 ;; *) echo x86_64 ;; esac; }
ARCH="${1:-$(host_arch)}"

# manylinux_2_28 images (tag 2026.10.10-1), pinned by digest.
case "$ARCH" in
  aarch64)
    PLATFORM=linux/arm64
    IMAGE=quay.io/pypa/manylinux_2_28_aarch64@sha256:abd1230aa9e4058a74b89d27cd14ba18c0db036d7bfe6e6f219a29ea63c24eb6 ;;
  x86_64)
    PLATFORM=linux/amd64
    IMAGE=quay.io/pypa/manylinux_2_28_x86_64@sha256:4131ddd7acb9c6c966af02fe7e71edc51e078c2d41f475966697676430bfa2ae ;;
  *) echo "usage: $0 [aarch64|x86_64]" >&2; exit 2 ;;
esac

COMMIT="$(git -C "$ROOT" rev-parse HEAD 2>/dev/null || echo unknown)"
DIRTY=0
[ -n "$(git -C "$ROOT" status --porcelain --untracked-files=no 2>/dev/null)" ] && DIRTY=1

TTY=(); [ -t 1 ] && TTY=(-t)
exec docker run --rm ${TTY[@]+"${TTY[@]}"} --platform "$PLATFORM" \
  -v "$ROOT:/work" -w /work \
  -e JOBS="${JOBS:-}" -e PGB_CLEAN="${PGB_CLEAN:-0}" -e PGB_KEEP_INCLUDE="${PGB_KEEP_INCLUDE:-0}" \
  -e PGB_COMMIT="$COMMIT" -e PGB_DIRTY="$DIRTY" -e PGB_REPO="${PGB_REPO:-${GITHUB_REPOSITORY:-sdairs/pg-bundles}}" \
  -e HOST_UID="$(id -u)" -e HOST_GID="$(id -g)" \
  "$IMAGE" bash -euo pipefail -c '
    # OpenSSL 3 Configure needs these Perl modules (AlmaLinux 8 ships them separately);
    # PostgreSQL 17+ tarballs no longer ship generated parsers, so flex is required.
    dnf install -y -q perl-IPC-Cmd perl-Time-Piece flex >/dev/null
    [ -n "$JOBS" ] || unset JOBS
    status=0
    /work/scripts/build.sh || status=$?
    # Hand the build tree and outputs back to the invoking user.
    chown -R "$HOST_UID:$HOST_GID" /work/.build /work/dist 2>/dev/null || true
    exit $status
  '
