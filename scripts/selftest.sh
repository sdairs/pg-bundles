#!/usr/bin/env bash
# Self-test a pg-bundles tarball (see SPEC.md, "Self-test").
#
#   scripts/selftest.sh dist/pg-18.6-pgch-0.11.0-aarch64-apple-darwin.tar.gz
#
# Runs from an extracted copy in a fresh random temp dir, as a non-root user,
# with a scrubbed environment (no DYLD_* / LD_* / Homebrew paths):
#   1. initdb with a password file (scram-sha-256, UTF8, locale C)
#   2. postgres on a free port, unix socket in the temp dir, wait for pg_isready
#   3. psql: SELECT version(); CREATE EXTENSION pg_clickhouse; \dx
#   4. if ClickHouse is reachable: foreign servers for both pg_clickhouse drivers
#      (http and binary), a real table in ClickHouse, queries through foreign
#      tables and clickhouse_query()
#   5. pg_ctl stop -m fast
#   6. dependency closure contains only allowed system libraries
#
# Environment:
#   CLICKHOUSE_HOST         default 127.0.0.1
#   CLICKHOUSE_HTTP_PORT    default 8123
#   CLICKHOUSE_NATIVE_PORT  default 9000
#   CLICKHOUSE_USER         default "default"
#   CLICKHOUSE_PASSWORD     default ""
#   PGB_SELFTEST_CLICKHOUSE auto (default: run step 4 if reachable) | require | skip
#   PGB_SELFTEST_REPORT     optional path; a JSON summary is written there
#   PGB_SELFTEST_KEEP=1     keep the temp dir for debugging
set -euo pipefail

TARBALL="${1:?usage: selftest.sh <bundle.tar.gz>}"
[ -f "$TARBALL" ] || { echo "error: $TARBALL not found" >&2; exit 1; }
TARBALL="$(cd "$(dirname "$TARBALL")" && pwd)/$(basename "$TARBALL")"
NAME="$(basename "$TARBALL" .tar.gz)"

CH_HOST="${CLICKHOUSE_HOST:-127.0.0.1}"
CH_HTTP_PORT="${CLICKHOUSE_HTTP_PORT:-8123}"
CH_NATIVE_PORT="${CLICKHOUSE_NATIVE_PORT:-9000}"
CH_USER="${CLICKHOUSE_USER:-default}"
CH_PASSWORD="${CLICKHOUSE_PASSWORD:-}"
CH_MODE="${PGB_SELFTEST_CLICKHOUSE:-auto}"

OS="$(uname -s)"
step() { printf '\n--- %s\n' "$*"; }
ok()   { printf 'ok: %s\n' "$*"; }
fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }

if [ "$(id -u)" = 0 ]; then
  fail "run the self-test as a non-root user (postgres refuses to run as root)"
fi

now_ms() {
  local t; t="$(date +%s%N 2>/dev/null || true)"
  case "$t" in *N|"") perl -MTime::HiRes=time -e 'printf "%d\n", time()*1000' ;; *) echo $((t / 1000000)) ;; esac
}
sha256() { if command -v sha256sum >/dev/null; then sha256sum "$@"; else shasum -a 256 "$@"; fi; }

# Scrub the environment for everything the bundle runs: only system paths, no
# loader overrides, so a library that is not in the bundle or the OS cannot be
# picked up from Homebrew / /usr/local / the build tree.
run() {
  env -i PATH=/usr/bin:/bin:/usr/sbin:/sbin HOME="${HOME:-/tmp}" USER="${USER:-$(id -un)}" \
    LANG=C LC_ALL=C TZ=UTC PGPASSWORD="$PGPASS" "$@"
}

# ------------------------------------------------------------------ setup ----
if [ -f "$TARBALL.sha256" ]; then
  step "verify sha256"
  want="$(awk '{print $1}' "$TARBALL.sha256")"
  got="$(sha256 "$TARBALL" | awk '{print $1}')"
  [ "$want" = "$got" ] || fail "sha256 mismatch: $got != $want"
  ok "sha256 $got"
fi

# Short base path: the unix socket path must fit in sun_path (~104 bytes).
TMP="$(mktemp -d /tmp/pgbst.XXXXXX)"
PG_PID=""
cleanup() {
  if [ -n "$PG_PID" ] && kill -0 "$PG_PID" 2>/dev/null; then
    kill -INT "$PG_PID" 2>/dev/null || true; sleep 1; kill -KILL "$PG_PID" 2>/dev/null || true
  fi
  if [ "${PGB_SELFTEST_KEEP:-0}" = 1 ]; then echo "kept $TMP"; else rm -rf "$TMP"; fi
}
trap cleanup EXIT
PGPASS="selftest-$RANDOM$RANDOM"
printf '%s\n' "$PGPASS" >"$TMP/pwfile"
chmod 600 "$TMP/pwfile"

free_port() {
  local p i
  for i in $(seq 1 50); do
    p=$(( 20000 + (RANDOM * 32768 + RANDOM) % 40000 ))
    if ! (exec 3<>"/dev/tcp/127.0.0.1/$p") 2>/dev/null; then echo "$p"; return; fi
  done
  fail "no free port found"
}

step "extract $NAME into $TMP"
T0=$(now_ms)
tar -xzf "$TARBALL" -C "$TMP"
T_EXTRACT=$(now_ms)
P="$TMP/$NAME"
[ -d "$P/bin" ] && [ -f "$P/BUNDLE.json" ] || fail "unexpected layout (no $NAME/bin or BUNDLE.json)"
ok "extracted in $((T_EXTRACT - T0)) ms"
cat "$P/BUNDLE.json"

# --------------------------------------------------------------- 1 initdb ----
step "1. initdb"
run "$P/bin/initdb" -D "$TMP/data" -U postgres --auth=scram-sha-256 --pwfile="$TMP/pwfile" \
  -E UTF8 --locale=C >"$TMP/initdb.log" 2>&1 || { cat "$TMP/initdb.log"; fail "initdb"; }
T_INITDB=$(now_ms)
ok "initdb in $((T_INITDB - T_EXTRACT)) ms"

# ---------------------------------------------------------- 2 start/ready ----
step "2. start postgres"
PORT="$(free_port)"
mkdir -p "$TMP/sock"
PRELOAD_ENV=()
# On macOS, have dyld log every image it loads into the postmaster and its
# backends, so step 6 can check what was actually loaded at runtime, including
# pg_clickhouse.dylib and everything it pulls in.
[ "$OS" = Darwin ] && PRELOAD_ENV=(DYLD_PRINT_LIBRARIES=1)
env -i PATH=/usr/bin:/bin:/usr/sbin:/sbin HOME="${HOME:-/tmp}" LANG=C LC_ALL=C TZ=UTC "${PRELOAD_ENV[@]}" \
  "$P/bin/postgres" -D "$TMP/data" -p "$PORT" -k "$TMP/sock" -c listen_addresses=127.0.0.1 \
  >"$TMP/postgres.log" 2>&1 &
PG_PID=$!
ready=0
for _ in $(seq 1 300); do
  if run "$P/bin/pg_isready" -q -h 127.0.0.1 -p "$PORT" -t 1; then ready=1; break; fi
  kill -0 "$PG_PID" 2>/dev/null || break
  sleep 0.1
done
T_READY=$(now_ms)
[ "$ready" = 1 ] || { cat "$TMP/postgres.log"; fail "postgres did not become ready"; }
ok "pg_isready on port $PORT after $((T_READY - T_INITDB)) ms (start); $((T_READY - T0)) ms from extract"

PSQL=("$P/bin/psql" -X -h 127.0.0.1 -p "$PORT" -U postgres -d postgres -v ON_ERROR_STOP=1)

# ------------------------------------------------------------------ 3 SQL ----
step "3. version and CREATE EXTENSION pg_clickhouse"
run "${PSQL[@]}" -Atc 'SELECT version();'
run "${PSQL[@]}" -qc 'CREATE EXTENSION pg_clickhouse;'
DX="$(run "${PSQL[@]}" -c '\dx')"
printf '%s\n' "$DX"
printf '%s\n' "$DX" | grep -q 'pg_clickhouse' || fail "\\dx does not list pg_clickhouse"
EXT_VER="$(run "${PSQL[@]}" -Atc "SELECT extversion FROM pg_extension WHERE extname = 'pg_clickhouse';")"
ok "pg_clickhouse extension version $EXT_VER"
# Unix-socket connection in the bundle's own temp dir, too.
run "$P/bin/psql" -X -h "$TMP/sock" -p "$PORT" -U postgres -d postgres -Atc 'SELECT 1;' >/dev/null
ok "unix socket connection"

# ----------------------------------------------------------- 4 ClickHouse ----
step "4. pg_clickhouse against ClickHouse at $CH_HOST (http $CH_HTTP_PORT, native $CH_NATIVE_PORT)"
CH_RESULT=skipped
reachable() { (exec 3<>"/dev/tcp/$CH_HOST/$1") 2>/dev/null; }
if [ "$CH_MODE" = skip ]; then
  echo "SKIP: ClickHouse step disabled (PGB_SELFTEST_CLICKHOUSE=skip)"
elif ! reachable "$CH_HTTP_PORT" || ! reachable "$CH_NATIVE_PORT"; then
  [ "$CH_MODE" = require ] && fail "ClickHouse required but not reachable at $CH_HOST:$CH_HTTP_PORT/$CH_NATIVE_PORT"
  echo "SKIP: no ClickHouse reachable at $CH_HOST:$CH_HTTP_PORT/$CH_NATIVE_PORT (set CLICKHOUSE_HOST/PORT to enable)"
else
  TBL="t_$(date +%s)_$RANDOM"
  sqlq() { printf "%s" "$1" | sed "s/'/''/g"; }
  run "${PSQL[@]}" -q <<SQL
CREATE SERVER ch_http FOREIGN DATA WRAPPER clickhouse_fdw
  OPTIONS (driver 'http', host '$(sqlq "$CH_HOST")', port '$CH_HTTP_PORT', dbname 'pgb_selftest');
CREATE SERVER ch_bin FOREIGN DATA WRAPPER clickhouse_fdw
  OPTIONS (driver 'binary', host '$(sqlq "$CH_HOST")', port '$CH_NATIVE_PORT', dbname 'pgb_selftest');
CREATE USER MAPPING FOR CURRENT_USER SERVER ch_http
  OPTIONS (user '$(sqlq "$CH_USER")', password '$(sqlq "$CH_PASSWORD")');
CREATE USER MAPPING FOR CURRENT_USER SERVER ch_bin
  OPTIONS (user '$(sqlq "$CH_USER")', password '$(sqlq "$CH_PASSWORD")');
CREATE SERVER ch_setup FOREIGN DATA WRAPPER clickhouse_fdw
  OPTIONS (driver 'http', host '$(sqlq "$CH_HOST")', port '$CH_HTTP_PORT', dbname 'default');
CREATE USER MAPPING FOR CURRENT_USER SERVER ch_setup
  OPTIONS (user '$(sqlq "$CH_USER")', password '$(sqlq "$CH_PASSWORD")');
CALL clickhouse_perform('ch_setup', 'CREATE DATABASE IF NOT EXISTS pgb_selftest');
CALL clickhouse_perform('ch_http', \$\$
  CREATE TABLE $TBL (id UInt32, name String, ts DateTime) ENGINE = MergeTree ORDER BY id
\$\$);
CALL clickhouse_perform('ch_bin', \$\$
  INSERT INTO $TBL SELECT number, concat('row-', toString(number)), toDateTime('2026-01-01 00:00:00') + number
  FROM numbers(1000)
\$\$);
CREATE FOREIGN TABLE ft_http (id bigint, name text, ts timestamp) SERVER ch_http OPTIONS (table_name '$TBL');
CREATE FOREIGN TABLE ft_bin  (id bigint, name text, ts timestamp) SERVER ch_bin  OPTIONS (table_name '$TBL');
SQL
  HTTP_OUT="$(run "${PSQL[@]}" -Atc "SELECT count(*), sum(id), max(name) FROM ft_http WHERE id < 1000;")"
  BIN_OUT="$(run "${PSQL[@]}" -Atc "SELECT count(*), sum(id), max(name) FROM ft_bin WHERE id < 1000;")"
  JOIN_OUT="$(run "${PSQL[@]}" -Atc "SELECT count(*) FROM ft_http h JOIN ft_bin b USING (id) WHERE b.name LIKE 'row-9%';")"
  VER_OUT="$(run "${PSQL[@]}" -Atc "SELECT * FROM clickhouse_query('ch_bin', 'SELECT version()') AS t(v text);")"
  echo "http driver:   $HTTP_OUT"
  echo "binary driver: $BIN_OUT"
  echo "join:          $JOIN_OUT"
  echo "ClickHouse:    $VER_OUT"
  run "${PSQL[@]}" -qc "CALL clickhouse_perform('ch_http', 'DROP TABLE IF EXISTS $TBL');"
  [ "$HTTP_OUT" = "1000|499500|row-999" ] || fail "http driver query returned '$HTTP_OUT'"
  [ "$BIN_OUT" = "1000|499500|row-999" ] || fail "binary driver query returned '$BIN_OUT'"
  [ "$JOIN_OUT" = "111" ] || fail "join query returned '$JOIN_OUT'"
  ok "queried ClickHouse $VER_OUT through pg_clickhouse (http + binary drivers)"
  CH_RESULT="passed (ClickHouse $VER_OUT)"
fi

# ----------------------------------------------------------------- 5 stop ----
step "5. pg_ctl stop -m fast"
run "$P/bin/pg_ctl" -D "$TMP/data" stop -m fast -w >/dev/null
for _ in $(seq 1 50); do kill -0 "$PG_PID" 2>/dev/null || break; sleep 0.1; done
kill -0 "$PG_PID" 2>/dev/null && fail "postgres still running after pg_ctl stop"
PG_PID=""
ok "stopped"

# ------------------------------------------------------ 6 dep closure ----
step "6. dependency closure"
BAD=0
bad() { printf 'disallowed: %s\n' "$*" >&2; BAD=1; }
NBIN=0
if [ "$OS" = Darwin ]; then
  while IFS= read -r -d '' f; do
    file -b "$f" | grep -q '^Mach-O' || continue
    NBIN=$((NBIN + 1))
    rel="${f#"$P"/}"
    # Load commands: LC_ID_DYLIB (first line for dylibs) is skipped.
    skip_id=0; file -b "$f" | grep -q 'shared library' && skip_id=1
    while read -r dep; do
      if [ $skip_id = 1 ]; then skip_id=0; continue; fi
      case "$dep" in
        /usr/lib/*|/System/Library/*) ;;
        @rpath/*) [ -e "$P/lib/${dep#@rpath/}" ] || bad "$rel -> $dep (not in bundle lib/)" ;;
        *) bad "$rel -> $dep" ;;
      esac
    done < <(otool -L "$f" | tail -n +2 | awk '{print $1}')
    while read -r rp; do
      case "$rp" in
        @loader_path|@loader_path/*|@executable_path/*)
          res="$(cd "$(dirname "$f")/${rp#@loader_path}" 2>/dev/null && pwd -P)"
          [ "$res" = "$(cd "$P/lib" && pwd -P)" ] || bad "$rel rpath $rp resolves to $res, not lib/" ;;
        *) bad "$rel LC_RPATH $rp" ;;
      esac
    done < <(otool -l "$f" | awk '/cmd LC_RPATH/{getline; getline; print $2}')
    codesign -v "$f" 2>/dev/null || bad "$rel has an invalid code signature"
  done < <(find "$P/bin" "$P/lib" -type f -print0)
  # Runtime: every image dyld loaded into postgres / its backends (including
  # pg_clickhouse.dylib after CREATE EXTENSION) must be in the bundle or the OS.
  LOADED="$(grep -E '^dyld\[[0-9]+\]: <' "$TMP/postgres.log" | sed -E 's/^dyld\[[0-9]+\]: <[^>]*> //' | sort -u || true)"
  [ -n "$LOADED" ] || bad "no DYLD_PRINT_LIBRARIES output captured"
  RP="$(cd "$P" && pwd -P)"
  while read -r img; do
    [ -z "$img" ] && continue
    case "$img" in
      "$RP"/*|"$P"/*|/usr/lib/*|/System/Library/*|/System/Volumes/Preboot/Cryptexes/OS/*) ;;
      *) bad "runtime load of $img" ;;
    esac
  done <<<"$LOADED"
  printf '%s\n' "$LOADED" | grep -q 'pg_clickhouse.dylib' || bad "pg_clickhouse.dylib was never loaded"
  echo "runtime images loaded by postgres: $(printf '%s\n' "$LOADED" | wc -l | tr -d ' ') (all bundle/system)"
  echo "otool closure of all bundle Mach-O files:"
  find "$P/bin" "$P/lib" -type f -exec otool -L {} + 2>/dev/null | awk '/^\t/{print $1}' \
    | grep -v '^@rpath/' | sort | uniq -c | sort -rn
else
  ALLOWED_RE='^(libc\.so\.6|libm\.so\.6|libpthread\.so\.0|libdl\.so\.2|librt\.so\.1|libutil\.so\.1|ld-linux-x86-64\.so\.2|ld-linux-aarch64\.so\.1)$'
  if command -v readelf >/dev/null; then
    elf_needed() { readelf -d "$1" | sed -n 's/.*(NEEDED).*\[\(.*\)\]/\1/p'; }
    elf_rpath()  { readelf -d "$1" | sed -n 's/.*(R\(UN\)\{0,1\}PATH).*\[\(.*\)\]/\2/p'; }
  elif command -v objdump >/dev/null; then
    elf_needed() { objdump -p "$1" | awk '$1=="NEEDED"{print $2}'; }
    elf_rpath()  { objdump -p "$1" | awk '$1=="RUNPATH"||$1=="RPATH"{print $2}'; }
  else
    fail "need readelf or objdump (binutils) for the dependency check"
  fi
  MAXGLIBC=0.0
  while IFS= read -r -d '' f; do
    head -c 4 "$f" | grep -q 'ELF' || continue
    NBIN=$((NBIN + 1))
    rel="${f#"$P"/}"
    for n in $(elf_needed "$f"); do
      if [[ "$n" =~ $ALLOWED_RE ]]; then :; elif [ -e "$P/lib/$n" ]; then :; else bad "$rel NEEDED $n"; fi
    done
    for rp in $(elf_rpath "$f" | tr ':' ' '); do
      case "$rp" in '$ORIGIN'|'$ORIGIN/'*) ;; *) bad "$rel RPATH/RUNPATH $rp" ;; esac
    done
    if command -v ldd >/dev/null; then
      while read -r line; do
        case "$line" in
          *"not found"*) bad "$rel: $line" ;;
          *"=> $P/"*|*"=> /lib"*|*"=> /usr/lib"*|linux-vdso*|*ld-linux*|/lib*|"") ;;
          *"=>"*) bad "$rel resolves $line" ;;
        esac
      done < <(ldd "$f" 2>/dev/null | sed 's/^[[:space:]]*//' | grep -v 'statically linked' || true)
    fi
    if command -v objdump >/dev/null; then
      v="$(objdump -T "$f" 2>/dev/null | grep -o 'GLIBC_[0-9.]*' | sed 's/GLIBC_//' | sort -t. -k1,1n -k2,2n | tail -1)"
      if [ -n "$v" ] && [ "$(printf '%s\n%s\n' "$v" "$MAXGLIBC" | sort -t. -k1,1n -k2,2n | tail -1)" = "$v" ]; then MAXGLIBC="$v"; fi
    fi
  done < <(find "$P/bin" "$P/lib" -type f -print0)
  if [ "$MAXGLIBC" != 0.0 ]; then
    echo "highest GLIBC symbol version required: $MAXGLIBC"
    [ "$(printf '%s\n2.28\n' "$MAXGLIBC" | sort -t. -k1,1n -k2,2n | tail -1)" = 2.28 ] \
      || bad "requires GLIBC_$MAXGLIBC (> 2.28 baseline)"
  fi
  echo "NEEDED closure of all bundle ELF files:"
  find "$P/bin" "$P/lib" -type f -print0 | while IFS= read -r -d '' f; do
    head -c 4 "$f" | grep -q ELF && elf_needed "$f"; done | sort | uniq -c | sort -rn
fi
[ "$BAD" = 0 ] || fail "dependency closure contains disallowed libraries"
ok "$NBIN binaries checked, only system libraries and bundled libs"

# ---------------------------------------------------------------- summary ----
CSIZE="$(wc -c <"$TARBALL" | tr -d ' ')"
ESIZE="$(du -sk "$P" | awk '{print $1*1024}')"
step "summary"
awk -v n="$NAME" -v c="$CSIZE" -v e="$ESIZE" -v x="$((T_EXTRACT - T0))" -v i="$((T_INITDB - T_EXTRACT))" \
    -v s="$((T_READY - T_INITDB))" -v t="$((T_READY - T0))" -v ch="$CH_RESULT" 'BEGIN {
  printf "bundle:              %s\n", n
  printf "compressed size:     %d bytes (%.1f MiB)\n", c, c/1048576
  printf "extracted size:      %d bytes (%.1f MiB)\n", e, e/1048576
  printf "extract:             %d ms\n", x
  printf "initdb:              %d ms\n", i
  printf "start to pg_isready: %d ms\n", s
  printf "extract to ready:    %d ms\n", t
  printf "clickhouse step:     %s\n", ch
}'
if [ -n "${PGB_SELFTEST_REPORT:-}" ]; then
  cat >"$PGB_SELFTEST_REPORT" <<EOF
{"bundle": "$NAME", "compressed_bytes": $CSIZE, "extracted_bytes": $ESIZE,
 "extract_ms": $((T_EXTRACT - T0)), "initdb_ms": $((T_INITDB - T_EXTRACT)),
 "start_ms": $((T_READY - T_INITDB)), "extract_to_ready_ms": $((T_READY - T0)),
 "pg_clickhouse": "$EXT_VER", "clickhouse": "$CH_RESULT"}
EOF
fi
echo "SELFTEST PASSED: $NAME"
