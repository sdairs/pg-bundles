# pg-bundles

Prototype: portable, relocatable PostgreSQL builds with
[pg_clickhouse](https://github.com/ClickHouse/pg_clickhouse) pre-installed, so
`clickhousectl` can run local Postgres without Docker. See [SPEC.md](SPEC.md) for
the motivation, requirements and plan.

A bundle is a tarball you can extract anywhere and run:

```bash
tar -xzf pg-18.6-pgch-0.11.0-aarch64-apple-darwin.tar.gz
cd pg-18.6-pgch-0.11.0-aarch64-apple-darwin
bin/initdb -D /tmp/pgdata -U postgres --auth=trust
bin/pg_ctl -D /tmp/pgdata -l /tmp/pg.log start
bin/psql -U postgres -c 'CREATE EXTENSION pg_clickhouse'
```

## Outputs

| Target | Built on | Notes |
| --- | --- | --- |
| `aarch64-apple-darwin` | macOS arm64 | macOS 12+ |
| `x86_64-apple-darwin` | macOS Intel (`macos-15-intel` in CI) | macOS 12+ |
| `x86_64-unknown-linux-gnu` | manylinux_2_28 container | glibc 2.28+ (RHEL/Alma/Rocky 8+, Debian 10+, Ubuntu 18.10+) |
| `aarch64-unknown-linux-gnu` | manylinux_2_28 container | glibc 2.28+ |

Each build writes two files to `dist/`:

```
dist/pg-<pgversion>-pgch-<pgchversion>-<target>.tar.gz
dist/pg-<pgversion>-pgch-<pgchversion>-<target>.tar.gz.sha256
```

The tarball has a single top-level directory named like the archive:

```
pg-18.6-pgch-0.11.0-<target>/
  bin/        postgres, initdb, pg_ctl, psql, pg_isready, pg_dump, pg_restore, pg_config, …
  lib/        libpq, libssl, libcrypto, liblz4, libzstd, libecpg, libpgtypes
  lib/postgresql/   server modules: pg_clickhouse, contrib, PL/pgSQL, encoding conversions
  share/postgresql/ timezone data, extension control/SQL files (incl. pg_clickhouse)
  share/licenses/   licences of PostgreSQL, pg_clickhouse and every bundled library
  BUNDLE.json       versions, target, build time, source commit, configure flags
```

`BUNDLE.json` example:

```json
{
  "postgres_version": "18.6",
  "extensions": { "pg_clickhouse": "0.11.0" },
  "target": "aarch64-apple-darwin",
  "built_at": "2026-10-15T14:04:30Z",
  "source": { "repo": "sdairs/pg-bundles", "commit": "…" },
  "configure": ["--prefix=/pgbundle", "--with-openssl", "--without-icu", "--with-lz4", "--with-zstd", "--with-libedit-preferred", "--disable-rpath"],
  "dependencies": { "openssl": "3.5.9", "curl": "8.23.0", "lz4": "1.10.0", "zstd": "1.5.7" },
  "platform": { "min_macos": "12.0", "openssldir": "/private/etc/ssl" }
}
```

## What is inside

All sources are pinned by version and sha256 in
[`scripts/versions.env`](scripts/versions.env); the build refuses a download
whose hash does not match.

| Component | Version | How it is linked |
| --- | --- | --- |
| PostgreSQL (+ contrib) | 18.6 | — |
| pg_clickhouse | 0.11.0 | `lib/postgresql/pg_clickhouse.{so,dylib}` |
| OpenSSL | 3.5.9 (3.x LTS) | shared, shipped in `lib/` |
| lz4 | 1.10.0 | shared, shipped in `lib/` |
| zstd | 1.5.7 | shared, shipped in `lib/` |
| curl | 8.23.0 (HTTP/HTTPS only, OpenSSL backend) | static, inside pg_clickhouse |
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
`libpthread`, `libdl` and `librt` on Linux.

## Build

### macOS

Needs the Xcode command line tools. Nothing from Homebrew is used: the build
runs with `PATH=/usr/bin:/bin:/usr/sbin:/sbin`, an empty pkg-config search path
and no `CPATH`/`LIBRARY_PATH`.

```bash
scripts/build.sh
```

The script builds for the host (`aarch64-apple-darwin` on Apple silicon,
`x86_64-apple-darwin` on Intel); cross builds are not supported.

### Linux

Needs Docker. The build runs inside a digest-pinned
`quay.io/pypa/manylinux_2_28_<arch>` image (AlmaLinux 8, glibc 2.28, GCC 14):

```bash
scripts/build-linux.sh            # the Docker host's architecture
scripts/build-linux.sh x86_64     # or aarch64; a foreign arch runs under emulation
```

Running `scripts/build.sh` directly on a Linux host also works, but the result
then requires that host's glibc version.

### Caching and options

Downloads are cached in `.build/sources/` and each step leaves a stamp in
`.build/<target>/stamps/`, so a rerun only repackages (seconds). Both `.build/`
and `dist/` are gitignored.

| Variable | Effect |
| --- | --- |
| `JOBS=<n>` | parallel make jobs (default: CPU count) |
| `PGB_CLEAN=1` | wipe `.build/<target>/` first; needed after changing a build recipe |
| `PGB_KEEP_INCLUDE=1` | keep `include/` and PGXS so more extensions can be built against the bundle |

A clean build takes about 4 minutes on an M-series Mac and 2 minutes for
aarch64 Linux in Docker on the same machine.

## Test

```bash
scripts/selftest.sh dist/pg-18.6-pgch-0.11.0-aarch64-apple-darwin.tar.gz
```

The self-test follows SPEC.md: it verifies the `.sha256`, extracts the bundle
into a fresh `/tmp/pgbst.XXXXXX` directory and, with a scrubbed environment
(no `DYLD_*`/`LD_*`, system `PATH` only), runs `initdb` with a password file,
starts `postgres` on a free port, waits for `pg_isready`, runs
`SELECT version()`, `CREATE EXTENSION pg_clickhouse` and `\dx`, then stops the
server with `pg_ctl stop -m fast` and checks the dependency closure.

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

The dependency check is strict:

- **macOS**: every `LC_LOAD_DYLIB` must be under `/usr/lib` or
  `/System/Library`, or `@rpath/<lib>` that exists in the bundle's `lib/`;
  every `LC_RPATH` must be `@loader_path`-relative and resolve to `lib/`; every
  code signature must be valid. The postmaster also runs with
  `DYLD_PRINT_LIBRARIES=1`, and every image loaded at runtime, including
  `pg_clickhouse.dylib` and its dependencies after `CREATE EXTENSION`, must
  come from the bundle or the OS. A library from `/opt/homebrew` or
  `/usr/local` fails the test.
- **Linux**: every `NEEDED` entry must be a glibc library or a file in the
  bundle's `lib/`; every RPATH/RUNPATH must start with `$ORIGIN`; `ldd` must
  resolve everything inside the bundle or the system library directories; and
  no binary may need a `GLIBC_` symbol version newer than 2.28.

The self-test prints compressed and extracted size and the times for extract,
initdb, start to `pg_isready`, and extract to `pg_isready`.

To test a Linux bundle on a specific distro from a Mac, run it in a container
that shares the ClickHouse container's network:

```bash
docker run --rm --network container:ch -v "$PWD/dist:/dist:ro" -v "$PWD/scripts:/scripts:ro" almalinux:8 \
  bash -c 'dnf install -y -q binutils file perl && useradd -m t &&
           su t -c "bash /scripts/selftest.sh /dist/pg-18.6-pgch-0.11.0-aarch64-unknown-linux-gnu.tar.gz"'
```

## Measured locally

Measured on an M-series Mac (macOS 26), 2026-10-15, over several self-test runs.
The Linux bundles ran in Docker containers on the same machine; x86_64 ran under
emulation, so its times are only indicative.

| Bundle | Compressed | Extracted | Extract | initdb | Start to `pg_isready` | Extract to `pg_isready` |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| `aarch64-apple-darwin` | 10.8 MiB | 35.0 MiB | 0.2 s | 1.3–2.9 s | 0.2–0.3 s | 1.7–3.3 s |
| `aarch64-unknown-linux-gnu` (AlmaLinux 8 / Ubuntu 24.04) | 12.5 MiB | 54.7 MiB | 0.3 s | 1.1–1.8 s | 0.1 s | 1.5–2.2 s |
| `x86_64-unknown-linux-gnu` (AlmaLinux 8, emulated) | 12.3 MiB | 35.0 MiB | 0.2 s | 1.4 s | 0.2 s | 1.9 s |

Most of the time goes to `initdb`; starting the server takes about 0.1–0.3 s.

The Linux bundle is larger once extracted because aarch64 ELF objects are
aligned to 64 KiB pages (needed for 64K-page kernels); that padding compresses
away.

## CI and releases

[`.github/workflows/build.yml`](.github/workflows/build.yml) runs on pushes to
`main`, pull requests, `v*` tags and manual dispatch (`workflow_dispatch`):

- `linux` job: `x86_64` on `ubuntu-24.04`, `aarch64` on `ubuntu-24.04-arm`.
  It builds in the manylinux_2_28 container, then self-tests on the runner
  (Ubuntu 24.04) against a `clickhouse/clickhouse-server` service container.
- `macos` job: `aarch64-apple-darwin` on `macos-15`, `x86_64-apple-darwin` on
  `macos-15-intel`. Hosted macOS runners have no service containers, so
  `scripts/start-clickhouse-macos.sh` starts a pinned, sha256-verified
  ClickHouse release binary natively.
- On every job the ClickHouse step is required (`PGB_SELFTEST_CLICKHOUSE=require`),
  and the self-test summary is added to the job summary. Each target uploads
  `bundle-<target>` with the tarball, `.sha256` and `.selftest.json`.
- `release` job (tags `v*` only): downloads all artifacts and creates a GitHub
  release with every tarball and `.sha256`. The release notes include a table
  of sizes and timings from the self-tests.

All actions are pinned to commit SHAs, and the container images are pinned by
digest.

To release:

```bash
git tag v18.6-0.11.0-1   # any tag starting with v
git push origin v18.6-0.11.0-1
```

The repo is public, so release assets download without authentication:

```
https://github.com/sdairs/pg-bundles/releases/download/<tag>/pg-18.6-pgch-0.11.0-<target>.tar.gz
```

## Known limitations

- **Not signed or notarized.** macOS binaries carry an ad-hoc signature only.
  Files downloaded by a browser get the quarantine attribute, and Gatekeeper
  will block them; a CLI download (curl, chctl) does not set it.
- **TLS trust store.** OpenSSL's default CA location is compiled in:
  `/private/etc/ssl` on macOS (`cert.pem` is the system bundle) and `/etc/ssl` on
  Linux, which works where `/etc/ssl/certs` holds hashed CA certificates
  (Debian, Ubuntu, Alpine-style layouts). On RHEL-family systems, set
  `SSL_CERT_FILE=/etc/pki/tls/certs/ca-bundle.crt` for the postgres process.
  This only matters for TLS connections to ClickHouse, such as ClickHouse
  Cloud. The self-test uses plaintext connections to a local server, so TLS is
  not exercised.
- **glibc only on Linux.** Bundles need glibc ≥ 2.28; musl distros such as
  Alpine are not supported.
- **No ICU**, so ICU collations are not available. Locales come from the OS.
- **No headers by default.** `include/` and PGXS are dropped to save space, so
  other extensions cannot be built against a bundle unless it is built with
  `PGB_KEEP_INCLUDE=1`. `pg_config` is still included.
- **PostgreSQL 18 only.** PostgreSQL 17 is not built yet.
- **Single architecture per build**: there are no universal macOS binaries,
  and Linux cross builds need emulation.
- Build-recipe changes are not tracked by the step stamps; use `PGB_CLEAN=1`
  after editing `scripts/build.sh` (CI always builds from scratch).
