#!/usr/bin/env bash
# Build a Linux bundle inside a container.
#
#   scripts/build-linux.sh [aarch64|x86_64] [gnu|musl]   # default: Docker host's arch, gnu
#   PG_MAJOR=17 scripts/build-linux.sh aarch64 musl
#
#   gnu  -> <arch>-unknown-linux-gnu, built in manylinux2014 (CentOS 7, glibc 2.17,
#           GCC 10 from devtoolset-10); runs on glibc 2.17+ distros.
#   musl -> <arch>-unknown-linux-musl, built in Alpine; ships its own musl loader
#           and runs on any Linux (glibc or musl, e.g. Alpine), see SPEC.md.
#
# The repo is bind-mounted at /work; sources are cached in .build/sources and
# the build tree in .build/<target>, exactly as for a native build. Output:
# dist/pg-<pg>-pgch-<pgch>-<target>.tar.gz. A non-native arch runs under
# emulation (binfmt/QEMU) and is slow.
#
# Environment: PG_MAJOR, JOBS, PGB_CLEAN, PGB_KEEP_INCLUDE are passed through to build.sh.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

host_arch() { case "$(uname -m)" in arm64|aarch64) echo aarch64 ;; *) echo x86_64 ;; esac; }
ARCH="${1:-$(host_arch)}"
LIBC="${2:-gnu}"

case "$ARCH" in
  aarch64) PLATFORM=linux/arm64 ;;
  x86_64)  PLATFORM=linux/amd64 ;;
  *) echo "usage: $0 [aarch64|x86_64] [gnu|musl]" >&2; exit 2 ;;
esac

case "$LIBC/$ARCH" in
  # manylinux2014 images (tag 2026.10.10-1), pinned by digest.
  gnu/aarch64) IMAGE=quay.io/pypa/manylinux2014_aarch64@sha256:c10b5d2ce68a4426011b5b9b8492f01037b9d0fd2187ed1956b346aa42faeb17 ;;
  gnu/x86_64)  IMAGE=quay.io/pypa/manylinux2014_x86_64@sha256:f6a6f153c9cf45470507ebbc27013e5db14ce21331b62fd2c540561f25e5f0a5 ;;
  # Alpine 3.24.2 (musl 1.2.6), multi-arch index digest.
  musl/*)      IMAGE=alpine:3.24.2@sha256:294b683cb724975bec92580e1e685676bd4b50bda910ddb8c51d4cabeaec77e6 ;;
  *) echo "usage: $0 [aarch64|x86_64] [gnu|musl]" >&2; exit 2 ;;
esac

if [ "$LIBC" = gnu ]; then
  # CentOS 7 is EOL; the manylinux2014 image points yum at vault.centos.org.
  # OpenSSL 3 Configure needs IPC::Cmd and Time::Piece; PostgreSQL 17+ tarballs
  # no longer ship generated parsers, so flex (2.5.37) and bison (3.0.4) are needed.
  SETUP='yum install -y -q perl-IPC-Cmd perl-Time-Piece flex bison >/dev/null'
else
  SETUP='apk add --no-cache -q bash build-base linux-headers perl flex bison patchelf file curl unzip xz bzip2 tar coreutils >/dev/null'
fi

COMMIT="$(git -C "$ROOT" rev-parse HEAD 2>/dev/null || echo unknown)"
DIRTY=0
[ -n "$(git -C "$ROOT" status --porcelain --untracked-files=no 2>/dev/null)" ] && DIRTY=1

TTY=(); [ -t 1 ] && TTY=(-t)
exec docker run --rm ${TTY[@]+"${TTY[@]}"} --platform "$PLATFORM" \
  -v "$ROOT:/work" -w /work \
  -e PG_MAJOR="${PG_MAJOR:-}" -e JOBS="${JOBS:-}" -e PGB_CLEAN="${PGB_CLEAN:-0}" -e PGB_KEEP_INCLUDE="${PGB_KEEP_INCLUDE:-0}" \
  -e PGB_COMMIT="$COMMIT" -e PGB_DIRTY="$DIRTY" -e PGB_REPO="${PGB_REPO:-${GITHUB_REPOSITORY:-sdairs/pg-bundles}}" \
  -e HOST_UID="$(id -u)" -e HOST_GID="$(id -g)" -e SETUP="$SETUP" \
  "$IMAGE" sh -euc '
    eval "$SETUP"
    [ -n "$JOBS" ] || unset JOBS
    [ -n "$PG_MAJOR" ] || unset PG_MAJOR
    status=0
    bash /work/scripts/build.sh || status=$?
    # Hand the build tree and outputs back to the invoking user.
    chown -R "$HOST_UID:$HOST_GID" /work/.build /work/dist 2>/dev/null || true
    exit $status
  '
