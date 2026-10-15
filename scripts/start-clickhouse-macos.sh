#!/usr/bin/env bash
# Start a throwaway ClickHouse server on macOS for the self-test (CI has no
# service containers on macOS runners). Downloads a pinned release binary,
# verifies its sha256 and runs it in the background with data in a temp dir.
#
#   scripts/start-clickhouse-macos.sh            # http 8123, native 9000
#   CLICKHOUSE_HTTP_PORT=18123 CLICKHOUSE_NATIVE_PORT=19000 scripts/start-clickhouse-macos.sh
#
# Prints the server pid on success. Stop it with `kill <pid>`.
set -euo pipefail

CH_TAG=v26.8.27.9-lts
case "$(uname -m)" in
  arm64)  ASSET=clickhouse-macos-aarch64; SHA=dce3b0999cce1086db51753fd3148088cbfe75777354103a640bda3cd0898e4f ;;
  x86_64) ASSET=clickhouse-macos;         SHA=75c8f277fc26d6fb06ea9d7b1499a481ab69991292e45c2c7bd03c9688f6f312 ;;
  *) echo "unsupported arch" >&2; exit 1 ;;
esac
HTTP_PORT="${CLICKHOUSE_HTTP_PORT:-8123}"
NATIVE_PORT="${CLICKHOUSE_NATIVE_PORT:-9000}"
DIR="${CLICKHOUSE_DIR:-$(mktemp -d /tmp/pgb-ch.XXXXXX)}"
CACHE="${CLICKHOUSE_CACHE:-$HOME/.cache/pg-bundles}"
mkdir -p "$CACHE" "$DIR/data"

BIN="$CACHE/$ASSET-$CH_TAG"
if [ ! -x "$BIN" ] || [ "$(shasum -a 256 "$BIN" | cut -d' ' -f1)" != "$SHA" ]; then
  echo "downloading ClickHouse $CH_TAG ($ASSET)" >&2
  curl -fsSL --retry 3 -o "$BIN.part" "https://github.com/ClickHouse/ClickHouse/releases/download/$CH_TAG/$ASSET"
  [ "$(shasum -a 256 "$BIN.part" | cut -d' ' -f1)" = "$SHA" ] || { echo "sha256 mismatch for $ASSET" >&2; exit 1; }
  chmod +x "$BIN.part"; mv "$BIN.part" "$BIN"
fi

cd "$DIR"
"$BIN" server -- --path="$DIR/data/" --http_port="$HTTP_PORT" --tcp_port="$NATIVE_PORT" \
  --listen_host=127.0.0.1 --logger.log="$DIR/server.log" --logger.errorlog="$DIR/server.err.log" \
  --logger.console=0 >"$DIR/stdout.log" 2>&1 &
PID=$!
for _ in $(seq 1 120); do
  if curl -fs "http://127.0.0.1:$HTTP_PORT/ping" >/dev/null 2>&1; then
    echo "ClickHouse $CH_TAG up (pid $PID, http $HTTP_PORT, native $NATIVE_PORT, dir $DIR)" >&2
    echo "$PID"; exit 0
  fi
  kill -0 "$PID" 2>/dev/null || break
  sleep 0.5
done
echo "ClickHouse failed to start" >&2
tail -50 "$DIR/stdout.log" "$DIR/server.err.log" >&2 2>/dev/null || true
exit 1
