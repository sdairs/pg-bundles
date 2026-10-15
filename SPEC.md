# pg-bundles: portable Postgres + pg_clickhouse builds

Status: **prototype** (v0.1.0 shipped PG 18 for four targets; this revision adds PG 17, musl/Alpine and
lower OS baselines). This repo exists to answer one question for the wider team: *should ClickHouse
publish its own portable Postgres binaries (with pg_clickhouse pre-installed) so that `clickhousectl`
can run local Postgres without Docker?*

Nothing here is published to `builds.clickhouse.com`. Hosting, ownership and signing are decisions for
other teams; the prototype only has to make the case.

## Background

`clickhousectl` (`chctl`, repo `ClickHouse/clickhousectl`) manages local ClickHouse and local Postgres:

- **Local ClickHouse** downloads a single static binary from `builds.clickhouse.com` into
  `~/.clickhouse/`, keeps per-project data in `.clickhouse/`, spawns the server as a child process and
  tracks it by pid. No Docker.
- **Local Postgres** (`chctl local postgres start|stop|remove|client|dotenv`) is Docker-backed: it pulls
  `postgres:<tag>`, creates a container configured with `POSTGRES_USER/PASSWORD/DB`, discovers instances by
  container labels and runs `psql` via `docker exec`. See `crates/clickhousectl/src/local/docker.rs` and
  `crates/clickhousectl/src/local/postgres.rs`.

Requiring Docker Desktop is the main friction in the local Postgres flow. Postgres has no official
portable builds; third-party ones exist (`theseus-rs/postgresql-binaries`, zonky) but are not something we
want users' CLI to pull executables from. Building our own also lets us ship **pg_clickhouse**
(`ClickHouse/pg_clickhouse`) in the box, so local Postgres can query local ClickHouse out of the box.

## Goal of the prototype

1. A reproducible build that produces a relocatable tarball: PostgreSQL + pg_clickhouse, runnable from
   any directory, with no Homebrew/apt runtime dependencies.
2. Tarballs for the platforms `chctl` local ClickHouse supports, attached to GitHub releases of this repo.
3. A draft `clickhousectl` branch that runs local Postgres from such a tarball (opt-in, Docker stays the
   default).
4. A demo and short write-up with numbers, to float with the Postgres / pg_clickhouse / infra folks.

Bundles are for **local development only**: standing up a local Postgres to develop against, not for
production. Portability is the priority, in the spirit of `chctl` itself (static musl binaries on Linux)
and ClickHouse: a bundle should run on as many macOS and Linux versions and distros as practical, with no
host packages.

### Non-goals

- Publishing to `builds.clickhouse.com`, code signing/notarization, SBOMs, provenance beyond sha256.
- Windows. Extensions other than pg_clickhouse (pg_re2, pgvector, PostGIS come later, if ever).
- Production use. Consequently out of scope: TLS to ClickHouse Cloud (works where the host's CA layout
  matches OpenSSL's compiled-in one, but is not tested or tuned) and PGXS/headers for building more
  extensions against a bundle (`PGB_KEEP_INCLUDE=1` keeps them, untested).
- Production-quality `chctl` code: no docs, help-text rewrite, migration of existing Docker instances or
  full test suite in the prototype branch.

## What a bundle is

### Versions

- PostgreSQL majors **17** and **18**, latest minor of each (17.11 and 18.6 as of 2026-10-15). The major is a
  build parameter (`PG_MAJOR=17|18`, default 18); `scripts/versions.env` pins version and sha256 per major.
- pg_clickhouse: latest release tag (v0.11.0 as of 2026-10; requires PG ≥ 14). It builds with PGXS and has a
  git submodule (`vendor/pg-clickhouse-c`, header-only), so clone with `--recurse-submodules` or use the
  release zip.

### Targets

Target names are Rust-style triples, the same ones `chctl` is built for, so `chctl` can match its own
target.

| Target triple | Build host | Runs on |
| --- | --- | --- |
| `aarch64-apple-darwin` | macOS arm64 (native) | macOS 11.0+ |
| `x86_64-apple-darwin` | macOS Intel runner | macOS 10.13+ |
| `x86_64-unknown-linux-musl` | Alpine 3.24 container | **any** Linux, glibc or musl (Alpine); no host libraries |
| `aarch64-unknown-linux-musl` | Alpine 3.24 container | **any** Linux, glibc or musl (Alpine); no host libraries |
| `x86_64-unknown-linux-gnu` | manylinux2014 container (CentOS 7) | glibc 2.17+ (CentOS/RHEL 7+, Debian 8+, Ubuntu 14.04+) |
| `aarch64-unknown-linux-gnu` | manylinux2014 container (CentOS 7) | glibc 2.17+ |

Each target is built for both PostgreSQL majors: 12 bundles per release. The reasoning behind the Linux
and macOS baselines is in [Decisions: portability](#decisions-portability-2026-10-15).

### Naming

```
pg-<pgversion>-pgch-<pgchversion>-<target>.tar.gz
pg-<pgversion>-pgch-<pgchversion>-<target>.tar.gz.sha256
```

e.g. `pg-18.6-pgch-0.11.0-aarch64-apple-darwin.tar.gz`, `pg-17.11-pgch-0.11.0-x86_64-unknown-linux-musl.tar.gz`.
The full PostgreSQL version carries the major (`18.6` → 18), so there is no separate major field in the name;
`BUNDLE.json` has `postgres_version`.

### Layout

The tarball has one top-level directory named like the archive (minus `.tar.gz`):

```
pg-18.6-pgch-0.11.0-aarch64-apple-darwin/
  bin/      postgres initdb pg_ctl psql pg_isready pg_dump pg_restore pg_config createdb …
  lib/      libpq.*, postgresql/*.so (incl. pg_clickhouse.so, contrib modules), any bundled dylibs/.so
  share/    postgresql/… (timezone data, extension/*.control + *.sql incl. pg_clickhouse)
  include/  optional; drop if size matters
  libexec/  musl bundles only: the real executables; bin/ holds launchers (see below)
  BUNDLE.json
```

`BUNDLE.json` records what is inside, so `chctl` and humans can inspect a bundle without running it:

```json
{
  "postgres_version": "18.6",
  "extensions": { "pg_clickhouse": "0.11.0" },
  "target": "aarch64-apple-darwin",
  "built_at": "2026-10-15T00:00:00Z",
  "source": { "repo": "sdairs/pg-bundles", "commit": "<sha>" },
  "configure": ["--with-openssl", "--without-icu", "..."]
}
```

### Build requirements

- **Relocatable**: Postgres resolves `share/` and `lib/` relative to the running binary's directory; keep
  the default relative layout (configure with a prefix and do not hard-code absolute paths elsewhere).
  Every binary and `.so`/`.dylib` must find its libraries via `$ORIGIN` (Linux rpath) or
  `@loader_path`/`@executable_path` (macOS install names). Verify with `otool -L` / `ldd` that nothing
  points at `/opt/homebrew`, `/usr/local` or the build prefix.
- **No runtime package dependencies**: OpenSSL, libcurl, lz4, zstd (and libuuid on Linux) — pg_clickhouse's
  link deps, see its `Makefile` — are linked statically, or shipped in `lib/` and resolved via rpath. Build
  curl minimal (HTTP/HTTPS only, OpenSSL backend, no nghttp2/idn2/brotli/ldap/psl) to keep the closure small.
  Only OS-provided libraries may remain dynamic (libc, libm, libSystem, macOS frameworks).
- **Postgres configure**: `--with-openssl`, `--without-icu` (decision for the prototype: smaller bundle,
  local dev uses C/libc collations; revisit if it matters), `--without-readline` unless libedit/readline is
  bundled (psql without line editing is poor; prefer bundling libedit or readline statically). Build contrib
  (`make world-bin` or `make -C contrib install`) since the Docker image has it.
- **pg_clickhouse**: `make PG_CONFIG=<prefix>/bin/pg_config && make install` against the freshly built
  prefix, with `CURL_CONFIG` pointing at the bundled curl.
- **macOS**: ad-hoc signature is fine (the arm64 linker applies one; re-sign with `codesign -s -` after
  `install_name_tool` edits, or the binary is killed on launch).
- The build is driven by scripts in this repo (`scripts/build-<os>.sh` or a single `scripts/build.sh`),
  runnable locally and in CI. Pin every source by version and sha256 (PostgreSQL tarball from
  ftp.postgresql.org, pg_clickhouse release, OpenSSL, curl, lz4, zstd).

### Self-test (every bundle, in CI and locally)

Run from an extracted copy in an unrelated temp directory, as a non-root user:

1. `bin/initdb -D $TMP/data -U postgres --auth=scram-sha-256 --pwfile=<file> -E UTF8 --locale=C`
2. `bin/postgres -D $TMP/data -p <free port> -k $TMP/sock -c listen_addresses=127.0.0.1` in the background;
   wait with `bin/pg_isready`.
3. `bin/psql` → `SELECT version();` and `CREATE EXTENSION pg_clickhouse;` (and `\dx` shows it).
4. If a ClickHouse server is reachable (CI: a `clickhouse/clickhouse-server` service container; locally:
   `chctl local server start`), create a pg_clickhouse foreign server/table against it and run a query.
   Skip this step with a clear log line when no ClickHouse is available.
5. Runtime libraries: in a backend that has loaded pg_clickhouse (and queried ClickHouse), every loaded
   shared object comes from the bundle or the OS (Linux: the backend's `/proc/self/maps`, read with
   `pg_read_file`; for musl bundles nothing from the host at all. macOS: `DYLD_PRINT_LIBRARIES`).
6. Stop with `bin/pg_ctl -D $TMP/data stop -m fast`.
7. Assert the dependency closure (`otool -L` / `ldd` / `readelf -d`, or the bundled musl loader's `--list`)
   contains only allowed system libraries, and the minimum OS (highest `GLIBC_` symbol version ≤ 2.17;
   Mach-O minos ≤ `min_macos`) holds.

Linux bundles are also self-tested in other distro containers (`scripts/selftest-container.sh`):
`centos:7` and `debian:10` for every Linux bundle, plus `alpine:3.24` for musl bundles.

Record bundle size (compressed and extracted) and time from extract to `pg_isready` success in the CI log
and in the release notes.

### CI

GitHub Actions in this repo:

- Matrix over PG majors {17, 18} × targets; macOS arm64 on `macos-15`, macOS x86_64 on `macos-15-intel`,
  Linux on `ubuntu-24.04` / `ubuntu-24.04-arm` running the build inside the manylinux2014 (gnu) or Alpine
  (musl) container, then self-testing on the runner and in older/other distro containers (CentOS 7,
  Debian 10, and Alpine for musl bundles).
- Runs the self-test, then on a tag (`v*`) creates a GitHub release with every tarball + `.sha256`.
- Pin actions to commit SHAs (same rule as clickhousectl).

Note: this repo is **public**, so release assets download without authentication, e.g.
`https://github.com/sdairs/pg-bundles/releases/download/<tag>/<bundle>.tar.gz`. The `chctl` prototype should
still accept a local file as well as a URL (for testing unreleased builds).

## Decisions: portability (2026-10-15)

### glibc baseline: 2.17 (manylinux2014)

`*-unknown-linux-gnu` bundles are built in the PyPA `manylinux2014` images (CentOS 7, glibc 2.17,
devtoolset-10 GCC 10), for both x86_64 and aarch64. glibc 2.17 is as far down as is practical:

- It is the oldest glibc with a still-maintained build image for **both** architectures (PyPA still
  publishes manylinux2014 images, with yum pointed at vault.centos.org). manylinux1/2010 (glibc 2.5/2.12)
  are retired and x86_64-only; 2.17 is also the first glibc release with aarch64 support at all.
- PostgreSQL 17/18 and every dependency build there unchanged; CentOS 7 has the flex (2.5.37) and bison
  (3.0.4) PostgreSQL 17+ needs, and Perl 5.16 is enough for PostgreSQL and OpenSSL 3.5. The only build
  change was dropping GNU tar's `--sort=name` (tar 1.26) for a sorted file list.
- The self-test fails a bundle that needs any `GLIBC_` symbol version above 2.17
  (`PGB_SELFTEST_MAX_GLIBC`, default 2.17) and runs every gnu bundle in `centos:7` and `debian:10`
  containers as well as on Ubuntu 24.04.

Anything older than glibc 2.17 is covered by the musl bundles below.

### musl / Alpine: one bundle that runs on every Linux

PostgreSQL loads contrib modules and pg_clickhouse with `dlopen`, which a fully static musl binary cannot
do (static musl's `dlopen` always fails), so "static like chctl" is not available for the server. Options
considered:

1. **Fully static musl, extensions linked in.** Not possible without patching PostgreSQL's extension
   loading; every `CREATE EXTENSION` and `LOAD` dlopens a `.so`. Rejected.
2. **Dynamic musl bundle for musl hosts only** (`PT_INTERP=/lib/ld-musl-<arch>.so.1`, built in
   Alpine/musllinux). Works on Alpine, needs the host's musl, and `chctl` would have to tell musl and glibc
   hosts apart. Strictly less capable than option 3 at the same build cost. Rejected.
3. **Dynamic musl with the musl loader shipped in the bundle (chosen).** Everything is built against musl
   in Alpine, and the bundle ships Alpine's `ld-musl-<arch>.so.1` (musl's loader *is* its libc) in `lib/`.
   `PT_INTERP` must be an absolute path, so the real executables live in `libexec/` and `bin/<name>` is a
   tiny static launcher (`scripts/launcher.c`, one file hard-linked under every name) that runs
   `libexec/ld/<name> --library-path=<root>/lib --preload= --argv0=<root>/bin/<name> -- <root>/libexec/<name> …`,
   where `libexec/ld/<name>` is a symlink to the bundled loader (so the process name stays `postgres`,
   `psql`, …). `--argv0` makes PostgreSQL treat `bin/<name>` as its own path, so `share/` and `lib/` resolve
   and sibling programs (`initdb`→`postgres`, `pg_ctl`→`postgres`, `pg_dumpall`→`pg_dump`) are found as
   launchers too. musl's loader honours `--library-path`/`--preload` over the host's
   `LD_LIBRARY_PATH`/`LD_PRELOAD`, so no host library can be loaded.
4. **Ship glibc instead** (its `ld-linux` + `libc.so.6` with the same launcher trick). Rejected: glibc is not
   designed to be relocated; NSS, iconv/gconv and locale data are loaded from fixed host paths and must
   match the libc version.
5. **`gcompat` on Alpine** for the gnu bundles: a host package, and incomplete. Rejected.

Result: `<arch>-unknown-linux-musl` bundles run, self-tested with the pg_clickhouse foreign-table step, on
Alpine 3.24 (musl 1.2.6), CentOS 7 (glibc 2.17), Debian 10 (glibc 2.28) and Ubuntu 24.04 (glibc 2.39). The
self-test reads a backend's `/proc/self/maps` after loading pg_clickhouse and querying ClickHouse and
requires every mapped shared object, including libc, to be from the bundle. The only host requirement is
a Linux kernel (and `/bin/sh` for the things PostgreSQL itself runs through the shell, e.g. `pg_ctl`).
Naming the target `-unknown-linux-musl` matches `chctl`'s own Linux release triples, so `chctl` can pick
the bundle for its own target with no libc detection.

Costs of the musl bundles, all acceptable for local development:

- About 1 MiB larger compressed than the gnu bundle (loader, launcher, slightly larger OpenSSL).
- `ps` shows the loader command line (`…/libexec/ld/postgres --library-path=… -- …/libexec/postgres -D …`)
  and PostgreSQL's process titles are squeezed into the `--argv0` value. `pgrep`/`pkill`/`top` show the
  right names.
- musl behaviour: collation is code-point order whatever `LC_COLLATE` says (ICU is not built anyway), the
  musl allocator is slower than glibc's, user lookup reads `/etc/passwd` (plus nscd) rather than NSS, so a
  directory-service (LDAP/sssd) user without a local passwd entry may fail `initdb`'s user lookup, and DNS
  uses `/etc/hosts` + `/etc/resolv.conf` only.
- Running a `libexec/` binary directly does not work on a glibc host (always go through `bin/`).

Both Linux flavours are kept: gnu bundles behave exactly like a distro (or the official Docker image)
PostgreSQL on glibc hosts, including glibc collations, and musl bundles cover everything else.

### macOS: 11.0 (arm64), 10.13 (x86_64)

`MACOSX_DEPLOYMENT_TARGET` defaults to 11.0 on Apple silicon (the first macOS for it) and 10.13 on Intel
(the oldest deployment target current Xcode supports; it also covers every Intel Mac that runs a
supported Xcode toolchain today). Everything, dependencies included, is compiled with
`-Werror=unguarded-availability-new`, so a call to an API newer than the target that is not guarded by an
availability check fails the build instead of failing at load time on an old macOS. The self-test checks
`LC_BUILD_VERSION` minos (or `LC_VERSION_MIN_MACOSX`) of every Mach-O file against `BUNDLE.json`
`platform.min_macos`. Nothing older than macOS 26 is available to run the bundles on here or in CI, so the
lower bounds are verified by load commands, not by booting old macOS.

## clickhousectl prototype (separate repo, draft branch)

Lives on a branch of `ClickHouse/clickhousectl`, opened as a **draft PR** for discussion, not for merge.
Read that repo's `AGENTS.md` first.

Opt-in only; default behaviour stays Docker:

- `CLICKHOUSECTL_PG_RUNTIME=native` selects the native backend.
- `CLICKHOUSECTL_PG_BUNDLE=<https URL | file:///path/to/bundle.tar.gz>` points at the bundle. Release assets
  of this public repo need no authentication.

Behaviour of the native backend:

- **Install/cache**: extract into `~/.clickhouse/postgres/<bundle-name>/` (verify sha256 if a `.sha256`
  sibling is available). Reuse if already present.
- **start**: if the instance's data dir under `.clickhouse/` is empty, run `initdb` with `--user`,
  `--password` (via `--pwfile`, never argv) and create `--database` if not `postgres`. Spawn `postgres`
  detached, bound to `127.0.0.1` on the chosen port (reuse the existing port-selection logic), socket dir
  inside `.clickhouse/`, logs to a file in the instance dir. Record the pid in the same server metadata
  `local server list` already reads (`Engine::Postgres` exists in `src/local/server.rs`). Wait for readiness
  with `pg_isready`. Refuse to start as root with a clear message (Postgres will not run as root).
- **stop / remove**: SIGINT (Postgres "fast" shutdown) to the postmaster pid, wait, then mark stopped;
  `remove` deletes the data dir.
- **client**: exec the bundled `psql` directly with the instance's connection settings.
- **dotenv / server list**: unchanged output shape; connection details come from metadata.

Out of scope for the prototype: Docker→native migration, `--env` passthrough, version-tag variants like
`18-alpine`, help text and docs updates, full test coverage.

## Demo and write-up

`DEMO.md` in this repo, with a script along the lines of:

```bash
# Docker not running
chctl local server start                       # local ClickHouse
CLICKHOUSECTL_PG_RUNTIME=native CLICKHOUSECTL_PG_BUNDLE=file:///…/pg-18.6-pgch-0.11.0-aarch64-apple-darwin.tar.gz \
  chctl local postgres start
chctl local postgres client -q "CREATE EXTENSION pg_clickhouse; …query a ClickHouse table from Postgres…"
chctl local postgres stop
```

The write-up compares Docker vs native: download size (`postgres:18` image vs bundle), time to first
`pg_isready` (cold and warm), and the steps a new user needs. It ends with the asks:

1. Who owns building bundles long term (Postgres team, pg_clickhouse team, or clickhousectl)?
2. Hosting: `builds.clickhouse.com/postgres/…` with a small `index.json` (major → latest bundle), or GitHub
   releases on a ClickHouse-org repo?
3. Signing/provenance: sha256 only, or GitHub artifact attestations / sigstore, plus macOS notarization?
4. Which extensions ship by default (pg_clickhouse only, or also pg_re2, pgvector, …) and which platforms.
5. Does ClickHouse Cloud's managed Postgres already have a Postgres build pipeline worth reusing?

## Plan and next step

1. ~~macOS arm64 bundle, local build~~ (done).
2. ~~Linux x86_64/aarch64 bundles via a container build; same self-test~~ (done; v0.1.0 at glibc 2.28).
3. ~~GitHub Actions matrix + tagged release with assets~~ (done, v0.1.0).
4. ~~PostgreSQL 17; glibc 2.17; musl bundles that run on any Linux; macOS 11.0/10.13~~ (done, see
   decisions above).
5. `clickhousectl` draft branch with the native backend described above (ClickHouse/clickhousectl#1098):
   pick the bundle by its own target triple (`*-unknown-linux-musl` on Linux), and the PG major.
6. `DEMO.md` with measured numbers and the asks; share.
