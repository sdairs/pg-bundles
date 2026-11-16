#!/usr/bin/env bash
# Self-test a Linux bundle on a host where the invoking user is root: the
# default in `docker run`, and common on cloud VMs and CI sandboxes.
#
#   scripts/selftest-root.sh <bundle.tar.gz>         # must run as root
#   PGB_CONTAINER_USER=root scripts/selftest-container.sh <image> <bundle.tar.gz>
#
# PostgreSQL refuses to run as root (initdb, pg_ctl and postgres all exit
# with an error), so a caller that is root has to run the server as an
# unprivileged user. This script is the recipe, written the way a caller
# (clickhousectl) would do it, and it fails if any step does not work:
#
#   1. root extracts the bundle; it stays owned by root (read-only for the
#      server user). Every directory on the way to it must be searchable
#      (o+x) by the server user. A home directory with mode 0700, such as
#      /root, is not: either install the bundle outside it or `chmod o+x` it.
#   2. pick an unprivileged user that has an /etc/passwd entry (PostgreSQL
#      looks its own uid up): an existing one such as "nobody", or a new
#      system user.
#   3. root creates the instance directory and chowns it to that user; the
#      data directory, socket directory, password file and log file live in
#      it. Every directory on the way to it must be searchable by that user.
#   4. initdb and postgres run as that user (setuid/setgid, here through
#      setpriv or su), from a working directory the user can enter, with a
#      clean environment.
#   5. root keeps using the client tools (psql, pg_isready, pg_dump) itself,
#      and stops the server by signalling the postmaster (SIGINT, "fast").
#
# Two layouts are run, each end to end (initdb, start, CREATE EXTENSION
# pg_clickhouse, a parallel query, a ClickHouse query when one is reachable,
# stop):
#
#   home     under root's home: bundle in <t>/.clickhouse/postgres/<bundle>,
#            instance in <t>/project/.clickhouse/postgres/default, where <t>
#            is a fresh $HOME/.pgbroot.XXXXXX (so nothing real is touched);
#            server user "nobody". First as extracted, which must fail when
#            $HOME is 0700; then after `chmod o+x $HOME` (restored at the end).
#   outside  the same tree under a fresh /opt/pgbroot.XXXXXX (mode 0755);
#            server user a newly created system user (useradd or adduser),
#            or "nobody" when the image has neither. $HOME is not touched.
#
# It also prints the shared memory and IPC limits of the host (/dev/shm,
# SysV shm and semaphores) and what PostgreSQL chose with them.
#
# Environment: CLICKHOUSE_HOST, CLICKHOUSE_HTTP_PORT, CLICKHOUSE_NATIVE_PORT,
# CLICKHOUSE_USER, CLICKHOUSE_PASSWORD and PGB_SELFTEST_CLICKHOUSE
# (auto|require|skip) as for selftest.sh.
set -euo pipefail

TARBALL="${1:?usage: selftest-root.sh <bundle.tar.gz>}"
[ -f "$TARBALL" ] || { echo "error: $TARBALL not found" >&2; exit 1; }
TARBALL="$(cd "$(dirname "$TARBALL")" && pwd)/$(basename "$TARBALL")"
NAME="$(basename "$TARBALL" .tar.gz)"

CH_HOST="${CLICKHOUSE_HOST:-127.0.0.1}"
CH_HTTP_PORT="${CLICKHOUSE_HTTP_PORT:-8123}"
CH_NATIVE_PORT="${CLICKHOUSE_NATIVE_PORT:-9000}"
CH_USER="${CLICKHOUSE_USER:-default}"
CH_PASSWORD="${CLICKHOUSE_PASSWORD:-}"
CH_MODE="${PGB_SELFTEST_CLICKHOUSE:-auto}"

step() { printf '\n--- %s\n' "$*"; }
ok()   { printf 'ok: %s\n' "$*"; }
fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }

[ "$(uname -s)" = Linux ] || fail "this test is for Linux bundles"
[ "$(id -u)" = 0 ] || fail "run this test as root (use selftest.sh as an unprivileged user)"
HOME="${HOME:-/root}"
HOST_DESC="$(uname -sm)"
[ -r /etc/os-release ] && HOST_DESC="$(. /etc/os-release; echo "${PRETTY_NAME:-$ID}") $(uname -m)"

PG_PID=""
MADE_USER=""
T_HOME=""
T_OUT=""
SCRATCH=""
HOME_MODE="$(stat -c %a "$HOME")"
cleanup() {
  if [ -n "$PG_PID" ] && kill -0 "$PG_PID" 2>/dev/null; then
    kill -INT "$PG_PID" 2>/dev/null || true; sleep 1; kill -KILL "$PG_PID" 2>/dev/null || true
  fi
  chmod "$HOME_MODE" "$HOME" 2>/dev/null || true
  rm -rf ${T_HOME:+"$T_HOME"} ${T_OUT:+"$T_OUT"} ${SCRATCH:+"$SCRATCH"}
  if [ -n "$MADE_USER" ]; then userdel "$MADE_USER" 2>/dev/null || deluser "$MADE_USER" 2>/dev/null || true; fi
}
trap cleanup EXIT

now_ms() {
  # bash 5: EPOCHREALTIME; else GNU date %N (busybox date ignores %N).
  if [ -n "${EPOCHREALTIME:-}" ]; then local t="${EPOCHREALTIME/[.,]/}"; echo $((10#$t / 1000)); return; fi
  local t; t="$(date +%s%N 2>/dev/null || true)"
  case "$t" in *N|"") echo $(( $(date +%s) * 1000 )) ;; *) echo $((t / 1000000)) ;; esac
}

# ------------------------------------------------- dropping privileges ----
# What a caller does with setgroups()/setgid()/setuid() before exec. Here:
# setpriv (util-linux) where it can change ids, else su (busybox setpriv
# cannot). Both run the command from / with a clean environment: the server
# user usually cannot enter root's working directory.
if setpriv --help 2>&1 | grep -q -- '--reuid'; then DROP=setpriv; else DROP=su; fi
command -v "$DROP" >/dev/null || fail "neither setpriv (with --reuid) nor su is available"

shq() { local a; for a in "$@"; do printf " '%s'" "${a//\'/\'\\\'\'}"; done; }
as_user() { # as_user <user> <command> [<arg>...]
  local user="$1"; shift
  local envv=(env -i PATH=/usr/bin:/bin:/usr/sbin:/sbin HOME=/ LANG=C LC_ALL=C TZ=UTC)
  if [ "$DROP" = setpriv ]; then
    (cd / && exec setpriv --reuid="$(id -u "$user")" --regid="$(id -g "$user")" --clear-groups "${envv[@]}" "$@")
  else
    su -s /bin/sh "$user" -c "cd / && exec$(shq "${envv[@]}" "$@")"
  fi
}
# Client tools run as root itself.
as_root() { env -i PATH=/usr/bin:/bin:/usr/sbin:/sbin HOME="$HOME" LANG=C LC_ALL=C TZ=UTC PGPASSWORD="$PGPASS" "$@"; }

free_port() {
  local p
  for _ in $(seq 1 50); do
    p=$(( 20000 + (RANDOM * 32768 + RANDOM) % 40000 ))
    if ! (exec 3<>"/dev/tcp/127.0.0.1/$p") 2>/dev/null; then echo "$p"; return; fi
  done
  fail "no free port found"
}

# First directory from / down to $2 that user $1 cannot search, or nothing.
first_blocked() {
  local user="$1" rest="${2#/}" cur=""
  while [ -n "$rest" ]; do
    cur="$cur/${rest%%/*}"
    case "$rest" in */*) rest="${rest#*/}" ;; *) rest="" ;; esac
    as_user "$user" test -x "$cur" || { echo "$cur"; return; }
  done
}

# ------------------------------------------------------------------ host ----
step "host: $HOST_DESC, uid $(id -u), HOME=$HOME (mode $HOME_MODE)"
echo "privileges are dropped with: $DROP"
echo "/dev/shm: $(df -k /dev/shm 2>/dev/null | awk 'NR==2 {printf "%d MiB total, %d MiB free (%s)", $2/1024, $4/1024, $1}' || true)"
SHM_MIB="$(df -k /dev/shm 2>/dev/null | awk 'NR==2 {printf "%d", $2/1024}' || true)"
echo "SysV shm:  shmmax=$(cat /proc/sys/kernel/shmmax 2>/dev/null || echo '?') shmall=$(cat /proc/sys/kernel/shmall 2>/dev/null || echo '?') shmmni=$(cat /proc/sys/kernel/shmmni 2>/dev/null || echo '?')"
echo "SysV sem:  $(tr '\t' ' ' </proc/sys/kernel/sem 2>/dev/null || echo '?') (semmsl semmns semopm semmni)"
echo "nofile:    $(ulimit -Sn) soft, $(ulimit -Hn) hard"

# ----------------------------------------------------------- as root ----
step "0. PostgreSQL refuses to run as root"
SCRATCH="$(mktemp -d /tmp/pgbroot.XXXXXX)"
tar -xzf "$TARBALL" -C "$SCRATCH"
for prog in initdb pg_ctl postgres; do
  case "$prog" in
    initdb)   args=(-D "$SCRATCH/data") ;;
    pg_ctl)   args=(-D "$SCRATCH/data" status) ;;
    postgres) args=(-D "$SCRATCH/data") ;;
  esac
  if out="$("$SCRATCH/$NAME/bin/$prog" "${args[@]}" 2>&1)"; then
    fail "$prog ran as root"
  fi
  printf '%s as root: %s\n' "$prog" "$(printf '%s\n' "$out" | sed -n 1p)"
done
"$SCRATCH/$NAME/bin/psql" --version >/dev/null || fail "psql does not run as root"
ok "initdb, pg_ctl and postgres refuse uid 0; client tools (psql) run as root"
rm -rf "$SCRATCH"; SCRATCH=""

# ----------------------------------------------------------- scenario ----
PGPASS="selftest-$RANDOM$RANDOM"
RECIPES=()

# run_instance <label> <bundle dir> <instance dir> <server user>
run_instance() {
  local label="$1" B="$2" INST="$3" SU="$4"
  local uid gid port t0 t1 t2 ready=0 owner
  uid="$(id -u "$SU")"; gid="$(id -g "$SU")"

  # 3. The instance directory belongs to the server user.
  mkdir -p "$INST"
  chown "$uid:$gid" "$INST"
  chmod 700 "$INST"
  (umask 077 && printf '%s\n' "$PGPASS" >"$INST/pwfile")
  chown "$uid:$gid" "$INST/pwfile"

  # 4. initdb and postgres as the server user.
  t0=$(now_ms)
  as_user "$SU" "$B/bin/initdb" -D "$INST/data" -U postgres --auth=scram-sha-256 --pwfile="$INST/pwfile" \
    -E UTF8 --locale=C >"$INST/initdb.log" 2>&1 || { cat "$INST/initdb.log"; fail "$label: initdb as $SU"; }
  t1=$(now_ms)
  as_user "$SU" mkdir "$INST/run"
  port="$(free_port)"
  # pg_ctl starts the postmaster detached and waits until it accepts connections.
  as_user "$SU" "$B/bin/pg_ctl" -D "$INST/data" -l "$INST/postgres.log" -w -t 60 \
    -o "-p $port -k $INST/run -c listen_addresses=127.0.0.1" start >"$INST/pg_ctl.log" 2>&1 \
    || { cat "$INST/pg_ctl.log" "$INST/postgres.log" 2>/dev/null; fail "$label: pg_ctl start as $SU"; }
  PG_PID="$(sed -n 1p "$INST/data/postmaster.pid")"
  for _ in $(seq 1 100); do
    if as_root "$B/bin/pg_isready" -q -h 127.0.0.1 -p "$port" -t 1; then ready=1; break; fi
    sleep 0.1
  done
  t2=$(now_ms)
  [ "$ready" = 1 ] || { cat "$INST/postgres.log"; fail "$label: postgres did not become ready"; }
  owner="$(awk '/^Uid:/ {print $2}' "/proc/$PG_PID/status")"
  [ "$owner" = "$uid" ] || fail "$label: postmaster runs as uid $owner, expected $uid ($SU)"
  ok "$label: initdb $((t1 - t0)) ms, start to pg_isready $((t2 - t1)) ms; postmaster pid $PG_PID runs as $SU (uid $uid)"

  # 5. root uses the client tools itself, over TCP and the unix socket.
  local psql=("$B/bin/psql" -X -h 127.0.0.1 -p "$port" -U postgres -d postgres -v ON_ERROR_STOP=1)
  as_root "${psql[@]}" -Atc 'SELECT version();'
  as_root "$B/bin/psql" -X -h "$INST/run" -p "$port" -U postgres -d postgres -Atc 'SELECT 1;' >/dev/null
  as_root "${psql[@]}" -qc 'CREATE EXTENSION pg_clickhouse;'
  ok "$label: root connected with psql (TCP and unix socket); CREATE EXTENSION pg_clickhouse"

  # Shared memory: what initdb chose on this host, and a parallel query,
  # which allocates dynamic shared memory (in /dev/shm for "posix").
  echo "$label: $(as_root "${psql[@]}" -Atc "SELECT string_agg(name || '=' || current_setting(name), ', ' ORDER BY name) FROM pg_settings WHERE name IN ('shared_buffers', 'max_connections', 'shared_memory_type', 'dynamic_shared_memory_type', 'huge_pages')")"
  local plan workers=0
  plan="$(as_root "${psql[@]}" -At <<'SQL'
CREATE TABLE pgb_root_t AS SELECT g AS id, md5(g::text) AS v FROM generate_series(1, 200000) g;
ANALYZE pgb_root_t;
SET max_parallel_workers_per_gather = 2;
SET parallel_setup_cost = 0;
SET parallel_tuple_cost = 0;
SET min_parallel_table_scan_size = 0;
EXPLAIN (ANALYZE, COSTS OFF, TIMING OFF) SELECT count(*), max(a.v) FROM pgb_root_t a JOIN pgb_root_t b USING (id);
SQL
)"
  if [[ "$plan" =~ Workers\ Launched:\ ([0-9]+) ]]; then workers="${BASH_REMATCH[1]}"; fi
  [ "$workers" -ge 1 ] || fail "$label: parallel query launched no workers"
  ok "$label: parallel hash join launched $workers workers (dynamic shared memory works)"

  # pg_clickhouse against a local ClickHouse, when one is there.
  local reach=1
  (exec 3<>"/dev/tcp/$CH_HOST/$CH_NATIVE_PORT") 2>/dev/null || reach=0
  (exec 3<>"/dev/tcp/$CH_HOST/$CH_HTTP_PORT") 2>/dev/null || reach=0
  if [ "$CH_MODE" = skip ]; then
    echo "SKIP: ClickHouse step disabled (PGB_SELFTEST_CLICKHOUSE=skip)"
  elif [ "$reach" = 0 ]; then
    [ "$CH_MODE" = require ] && fail "ClickHouse required but not reachable at $CH_HOST:$CH_HTTP_PORT/$CH_NATIVE_PORT"
    echo "SKIP: no ClickHouse reachable at $CH_HOST:$CH_HTTP_PORT/$CH_NATIVE_PORT"
  else
    local q="s/'/''/g" ver
    as_root "${psql[@]}" -q <<SQL
CREATE SERVER ch_bin FOREIGN DATA WRAPPER clickhouse_fdw
  OPTIONS (driver 'binary', host '$(printf %s "$CH_HOST" | sed "$q")', port '$CH_NATIVE_PORT');
CREATE SERVER ch_http FOREIGN DATA WRAPPER clickhouse_fdw
  OPTIONS (driver 'http', host '$(printf %s "$CH_HOST" | sed "$q")', port '$CH_HTTP_PORT');
CREATE USER MAPPING FOR CURRENT_USER SERVER ch_bin
  OPTIONS (user '$(printf %s "$CH_USER" | sed "$q")', password '$(printf %s "$CH_PASSWORD" | sed "$q")');
CREATE USER MAPPING FOR CURRENT_USER SERVER ch_http
  OPTIONS (user '$(printf %s "$CH_USER" | sed "$q")', password '$(printf %s "$CH_PASSWORD" | sed "$q")');
SQL
    ver="$(as_root "${psql[@]}" -Atc "SELECT * FROM clickhouse_query('ch_bin', 'SELECT version()') AS t(v text);")"
    [ "$(as_root "${psql[@]}" -Atc "SELECT * FROM clickhouse_query('ch_http', 'SELECT sum(number) FROM numbers(1000)') AS t(v bigint);")" = 499500 ] \
      || fail "$label: http driver query returned a wrong result"
    [ -n "$ver" ] || fail "$label: binary driver query returned nothing"
    ok "$label: queried ClickHouse $ver through pg_clickhouse (binary + http drivers)"
    CH_RESULT="passed (ClickHouse $ver)"
  fi

  # 5. root stops the server by signalling the postmaster (SIGINT = fast).
  kill -INT "$PG_PID"
  for _ in $(seq 1 100); do kill -0 "$PG_PID" 2>/dev/null || break; sleep 0.1; done
  kill -0 "$PG_PID" 2>/dev/null && fail "$label: postgres still running 10 s after SIGINT"
  PG_PID=""
  [ ! -e "$INST/data/postmaster.pid" ] || fail "$label: postmaster.pid left behind"
  [ "$(stat -c %u "$INST/data/PG_VERSION")" = "$uid" ] || fail "$label: data directory is not owned by $SU"
  [ "$(stat -c %u "$B/bin/postgres")" = 0 ] || fail "$label: bundle is not owned by root"
  ok "$label: stopped with SIGINT from root; data owned by $SU, bundle owned by root"
  RECIPES+=("$label: bundle $B (root-owned), instance $INST (owned by $SU, uid $uid), privileges dropped with $DROP")
}

CH_RESULT=skipped

# ---------------------------------------------------- layout 1: home ----
step "1. bundle and project under root's home ($HOME, mode $HOME_MODE), server user nobody"
id nobody >/dev/null 2>&1 || fail "this image has no 'nobody' user"
T_HOME="$(mktemp -d "$HOME/.pgbroot.XXXXXX")"
chmod 755 "$T_HOME"
B1="$T_HOME/.clickhouse/postgres/$NAME"
I1="$T_HOME/project/.clickhouse/postgres/default"
mkdir -p "$(dirname "$B1")" "$(dirname "$I1")"
tar -xzf "$TARBALL" -C "$(dirname "$B1")"
blocked="$(first_blocked nobody "$B1/bin")"
if [ -n "$blocked" ]; then
  echo "nobody cannot search $blocked (mode $(stat -c %a "$blocked"), owner $(stat -c %U "$blocked")):"
  if out="$(as_user nobody "$B1/bin/postgres" --version 2>&1)"; then
    fail "expected $B1/bin/postgres to be unreachable for nobody"
  fi
  printf '  %s\n' "$(printf '%s\n' "$out" | sed -n 1p)"
  [ "$blocked" = "$HOME" ] || fail "only $HOME was expected to block nobody, got $blocked"
  ok "as extracted, a bundle under $HOME cannot be run by an unprivileged user"
  # The one change that makes it work: let others search (not list) $HOME.
  chmod o+x "$HOME"
  echo "chmod o+x $HOME (now mode $(stat -c %a "$HOME"))"
  [ -z "$(first_blocked nobody "$B1/bin")" ] || fail "nobody still cannot reach $B1/bin"
else
  echo "nobody can already search every directory down to $B1/bin"
fi
as_user nobody "$B1/bin/postgres" --version
run_instance "home" "$B1" "$I1" nobody
chmod "$HOME_MODE" "$HOME"

# ------------------------------------------------- layout 2: outside ----
step "2. bundle and project outside root's home, dedicated server user"
SU2=nobody
if command -v useradd >/dev/null 2>&1; then
  useradd --system --no-create-home --home-dir / --shell /sbin/nologin pgbundle
  SU2=pgbundle; MADE_USER=pgbundle
  echo "created system user pgbundle with useradd (uid $(id -u pgbundle))"
elif command -v adduser >/dev/null 2>&1; then
  adduser -S -D -H -h / -s /sbin/nologin pgbundle
  SU2=pgbundle; MADE_USER=pgbundle
  echo "created system user pgbundle with adduser (uid $(id -u pgbundle))"
else
  echo "no useradd or adduser in this image; using nobody"
fi
mkdir -p /opt
T_OUT="$(mktemp -d /opt/pgbroot.XXXXXX)"
chmod 755 "$T_OUT"
B2="$T_OUT/.clickhouse/postgres/$NAME"
I2="$T_OUT/project/.clickhouse/postgres/default"
mkdir -p "$(dirname "$B2")" "$(dirname "$I2")"
tar -xzf "$TARBALL" -C "$(dirname "$B2")"
[ -z "$(first_blocked "$SU2" "$B2/bin")" ] || fail "$SU2 cannot reach $B2/bin"
[ -z "$(first_blocked "$SU2" "$(dirname "$I2")")" ] || fail "$SU2 cannot reach $(dirname "$I2")"
run_instance "outside" "$B2" "$I2" "$SU2"

# --------------------------------------------------------------- summary ----
step "summary"
echo "bundle:              $NAME"
echo "host:                $HOST_DESC (invoking user: root)"
echo "/dev/shm:            ${SHM_MIB:-?} MiB"
for r in "${RECIPES[@]}"; do echo "worked:              $r"; done
echo "clickhouse step:     $CH_RESULT"
echo "SELFTEST PASSED (as root): $NAME"
