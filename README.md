# pg-bundles

Portable, relocatable PostgreSQL builds with
[pg_clickhouse](https://github.com/ClickHouse/pg_clickhouse) pre-installed, so
`clickhousectl` can run local Postgres without Docker. See [SPEC.md](SPEC.md) for
the motivation, requirements and the reasoning behind the platform baselines.

The bundles are for **local development**: a local Postgres next to a local
ClickHouse, with pg_clickhouse pointed at it. They are not for production.
They aim to run on as many macOS and Linux systems as practical with nothing
installed on the host.

A bundle is a tarball you can extract anywhere and run:

```bash
tar -xzf pg-18.7-pgch-0.11.1-aarch64-apple-darwin.tar.gz
cd pg-18.7-pgch-0.11.1-aarch64-apple-darwin
bin/initdb -D /tmp/pgdata -U postgres --auth=trust
bin/pg_ctl -D /tmp/pgdata -l /tmp/pg.log start
bin/psql -U postgres -c 'CREATE EXTENSION pg_clickhouse'
```

The versions in the examples here (PostgreSQL 17.12 and 18.7, pg_clickhouse
0.11.1) are the ones pinned when this was written. The current ones are in
[`scripts/versions.env`](scripts/versions.env) and in each release's
[`manifest.json`](#release-manifest); [scheduled rebuilds](#scheduled-rebuilds)
move them forward.

## Outputs

PostgreSQL **17** and **18** (the latest minor of each), each for four targets
(Rust-style triples, as used by `chctl`): 8 bundles per release.

| Target | Built in | Runs on |
| --- | --- | --- |
| `aarch64-apple-darwin` | macOS arm64 | macOS 11.0+ |
| `x86_64-apple-darwin` | macOS Intel (`macos-15-intel` in CI) | macOS 10.13+ |
| `x86_64-unknown-linux-musl` | Alpine 3.24 container | any Linux: glibc or musl (Alpine), any version; no host libraries |
| `aarch64-unknown-linux-musl` | Alpine 3.24 container | any Linux: glibc or musl (Alpine), any version; no host libraries |

The Linux bundles carry their own musl C library and loader, so one bundle
runs on every distro; see [musl bundles](#musl-bundles). There are no
`-unknown-linux-gnu` bundles (releases up to v0.2.0 had them; `chctl` only
ever picks `-musl`).

Each build writes two files to `dist/`:

```
dist/pg-<pgversion>-pgch-<pgchversion>-<target>.tar.gz
dist/pg-<pgversion>-pgch-<pgchversion>-<target>.tar.gz.sha256
```

e.g. `pg-17.12-pgch-0.11.1-x86_64-unknown-linux-musl.tar.gz`. The tarball has a
single top-level directory named like the archive:

```
pg-18.7-pgch-0.11.1-<target>/
  bin/        postgres, initdb, pg_ctl, psql, pg_isready, pg_dump, pg_restore, pg_config, …
  lib/        libpq, libssl, libcrypto, liblz4, libzstd, libecpg, libpgtypes
              (Linux: also ld-musl-<arch>.so.1, the musl loader and libc)
  lib/postgresql/   server modules: pg_clickhouse, contrib, PL/pgSQL, encoding conversions
  libexec/    Linux only: the real executables (bin/ holds launchers)
  share/postgresql/ timezone data, extension control/SQL files (incl. pg_clickhouse)
  share/licenses/   licences of PostgreSQL, pg_clickhouse and every bundled library
  BUNDLE.json       versions, target, build time, source commit, configure flags
```

`BUNDLE.json` example:

```json
{
  "postgres_version": "18.7",
  "extensions": { "pg_clickhouse": "0.11.1" },
  "target": "aarch64-apple-darwin",
  "built_at": "2026-11-16T16:34:11Z",
  "source": { "repo": "sdairs/pg-bundles", "commit": "…" },
  "configure": ["--prefix=/pgbundle", "--with-openssl", "--without-icu", "--with-lz4", "--with-zstd", "--with-libedit-preferred", "--disable-rpath"],
  "dependencies": { "openssl": "3.5.9", "curl": "8.23.0", "lz4": "1.11.1", "zstd": "1.5.7" },
  "platform": { "min_macos": "11.0", "openssldir": "/private/etc/ssl" }
}
```

Linux bundles also list zlib, libedit, ncurses, libuuid and musl under
`dependencies`, and `platform` is:

```json
  "platform": { "libc": "musl", "bundled_loader": "lib/ld-musl-aarch64.so.1", "host_libc": ["glibc", "musl"], "openssldir": "/etc/ssl" }
```

## What is inside

All sources are pinned by version and sha256 in
[`scripts/versions.env`](scripts/versions.env); the build refuses a download
whose hash does not match.

| Component | How it is linked |
| --- | --- |
| PostgreSQL (+ contrib), majors 17 and 18 | — |
| pg_clickhouse | `lib/postgresql/pg_clickhouse.{so,dylib}` |
| OpenSSL (3.5, the current 3.x LTS series) | shared, shipped in `lib/` |
| lz4 | shared, shipped in `lib/` |
| zstd | shared, shipped in `lib/` |
| curl (HTTP/HTTPS only, OpenSSL backend) | static, inside pg_clickhouse |
| musl, Linux only | shared: `lib/ld-musl-<arch>.so.1` (loader and libc in one) |
| zlib (Linux; the OS library on macOS) | static on Linux |
| libedit, psql line editing (Linux; the OS library on macOS) | static on Linux |
| ncurses, libedit's terminfo backend (Linux only) | static |
| libuuid from util-linux (Linux; libSystem on macOS) | static, inside pg_clickhouse |

OpenSSL, lz4 and zstd are shared because postgres, libpq, every client tool,
pgcrypto, sslinfo and pg_clickhouse all use them; linking them statically
copied libcrypto into each binary and more than doubled the bundle size.
libedit is used instead of GNU readline so that bundling it does not bring
GPLv3 terms into psql. ICU is left out (`--without-icu`): smaller bundle, and
local development uses the C/libc collations.

Every binary finds bundled libraries relative to itself, through `@rpath` +
`@loader_path` on macOS and `$ORIGIN` RUNPATHs on Linux. PostgreSQL itself
locates `share/` and `lib/postgresql/` relative to the running binary. The only
remaining dynamic dependencies are OS libraries on macOS (`libSystem`, `libz`,
`libedit`, CoreFoundation and SystemConfiguration); on Linux there are none.

### musl bundles

PostgreSQL loads contrib and pg_clickhouse with `dlopen`, so it cannot be a
fully static musl binary the way `chctl` is. The Linux bundles are instead
dynamically linked against musl, built in Alpine, and ship Alpine's musl
loader (`lib/ld-musl-<arch>.so.1`, which is also musl's libc). Because an
ELF program interpreter path cannot be relative, the real executables are in
`libexec/`, and every `bin/<name>` is the same small static launcher
([`scripts/launcher.c`](scripts/launcher.c), hard-linked under each name). It
runs

```
<bundle>/libexec/ld/<name> --library-path=<bundle>/lib --preload= \
    --argv0=<bundle>/bin/<name> -- <bundle>/libexec/<name> <args>
```

where `libexec/ld/<name>` is a symlink to the bundled loader, so the process is
still called `postgres`, `psql`, … in `top` and `pgrep`. `--argv0` makes
PostgreSQL see `bin/<name>` as its own path, so it finds `share/`, `lib/` and
its sibling programs (`pg_ctl` → `postgres`, `initdb` → `postgres`) as usual.
Symlinking `bin/psql` into `~/.local/bin` works.

The only host requirements are a Linux kernel and `/bin/sh` (which PostgreSQL
uses for `pg_ctl` and `initdb`). Differences from a glibc build of PostgreSQL:

- `ps` shows the loader command line, and PostgreSQL's process titles
  (`postgres: checkpointer`, …) are squeezed into the `--argv0` argument.
- Text sorts in code-point order whatever the locale (`LANG=en_US.UTF-8` is
  accepted); with `--locale=C` or the PostgreSQL 17+ `builtin` provider the
  result is the same on every platform anyway.
- User lookup reads `/etc/passwd` (and nscd), not NSS, so the user that runs
  `initdb` and `postgres` needs an `/etc/passwd` entry: an LDAP/sssd user
  without one, or an arbitrary `docker run --user 1234`, fails with `could not
  look up effective user ID`. DNS uses `/etc/hosts` and `/etc/resolv.conf`.
- musl's allocator is slower than glibc's; irrelevant for local development.
- `libexec/` binaries cannot be run directly on a glibc host; always use `bin/`.

## Build

### macOS

Needs the Xcode command line tools. Nothing from Homebrew is used: the build
runs with `PATH=/usr/bin:/bin:/usr/sbin:/sbin`, an empty pkg-config search path
and no `CPATH`/`LIBRARY_PATH`.

```bash
scripts/build.sh
```

The script builds for the host (`aarch64-apple-darwin` on Apple silicon,
`x86_64-apple-darwin` on Intel); cross builds are not supported, but
`arch -x86_64 /bin/bash scripts/build.sh` builds the Intel bundle under
Rosetta. The deployment target defaults to 11.0 (arm64) and 10.13 (x86_64),
and everything is compiled with `-Werror=unguarded-availability-new`, so an
unguarded use of a newer macOS API fails the build.

`PG_MAJOR=17 scripts/build.sh` builds PostgreSQL 17 instead of 18 (versions in
[`scripts/versions.env`](scripts/versions.env)).

### Linux

Needs Docker. The build runs inside the digest-pinned `alpine:3.24.2` image
(musl 1.2.6, GCC 15):

```bash
scripts/build-linux.sh                       # Docker host's arch, PostgreSQL 18
scripts/build-linux.sh x86_64                # arch: aarch64|x86_64; a foreign arch runs under emulation
PG_MAJOR=17 scripts/build-linux.sh aarch64
```

`scripts/build.sh` itself also runs directly on a musl host (Alpine). It
refuses a glibc host: only musl bundles are built.

### Caching and options

Downloads are cached in `.build/sources/`. Dependencies are built once per
target in `.build/<target>/`, PostgreSQL and pg_clickhouse once per target and
PostgreSQL version in `.build/<target>/pg-<version>/`; each step leaves a stamp,
so a rerun only repackages (seconds), and the second PostgreSQL major reuses
the dependencies. Both `.build/`
and `dist/` are gitignored.

| Variable | Effect |
| --- | --- |
| `PG_MAJOR=17\|18` | PostgreSQL major (default 18) |
| `JOBS=<n>` | parallel make jobs (default: CPU count) |
| `PGB_CLEAN=1` | wipe `.build/<target>/` first; needed after changing a build recipe |
| `PGB_KEEP_INCLUDE=1` | keep `include/` and PGXS so more extensions can be built against the bundle |

A clean build takes about 4 minutes on an M-series Mac and 2–3 minutes for
aarch64 Linux in Docker on the same machine; the second PostgreSQL major
takes 1–2 minutes more.

## Test

```bash
scripts/selftest.sh dist/pg-18.7-pgch-0.11.1-aarch64-apple-darwin.tar.gz
```

The self-test follows SPEC.md: it verifies the `.sha256`, extracts the bundle
into a fresh `/tmp/pgbst.XXXXXX` directory and, with a scrubbed environment
(no `DYLD_*`/`LD_*`, system `PATH` only), runs `initdb` with a password file,
starts `postgres` on a free port, waits for `pg_isready`, runs
`SELECT version()`, `CREATE EXTENSION pg_clickhouse` and `\dx`, checks which
shared objects a backend actually loaded, stops the server with
`pg_ctl stop -m fast` and checks the dependency closure.

When a ClickHouse server is reachable, the self-test also creates foreign
servers for both pg_clickhouse drivers (`http` and `binary`), creates and fills
a table in ClickHouse with `clickhouse_perform()`, and checks queries through
foreign tables and `clickhouse_query()`. Otherwise it logs `SKIP:` and carries on.
To get a server locally:

```bash
docker run -d --name ch -p 8123:8123 -p 9000:9000 clickhouse/clickhouse-server
# or: chctl local server start
# or, without Docker on macOS: scripts/start-clickhouse-macos.sh
```

| Variable | Default |
| --- | --- |
| `CLICKHOUSE_HOST` | `127.0.0.1` |
| `CLICKHOUSE_HTTP_PORT` / `CLICKHOUSE_NATIVE_PORT` | `8123` / `9000` |
| `CLICKHOUSE_USER` / `CLICKHOUSE_PASSWORD` | `default` / empty |
| `PGB_SELFTEST_CLICKHOUSE` | `auto`; `require` fails when ClickHouse is unreachable, `skip` never runs the step |
| `PGB_SELFTEST_REPORT` | optional path for a JSON summary (sizes, timings) |
| `PGB_SELFTEST_KEEP=1` | keep the temp directory |

The dependency checks are strict:

- **macOS**: every `LC_LOAD_DYLIB` must be under `/usr/lib` or
  `/System/Library`, or `@rpath/<lib>` that exists in the bundle's `lib/`;
  every `LC_RPATH` must be `@loader_path`-relative and resolve to `lib/`; every
  code signature must be valid; and every Mach-O file's minimum macOS
  (`LC_BUILD_VERSION` minos) must be at most `BUNDLE.json` `min_macos`. The
  postmaster also runs with `DYLD_PRINT_LIBRARIES=1`, and every image loaded
  at runtime, including `pg_clickhouse.dylib` and its dependencies after
  `CREATE EXTENSION`, must come from the bundle or the OS. A library from
  `/opt/homebrew` or `/usr/local` fails the test.
- **Linux, at runtime**: a backend loads pg_clickhouse, queries ClickHouse
  through both drivers and reads its own `/proc/self/maps` with
  `pg_read_file`. Every mapped shared object must be from the bundle; nothing
  from the host is allowed, libc included.
- **Linux, static**: every `NEEDED` entry must be musl's libc or a file in the
  bundle's `lib/`; every RPATH/RUNPATH must start with `$ORIGIN`; libraries
  must resolve inside the bundle (the bundled loader's `--list`); no `GLIBC_`
  symbol version may be referenced, and the launchers must be static. These
  checks need `readelf` or `objdump`; in a container without binutils they
  are skipped with a `SKIP:` line and the runtime check still runs.

The self-test prints compressed and extracted size and the times for extract,
initdb, start to `pg_isready`, and extract to `pg_isready`.

To run the self-test for a Linux bundle inside another distro, as a non-root
user, use `scripts/selftest-container.sh`. It installs nothing except bash and
binutils on images that have no bash (Alpine). From a Mac, share the
ClickHouse container's network so `127.0.0.1` reaches it:

```bash
docker run -d --name ch -p 8123:8123 -p 9000:9000 clickhouse/clickhouse-server
export PGB_DOCKER_NETWORK=container:ch PGB_SELFTEST_CLICKHOUSE=require
for image in alpine:3.24 centos:7 debian:10 ubuntu:24.04; do
  scripts/selftest-container.sh "$image" dist/pg-18.7-pgch-0.11.1-aarch64-unknown-linux-musl.tar.gz
done
```

### Running as root

PostgreSQL refuses to run as root: `initdb`, `pg_ctl` and `postgres` exit with
`cannot be run as root`. The client tools (`psql`, `pg_isready`, `pg_dump`) do
run as root. Root is the default user of `docker run` and common on cloud VMs
and CI sandboxes, so [`scripts/selftest-root.sh`](scripts/selftest-root.sh)
tests what a caller that is root has to do, and CI runs it for every Linux
bundle in Alpine, CentOS 7 and Debian 10 containers:

```bash
PGB_CONTAINER_USER=root scripts/selftest-container.sh debian:10 dist/pg-18.7-pgch-0.11.1-aarch64-unknown-linux-musl.tar.gz
```

The recipe that works (as root; `$B` is the extracted bundle, `$I` the
instance directory, `$U` the server user):

```bash
# 1. The bundle stays owned by root. Every directory down to it must be
#    searchable by $U; a 0700 home such as /root is not (see below).
mkdir -p /opt/pg-bundles
tar -xzf pg-18.7-pgch-0.11.1-x86_64-unknown-linux-musl.tar.gz -C /opt/pg-bundles
# 2. A server user with an /etc/passwd entry: an existing one ("nobody"), or
#    a new system user (useradd --system …; adduser -S … on Alpine).
U=nobody
# 3. The instance directory (data, socket, log, password file) belongs to $U.
mkdir -p "$I" && chown "$U" "$I" && chmod 700 "$I"
(umask 077 && printf '%s\n' "$PASSWORD" >"$I/pwfile") && chown "$U" "$I/pwfile"
# 4. initdb and postgres run as $U, from a directory $U can enter (/), with
#    a clean environment. setpriv is what setgroups/setgid/setuid do in code;
#    `su -s /bin/sh $U -c '…'` is the fallback (busybox setpriv cannot do it).
drop() { (cd / && setpriv --reuid="$(id -u "$U")" --regid="$(id -g "$U")" --clear-groups "$@"); }
drop "$B/bin/initdb" -D "$I/data" -U postgres --auth=scram-sha-256 --pwfile="$I/pwfile" -E UTF8 --locale=C
drop "$B/bin/pg_ctl" -D "$I/data" -l "$I/postgres.log" -w -o "-p 5432 -k $I/run -c listen_addresses=127.0.0.1" start
# 5. root uses the client tools itself, and stops the server with a signal.
"$B/bin/psql" -h 127.0.0.1 -p 5432 -U postgres -c 'CREATE EXTENSION pg_clickhouse'
kill -INT "$(head -1 "$I/data/postmaster.pid")"     # "fast" shutdown
```

Which paths the server user must be able to reach:

- **The bundle**: read and search access to the whole tree (it is extracted
  with modes 0755/0644, so root ownership is fine), and search (`x`) on every
  directory above it. `/root` is mode 0700 on Debian, Ubuntu and Alpine and
  0550 on CentOS, so a bundle under `/root/.clickhouse/postgres/` cannot be
  executed by another user as extracted: running `bin/postgres` fails with
  `Permission denied`. Either `chmod o+x /root` (others can then pass through `/root` to
  paths they already know, but still cannot list it; the test runs this
  layout too), or install the bundle outside root's home (`/opt`, `/usr/local`,
  `/var/lib`).
- **The instance directory**: owned by the server user, and again every
  directory above it searchable by that user. A project under `/root` has the
  same problem as the bundle.
- **The working directory** does not have to be reachable (`initdb` and
  `pg_ctl` ran from `/root` without warnings), but `cd /` avoids surprises.

Shared memory and IPC in containers, measured with these bundles:

- The server allocates about 1.1 MiB in `/dev/shm` at start
  (`dynamic_shared_memory_type=posix`, chosen by `initdb`), and a 56-byte
  SysV segment; `shared_buffers` (128 MiB) is anonymous `mmap`, not `/dev/shm`.
  Docker's default 64 MiB `/dev/shm` is enough to start and for ordinary
  queries.
- A parallel query allocates its shared state in `/dev/shm`: with the default
  64 MiB, a parallel hash join over 2 million rows with `work_mem=256MB`
  failed with `could not resize shared memory segment … No space left on
  device`. With `--shm-size=1m`, `initdb` itself fails that way.
- `-c dynamic_shared_memory_type=sysv` (for `initdb` and `postgres`) avoids
  `/dev/shm` altogether: the same join passed with 64 MiB and 1 MiB
  `/dev/shm`. Default containers have no practical SysV limits
  (`shmmax`/`shmall` about 16 EiB, `shmmni` 4096), and PostgreSQL on Linux uses
  POSIX semaphores, so the SysV semaphore limits do not matter.

## Measured locally

Measured on an M-series Mac (macOS 26.7), 2026-11-16, with the `aarch64` Linux
bundles in Docker containers (OrbStack) on the same machine. Sizes are what
the self-test measured after extraction.

| Bundle | Compressed | Extracted | Passed the self-test (with ClickHouse) on | initdb | Start to `pg_isready` | Extract to `pg_isready` |
| --- | ---: | ---: | --- | ---: | ---: | ---: |
| `pg-18.7-…-aarch64-apple-darwin` | 10.9 MiB | 36.5 MiB | macOS 26.7 | 3.2 s | 0.4 s | 3.9 s |
| `pg-17.12-…-aarch64-apple-darwin` | 10.7 MiB | 35.8 MiB | macOS 26.7 | 3.0 s | 0.3 s | 3.5 s |
| `pg-18.7-…-aarch64-unknown-linux-musl` | 13.5 MiB | 42.7 MiB | Alpine 3.24, CentOS 7, Debian 10, Ubuntu 24.04 | 1.2–2.6 s | 0.1 s | 1.6–3.1 s |
| `pg-17.12-…-aarch64-unknown-linux-musl` | 13.1 MiB | 41.7 MiB | Alpine 3.24, CentOS 7, Debian 10, Ubuntu 24.04 | 1.5–2.7 s | 0.1 s | 1.8–3.1 s |

The PostgreSQL 18 Linux bundle also passed the [root test](#running-as-root)
in the same four distros.

Most of the time goes to `initdb`; starting the server takes about 0.1–0.4 s.
CI measures the x86_64 bundles on GitHub-hosted runners (Intel macOS 15,
Ubuntu 24.04 and the distro containers); see the job summaries and release
notes.

The Linux bundles are larger once extracted because aarch64 ELF objects are
aligned to 64 KiB pages (needed for 64K-page kernels); that padding compresses
away.

## CI and releases

[`.github/workflows/build.yml`](.github/workflows/build.yml) runs on pushes to
`main`, pull requests, `v*` tags and manual dispatch, and is called by the
[scheduled rebuild](#scheduled-rebuilds). Every job runs for PostgreSQL 17 and
18:

- `linux` job: `x86_64` on `ubuntu-24.04`, `aarch64` on `ubuntu-24.04-arm`. It
  builds in the Alpine container, then self-tests on the runner (Ubuntu 24.04,
  glibc) against a `clickhouse/clickhouse-server` service container, again as
  an unprivileged user in `alpine:3.24`, `centos:7` (glibc 2.17) and
  `debian:10` (glibc 2.28) containers, and [as root](#running-as-root) in the
  same three.
- `macos` job: `aarch64-apple-darwin` on `macos-15`, `x86_64-apple-darwin` on
  `macos-15-intel`. Hosted macOS runners have no service containers, so
  `scripts/start-clickhouse-macos.sh` starts a pinned, sha256-verified
  ClickHouse release binary natively.
- On every job the ClickHouse step is required (`PGB_SELFTEST_CLICKHOUSE=require`),
  and every self-test summary is added to the job summary. Each job uploads
  `bundle-pg<major>-<target>` with the tarball, `.sha256` and `.selftest.json`.
- `manifest` job (every run): downloads the 8 artifacts, generates
  `manifest.json` and validates it: every PostgreSQL major × target present
  with the pinned versions, built from this commit, sha256 and size equal to
  the file and its `.sha256`. A pull request therefore checks the manifest a
  release would publish (with the placeholder release `v0.0.0-dev`).
- `release` job (`v*` tags and scheduled rebuilds only): validates again,
  signs a [build provenance attestation](#verifying-a-download) for the
  tarballs, and creates the GitHub release with every tarball, `.sha256` and
  `manifest.json`. The release notes include a table of sizes and timings
  from the self-tests.

All actions are pinned to commit SHAs, and the build and test container images
are pinned by digest.

To release by hand:

```bash
git tag v0.3.0   # any tag starting with v
git push origin v0.3.0
```

The repo is public, so release assets download without authentication:

```
https://github.com/sdairs/pg-bundles/releases/latest/download/manifest.json
https://github.com/sdairs/pg-bundles/releases/download/<tag>/<file>
```

### Release manifest

Every release carries `manifest.json`, so a client needs one unauthenticated
request (no GitHub API) to find its bundle:

```json
{
  "schema": 1,
  "release": "v0.3.0",
  "built_at": "2026-11-16T00:00:00Z",
  "source": { "repo": "sdairs/pg-bundles", "commit": "<sha>" },
  "bundles": [
    {
      "postgres_version": "18.7",
      "postgres_major": "18",
      "extensions": { "pg_clickhouse": "0.11.1" },
      "target": "aarch64-apple-darwin",
      "file": "pg-18.7-pgch-0.11.1-aarch64-apple-darwin.tar.gz",
      "sha256": "<64 hex>",
      "size": 11370169
    }
  ]
}
```

- `file` is relative to the manifest's own URL, so the manifest does not name
  its host: moving the files (to another repo, or to `builds.clickhouse.com`)
  is a change of the one URL the client starts from.
- There is exactly one bundle per `postgres_major` × `target`. Bundle names
  have no build revision; two releases can carry the same name with different
  bytes (a dependency changed), so cache by name **and** `sha256`.
- `sha256` and `size` are of the `.tar.gz`. The `.sha256` sidecars are still
  published next to each tarball.

[`scripts/manifest.py`](scripts/manifest.py) (Python 3, standard library only)
writes and checks it, in CI and locally:

```bash
scripts/manifest.py generate --release v0.3.0      # reads dist/, writes dist/manifest.json
scripts/manifest.py validate                       # dist/manifest.json against dist/ and versions.env
```

### Choosing a bundle (for `chctl`)

Fetch `manifest.json`, then take the entry whose `target` is `chctl`'s own
target triple (`<arch>-apple-darwin`, or `<arch>-unknown-linux-musl` on every
Linux, so no libc detection is needed) and whose `postgres_major` is the
requested major. Download `file` from next to the manifest and check `sha256`.

### Verifying a download

```bash
shasum -a 256 -c pg-18.7-pgch-0.11.1-aarch64-apple-darwin.tar.gz.sha256
gh attestation verify pg-18.7-pgch-0.11.1-aarch64-apple-darwin.tar.gz -R sdairs/pg-bundles
```

The release job signs a [build provenance
attestation](https://docs.github.com/en/actions/security-for-github-actions/using-artifact-attestations)
(`actions/attest-build-provenance`) for every tarball, as `clickhousectl`'s own
release does: it proves the file was built by this repository's workflow from
the recorded commit. Releases up to v0.2.0 have none.

### Scheduled rebuilds

[`.github/workflows/update.yml`](.github/workflows/update.yml) runs every
Monday (and on manual dispatch) and releases new upstream versions without a
human:

1. `scripts/check-updates.py --write` looks for newer releases and updates
   `scripts/versions.env` (version and sha256). Nothing newer: the run ends.
2. The bump is committed and pushed to a temporary branch
   `auto-update/<run id>`.
3. `build.yml` is called (`workflow_call`) for exactly that commit: all 8
   bundles are built and pass every self-test, and the manifest is validated.
4. Only then the `release` job fast-forwards `main` to the commit, and
   creates the next tag (patch + 1 of the highest `vX.Y.Z` tag) and the
   release at that commit. The temporary branch is deleted either way.

Refs written with the default `GITHUB_TOKEN` do not trigger other workflows,
so the design does not depend on "open a pull request and let CI run": the
scheduled run builds, tests and releases in one workflow run, and the bundles
that were tested are the files that are released. If any self-test fails,
`main` is untouched and nothing is tagged; the next run tries again. If
`main` moved while the build ran, the fast-forward fails and nothing is
released. The workflow token must be allowed to push to `main`: a branch
rule that requires pull requests would block the fast-forward.

What `scripts/check-updates.py` tracks:

| Source | Newer means | Version from | Hash checked against |
| --- | --- | --- | --- |
| PostgreSQL | latest minor of each major in `PG_MAJORS` | ftp.postgresql.org listing | upstream `.sha256` |
| pg_clickhouse | latest stable release | PGXN | sha1 in PGXN `META.json` |
| OpenSSL | latest patch of the pinned series (3.5.x) | GitHub releases | `.sha256` release asset |
| curl, zlib | latest release, same major | GitHub releases | sha256 digest GitHub records for the asset |
| lz4, zstd | latest release, same major | GitHub releases | `.sha256` release asset |
| util-linux (libuuid) | latest patch of the pinned series | kernel.org listing | `sha256sums.asc` |

Each new tarball is downloaded from the URL the build uses, and the update is
refused unless its hash matches the upstream-published one. If any upstream
cannot be checked, nothing is changed and the run fails. A new major version
(OpenSSL 4, PostgreSQL 19, …) is reported, never applied. Not tracked, bump by
hand: libedit and ncurses (no machine-readable release list or hash), musl and
the container images (pinned by digest; musl comes with the Alpine image), and
`PG_MAJORS` itself.

Run it locally; without `--write` it is a dry run:

```bash
scripts/check-updates.py            # report only
scripts/check-updates.py --write    # also update scripts/versions.env
```

In GitHub, `gh workflow run update.yml` is a dry run by default (it builds and
self-tests the bumped tree and validates the manifest, but does not touch
`main`, tag or release); `-f dry_run=false` on `main` does the real thing. A
run on any other branch is always a dry run. Recovery, if a run fails after
`main` was fast-forwarded but before the release exists: tag that commit by
hand (`git tag vX.Y.Z && git push origin vX.Y.Z`); the tag build releases it.

GitHub disables scheduled workflows in a repository with no activity for 60
days; re-enable it from the Actions tab if that happens.

### Moving the repository

The repo is meant to move to the ClickHouse organisation and publish to
`builds.clickhouse.com`. Nothing in a bundle, the manifest or the workflows
depends on the current location: workflows use `$GITHUB_REPOSITORY`, and
`manifest.json` uses relative file names. What changes is the URL the client
fetches `manifest.json` from, the URLs in this README, and the
`sdairs/pg-bundles` fallback that `build.sh`, `build-linux.sh` and
`manifest.py` use for builds outside GitHub Actions. Publishing to another
host is one more upload step in the `release` job, of the same files.

## Known limitations

- **Local development only.** Not tuned, hardened or supported for production.
- **Not signed or notarized.** macOS binaries carry an ad-hoc signature only.
  Files downloaded by a browser get the quarantine attribute, and Gatekeeper
  will block them; a CLI download (curl, chctl) does not set it.
- **Old macOS is checked, not run.** The minimum versions (11.0 arm64, 10.13
  x86_64) are enforced at build time and checked in every Mach-O load command,
  but the bundles have only been run on macOS 15 and 26.
- **TLS to ClickHouse Cloud is out of scope** and untested. OpenSSL's default
  CA location is compiled in: `/private/etc/ssl` on macOS and `/etc/ssl` on
  Linux, which works where `/etc/ssl/certs` holds hashed CA certificates
  (Debian, Ubuntu, Alpine). On RHEL-family systems set
  `SSL_CERT_FILE=/etc/pki/tls/certs/ca-bundle.crt` for the postgres process.
- **musl behaviour** on Linux: code-point collation, `/etc/passwd` user
  lookup, `ps` shows the loader command line; see
  [musl bundles](#musl-bundles).
- **Root** cannot run the server; a caller that is root has to drop
  privileges, see [Running as root](#running-as-root).
- **No ICU**, so ICU collations are not available. Locales come from the OS
  (macOS) or musl.
- **No headers by default.** Building more extensions against a bundle is out
  of scope: `include/` and PGXS are dropped, unless the bundle is built with
  `PGB_KEEP_INCLUDE=1` (untested). `pg_config` is still included.
- **Single architecture per build**: there are no universal macOS binaries,
  and Linux cross builds need emulation.
- Build-recipe changes are not tracked by the step stamps; use `PGB_CLEAN=1`
  after editing `scripts/build.sh` (CI always builds from scratch).

## Licence

The build scripts, workflows and documentation in this repository are licensed
under the [Apache License 2.0](LICENSE), the same licence as
[clickhousectl](https://github.com/ClickHouse/clickhousectl). The bundles
contain third-party software under its own licences (PostgreSQL, pg_clickhouse,
OpenSSL, curl, lz4, zstd and, on Linux, zlib, libedit, ncurses, libuuid and
musl); each bundle ships those licence texts in `share/licenses/`.
