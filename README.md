# pg-bundles

Prototype: portable, relocatable PostgreSQL builds with
[pg_clickhouse](https://github.com/ClickHouse/pg_clickhouse) pre-installed, so
`clickhousectl` can run local Postgres without Docker. See [SPEC.md](SPEC.md) for
the motivation, requirements, plan and the reasoning behind the platform
baselines.

The bundles are for **local development** (a Postgres to develop against), not
for production. They aim to run on as many macOS and Linux systems as
practical with nothing installed on the host.

A bundle is a tarball you can extract anywhere and run:

```bash
tar -xzf pg-18.6-pgch-0.11.0-aarch64-apple-darwin.tar.gz
cd pg-18.6-pgch-0.11.0-aarch64-apple-darwin
bin/initdb -D /tmp/pgdata -U postgres --auth=trust
bin/pg_ctl -D /tmp/pgdata -l /tmp/pg.log start
bin/psql -U postgres -c 'CREATE EXTENSION pg_clickhouse'
```

## Outputs

PostgreSQL **17.11** and **18.6**, each for six targets (Rust-style triples, as
used by `chctl`):

| Target | Built in | Runs on |
| --- | --- | --- |
| `aarch64-apple-darwin` | macOS arm64 | macOS 11.0+ |
| `x86_64-apple-darwin` | macOS Intel (`macos-15-intel` in CI) | macOS 10.13+ |
| `x86_64-unknown-linux-musl` | Alpine 3.24 container | any Linux: glibc or musl (Alpine), any version; no host libraries |
| `aarch64-unknown-linux-musl` | Alpine 3.24 container | any Linux: glibc or musl (Alpine), any version; no host libraries |
| `x86_64-unknown-linux-gnu` | manylinux2014 container | glibc 2.17+ (RHEL/CentOS 7+, Debian 8+, Ubuntu 14.04+, Amazon Linux 2+) |
| `aarch64-unknown-linux-gnu` | manylinux2014 container | glibc 2.17+ |

On Linux, the `-musl` bundle is the portable choice: it carries its own musl C
library and loader and runs on any distro. The `-gnu` bundle uses the host's
glibc, so it behaves like a distro PostgreSQL there (glibc collations and NSS
user lookup); see [musl bundles](#musl-bundles).

Each build writes two files to `dist/`:

```
dist/pg-<pgversion>-pgch-<pgchversion>-<target>.tar.gz
dist/pg-<pgversion>-pgch-<pgchversion>-<target>.tar.gz.sha256
```

e.g. `pg-17.11-pgch-0.11.0-x86_64-unknown-linux-musl.tar.gz`. The tarball has a
single top-level directory named like the archive:

```
pg-18.6-pgch-0.11.0-<target>/
  bin/        postgres, initdb, pg_ctl, psql, pg_isready, pg_dump, pg_restore, pg_config, …
  lib/        libpq, libssl, libcrypto, liblz4, libzstd, libecpg, libpgtypes
              (musl bundles: also ld-musl-<arch>.so.1, the musl loader and libc)
  lib/postgresql/   server modules: pg_clickhouse, contrib, PL/pgSQL, encoding conversions
  libexec/    musl bundles only: the real executables (bin/ holds launchers)
  share/postgresql/ timezone data, extension control/SQL files (incl. pg_clickhouse)
  share/licenses/   licences of PostgreSQL, pg_clickhouse and every bundled library
  BUNDLE.json       versions, target, build time, source commit, configure flags
```

`BUNDLE.json` examples:

```json
{
  "postgres_version": "17.11",
  "extensions": { "pg_clickhouse": "0.11.0" },
  "target": "aarch64-apple-darwin",
  "built_at": "2026-10-15T19:44:46Z",
  "source": { "repo": "sdairs/pg-bundles", "commit": "…" },
  "configure": ["--prefix=/pgbundle", "--with-openssl", "--without-icu", "--with-lz4", "--with-zstd", "--with-libedit-preferred", "--disable-rpath"],
  "dependencies": { "openssl": "3.5.9", "curl": "8.23.0", "lz4": "1.10.0", "zstd": "1.5.7" },
  "platform": { "min_macos": "11.0", "openssldir": "/private/etc/ssl" }
}
```

Linux bundles also list zlib, libedit, ncurses and libuuid (and musl) under
`dependencies`, and `platform` is one of:

```json
  "platform": { "libc": "glibc", "min_glibc": "2.17", "openssldir": "/etc/ssl" }
  "platform": { "libc": "musl", "bundled_loader": "lib/ld-musl-aarch64.so.1", "host_libc": ["glibc", "musl"], "openssldir": "/etc/ssl" }
```

## What is inside

All sources are pinned by version and sha256 in
[`scripts/versions.env`](scripts/versions.env); the build refuses a download
whose hash does not match.

| Component | Version | How it is linked |
| --- | --- | --- |
| PostgreSQL (+ contrib) | 17.11 or 18.6 | — |
| pg_clickhouse | 0.11.0 | `lib/postgresql/pg_clickhouse.{so,dylib}` |
| OpenSSL | 3.5.9 (3.x LTS) | shared, shipped in `lib/` |
| lz4 | 1.10.0 | shared, shipped in `lib/` |
| zstd | 1.5.7 | shared, shipped in `lib/` |
| curl | 8.23.0 (HTTP/HTTPS only, OpenSSL backend) | static, inside pg_clickhouse |
| musl | 1.2.6, `-musl` bundles only | shared: `lib/ld-musl-<arch>.so.1` (loader and libc in one) |
| zlib | 1.3.2 on Linux, OS library on macOS | static on Linux |
| libedit (psql line editing) | 20260512-3.1 on Linux, OS library on macOS | static on Linux |
| ncurses (libedit's terminfo backend) | 6.6, Linux only | static |
| libuuid (util-linux) | 2.42.4, Linux only (macOS: libSystem) | static, inside pg_clickhouse |

OpenSSL, lz4 and zstd are shared because postgres, libpq, every client tool,
pgcrypto, sslinfo and pg_clickhouse all use them; linking them statically
copied libcrypto into each binary and more than doubled the bundle size.
libedit is used instead of GNU readline so that bundling it does not bring
GPLv3 terms into psql. ICU is left out (`--without-icu`): smaller bundle, and
local development uses the C/libc collations.

Every binary finds bundled libraries relative to itself, through `@rpath` +
`@loader_path` on macOS and `$ORIGIN` RUNPATHs on Linux. PostgreSQL itself
locates `share/` and `lib/postgresql/` relative to the running binary. The only
remaining dynamic dependencies are OS libraries: `libSystem`, `libz`,
`libedit`, CoreFoundation and SystemConfiguration on macOS; `libc`, `libm`,
`libpthread`, `libdl` and `librt` for `-gnu` bundles; none for `-musl` bundles.

### musl bundles

PostgreSQL loads contrib and pg_clickhouse with `dlopen`, so it cannot be a
fully static musl binary the way `chctl` is. The `-musl` bundles are instead
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
uses for `pg_ctl` and `initdb`). Differences from a glibc build:

- `ps` shows the loader command line, and PostgreSQL's process titles
  (`postgres: checkpointer`, …) are squeezed into the `--argv0` argument.
- Text sorts in code-point order whatever the locale (`LANG=en_US.UTF-8` is
  accepted); with `--locale=C` or the PostgreSQL 17+ `builtin` provider the
  result is the same on every platform anyway.
- User lookup reads `/etc/passwd` (and nscd), not NSS, so an LDAP/sssd user
  with no local passwd entry can fail `initdb`'s user lookup; use the `-gnu`
  bundle there. DNS uses `/etc/hosts` and `/etc/resolv.conf`.
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

Needs Docker. The build runs inside a digest-pinned image:
`quay.io/pypa/manylinux2014_<arch>` (CentOS 7, glibc 2.17, GCC 10) for `-gnu`,
`alpine:3.24.2` (musl 1.2.6, GCC 15) for `-musl`:

```bash
scripts/build-linux.sh                       # Docker host's arch, gnu, PostgreSQL 18
scripts/build-linux.sh aarch64 musl          # arch: aarch64|x86_64; libc: gnu|musl
PG_MAJOR=17 scripts/build-linux.sh x86_64 gnu  # a foreign arch runs under emulation
```

Running `scripts/build.sh` directly on a Linux host also works; on a glibc
host the result then requires that host's glibc version, and on a musl host
(`/lib/ld-musl-<arch>.so.1` exists) it builds the `-musl` target.

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
scripts/selftest.sh dist/pg-18.6-pgch-0.11.0-aarch64-apple-darwin.tar.gz
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
| `PGB_SELFTEST_MAX_GLIBC` | `2.17`: highest `GLIBC_` symbol version a `-gnu` bundle may need |

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
  `pg_read_file`. Every mapped shared object must be from the bundle, or, for
  `-gnu` bundles, one of glibc's own libraries (libc, ld-linux, libm,
  libpthread, libdl, librt, NSS modules). For `-musl` bundles nothing from
  the host is allowed, libc included.
- **Linux, static**: every `NEEDED` entry must be a glibc library (`-gnu`),
  musl's libc (`-musl`) or a file in the bundle's `lib/`; every RPATH/RUNPATH
  must start with `$ORIGIN`; libraries must resolve inside the bundle (`ldd`
  for `-gnu`, the bundled loader's `--list` for `-musl`); `-gnu` binaries may
  not need a `GLIBC_` symbol version above 2.17, and `-musl` launchers must be
  static. These checks need `readelf` or `objdump`; in a container without
  binutils they are skipped with a `SKIP:` line and the runtime check still
  runs.

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
  scripts/selftest-container.sh "$image" dist/pg-18.6-pgch-0.11.0-aarch64-unknown-linux-musl.tar.gz
done
```

## Measured locally

Measured on an M-series Mac (macOS 26.7), 2026-10-15, with the
`aarch64` Linux bundles in Docker containers (OrbStack) on the same machine.
Sizes are what the self-test measured after extraction.

| Bundle | Compressed | Extracted | Passed the self-test (with ClickHouse) on | initdb | Start to `pg_isready` | Extract to `pg_isready` |
| --- | ---: | ---: | --- | ---: | ---: | ---: |
| `pg-18.6-…-aarch64-apple-darwin` | 10.8 MiB | 36.3 MiB | macOS 26.7 | 2.6–3.1 s | 0.3 s | 3.1–3.6 s |
| `pg-17.11-…-aarch64-apple-darwin` | 10.6 MiB | 35.6 MiB | macOS 26.7 | 2.9 s | 0.3 s | 3.4 s |
| `pg-18.6-…-aarch64-unknown-linux-musl` | 13.4 MiB | 42.6 MiB | Alpine 3.24, CentOS 7, Debian 10, Ubuntu 24.04 | 1.4–2.6 s | 0.1 s | 1.7–2.9 s |
| `pg-17.11-…-aarch64-unknown-linux-musl` | 13.1 MiB | 41.6 MiB | Alpine 3.24, CentOS 7, Debian 10, Ubuntu 24.04 | 1.8–2.5 s | 0.1 s | 2.1–2.8 s |
| `pg-18.6-…-aarch64-unknown-linux-gnu` | 12.4 MiB | 41.6 MiB | CentOS 7, Debian 10, Ubuntu 24.04 | 2.2–2.5 s | 0.1 s | 2.5–2.9 s |
| `pg-17.11-…-aarch64-unknown-linux-gnu` | 12.1 MiB | 40.9 MiB | CentOS 7, Debian 10, Ubuntu 24.04 | 1.1–2.3 s | 0.1 s | 1.4–2.7 s |

Most of the time goes to `initdb`; starting the server takes about 0.1–0.3 s.
`pg-18.6-…-x86_64-apple-darwin` (11.4 MiB / 34.1 MiB, minos 10.13) was also
built and self-tested here under Rosetta. CI measures the x86_64 bundles on
GitHub-hosted runners (Intel macOS 15, Ubuntu 24.04 and the distro
containers); see the job summaries and release notes.

The Linux bundles are larger once extracted because aarch64 ELF objects are
aligned to 64 KiB pages (needed for 64K-page kernels); that padding compresses
away. The `-musl` bundle is about 1 MiB larger compressed than `-gnu`: it
carries the musl loader/libc and the launcher.

## CI and releases

[`.github/workflows/build.yml`](.github/workflows/build.yml) runs on pushes to
`main`, pull requests, `v*` tags and manual dispatch (`workflow_dispatch`).
Every job runs for PostgreSQL 17 and 18:

- `linux` job: {`x86_64` on `ubuntu-24.04`, `aarch64` on `ubuntu-24.04-arm`} ×
  {`gnu`, `musl`}. It builds in the manylinux2014 or Alpine container, then
  self-tests on the runner (Ubuntu 24.04) against a
  `clickhouse/clickhouse-server` service container, and again with
  `scripts/selftest-container.sh` in `centos:7` (glibc 2.17) and `debian:10`
  (glibc 2.28), plus `alpine:3.24` for `-musl` bundles.
- `macos` job: `aarch64-apple-darwin` on `macos-15`, `x86_64-apple-darwin` on
  `macos-15-intel`. Hosted macOS runners have no service containers, so
  `scripts/start-clickhouse-macos.sh` starts a pinned, sha256-verified
  ClickHouse release binary natively.
- On every job the ClickHouse step is required (`PGB_SELFTEST_CLICKHOUSE=require`),
  and every self-test summary is added to the job summary. Each job uploads
  `bundle-pg<major>-<target>` with the tarball, `.sha256` and `.selftest.json`.
- `release` job (tags `v*` only): downloads all 12 artifacts, checks that every
  PostgreSQL major × target bundle is present, and creates a GitHub release
  with every tarball and `.sha256`. The release notes include a table of sizes
  and timings from the self-tests.

All actions are pinned to commit SHAs, and the build and test container images
are pinned by digest.

To release:

```bash
git tag v0.2.0   # any tag starting with v
git push origin v0.2.0
```

The repo is public, so release assets download without authentication:

```
https://github.com/sdairs/pg-bundles/releases/download/<tag>/pg-<pgversion>-pgch-0.11.0-<target>.tar.gz
```

### Choosing a bundle (for `chctl`)

- macOS: `<arch>-apple-darwin`.
- Linux: `<arch>-unknown-linux-musl` works on every distro and is the same
  triple `chctl` itself is built for, so no libc detection is needed. Prefer
  `<arch>-unknown-linux-gnu` only when glibc behaviour matters (glibc
  collations, NSS users) and the host has glibc ≥ 2.17.
- PostgreSQL major: from `postgres_version` in the name (`pg-17.11-…`,
  `pg-18.6-…`) or `BUNDLE.json`.

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
- **musl behaviour** in `-musl` bundles: code-point collation, `/etc/passwd`
  user lookup, `ps` shows the loader command line; see
  [musl bundles](#musl-bundles).
- **No ICU**, so ICU collations are not available. Locales come from the OS
  (`-gnu`, macOS) or musl.
- **No headers by default.** Building more extensions against a bundle is out
  of scope: `include/` and PGXS are dropped, unless the bundle is built with
  `PGB_KEEP_INCLUDE=1` (untested). `pg_config` is still included.
- **Single architecture per build**: there are no universal macOS binaries,
  and Linux cross builds need emulation.
- Build-recipe changes are not tracked by the step stamps; use `PGB_CLEAN=1`
  after editing `scripts/build.sh` (CI always builds from scratch).
