#!/usr/bin/env bash
# Run scripts/selftest.sh for a Linux bundle inside a container of some other
# distro, as a non-root user, to prove the bundle runs there.
#
#   scripts/selftest-container.sh <image> dist/<bundle>.tar.gz
#   e.g. alpine:3.24, centos:7, debian:10, ubuntu:24.04
#
# Nothing is installed in the container except, where the image has no bash
# (Alpine, busybox), bash and binutils. Images without readelf/objdump skip the
# static ELF checks; the runtime library check (/proc/self/maps of a backend)
# always runs.
#
# Environment:
#   PGB_DOCKER_NETWORK  docker --network value (default "host"; on Docker Desktop
#                       use "container:<clickhouse container>" so 127.0.0.1 reaches it)
#   PGB_DOCKER_PLATFORM docker --platform (default: from the bundle's target)
#   CLICKHOUSE_*, PGB_SELFTEST_CLICKHOUSE, PGB_SELFTEST_MAX_GLIBC are passed to selftest.sh.
set -euo pipefail

IMAGE="${1:?usage: selftest-container.sh <image> <bundle.tar.gz>}"
TARBALL="${2:?usage: selftest-container.sh <image> <bundle.tar.gz>}"
[ -f "$TARBALL" ] || { echo "error: $TARBALL not found" >&2; exit 1; }
DIR="$(cd "$(dirname "$TARBALL")" && pwd)"
FILE="$(basename "$TARBALL")"
SCRIPTS="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

case "$FILE" in
  *aarch64-unknown-linux-*) PLATFORM=linux/arm64 ;;
  *x86_64-unknown-linux-*)  PLATFORM=linux/amd64 ;;
  *) echo "error: $FILE is not a Linux bundle" >&2; exit 2 ;;
esac
PLATFORM="${PGB_DOCKER_PLATFORM:-$PLATFORM}"

# Values are passed through the environment and re-exported for the test user.
ENV_ARGS=()
for v in CLICKHOUSE_HOST CLICKHOUSE_HTTP_PORT CLICKHOUSE_NATIVE_PORT CLICKHOUSE_USER CLICKHOUSE_PASSWORD \
         PGB_SELFTEST_CLICKHOUSE PGB_SELFTEST_MAX_GLIBC; do
  [ -n "${!v+x}" ] && ENV_ARGS+=(-e "$v")
done

echo "=== self-test of $FILE in $IMAGE ($PLATFORM)"
docker run --rm --platform "$PLATFORM" --network "${PGB_DOCKER_NETWORK:-host}" \
  -v "$DIR:/dist:ro" -v "$SCRIPTS:/scripts:ro" ${ENV_ARGS[@]+"${ENV_ARGS[@]}"} \
  -e PGB_FILE="$FILE" "$IMAGE" sh -euc '
    if ! command -v bash >/dev/null 2>&1; then
      if command -v apk >/dev/null 2>&1; then apk add --no-cache -q bash binutils >/dev/null
      else echo "error: no bash in this image" >&2; exit 1; fi
    fi
    id pgbtest >/dev/null 2>&1 || useradd -m pgbtest 2>/dev/null || adduser -D pgbtest
    # export -p prints shell-quoted assignments; the test user sources them.
    export -p | grep -E "^export (CLICKHOUSE_|PGB_SELFTEST_)" >/tmp/pgb-selftest.env || true
    chmod 644 /tmp/pgb-selftest.env
    cd /tmp
    su pgbtest -c ". /tmp/pgb-selftest.env; exec bash /scripts/selftest.sh /dist/$PGB_FILE"
  '
