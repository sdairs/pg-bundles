# pg-bundles: portable Postgres + pg_clickhouse builds

Status: **prototype** (v0.1.0 shipped PG 18 for four targets; v0.2.0 added PG 17, musl/Alpine and lower
OS baselines; this revision drops the glibc bundles and adds a release manifest, build provenance and
scheduled rebuilds). This repo exists to answer one question for the wider team: *should ClickHouse
publish its own portable Postgres binaries (with pg_clickhouse pre-installed) so that `clickhousectl`
can run local Postgres without Docker?*

Bundles are published as GitHub releases of this repo. The repo is expected to move to the ClickHouse
organisation and publish to `builds.clickhouse.com`; it is built so that the move is a URL change (a
manifest with relative file names, no repository name baked into the workflows; see README, "Moving the
repository"). macOS signing and notarization remain decisions for other teams.

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

- Publishing to `builds.clickhouse.com` (not yet), macOS code signing/notarization, SBOMs. Releases do
  carry sha256 files and GitHub build provenance attestations.
- Windows. Extensions other than pg_clickhouse (pg_re2, pgvector, PostGIS come later, if ever).
- Production use. Consequently out of scope: TLS to ClickHouse Cloud (works where the host's CA layout
  matches OpenSSL's compiled-in one, but is not tested or tuned) and PGXS/headers for building more
  extensions against a bundle (`PGB_KEEP_INCLUDE=1` keeps them, untested).
- Production-quality `chctl` code: no docs, help-text rewrite, migration of existing Docker instances or
  full test suite in the prototype branch.

## What a bundle is

### Versions

- PostgreSQL majors **17** and **18**, latest minor of each (17.12 and 18.7 as of 2026-11-16). The major is a
  build parameter (`PG_MAJOR=17|18`, default 18); `scripts/versions.env` pins version and sha256 per major.
- pg_clickhouse: latest release (0.11.1 as of 2026-11; requires PG ≥ 14). It builds with PGXS and has a
  git submodule (`vendor/pg-clickhouse-c`, header-only), so the build uses the PGXN distribution zip,
  which includes it (the GitHub release usually carries the same zip, but v0.11.1 has no asset).
- Versions move forward without a human: a scheduled workflow finds newer upstream releases, and
  builds, tests and releases them (see [CI](#ci)).

### Targets

Target names are Rust-style triples, the same ones `chctl` is built for, so `chctl` can match its own
target.

| Target triple | Build host | Runs on |
| --- | --- | --- |
| `aarch64-apple-darwin` | macOS arm64 (native) | macOS 11.0+ |
| `x86_64-apple-darwin` | macOS Intel runner | macOS 10.13+ |
| `x86_64-unknown-linux-musl` | Alpine 3.24 container | **any** Linux, glibc or musl (Alpine); no host libraries |
| `aarch64-unknown-linux-musl` | Alpine 3.24 container | **any** Linux, glibc or musl (Alpine); no host libraries |

Each target is built for both PostgreSQL majors: 8 bundles per release. The reasoning behind the Linux
and macOS baselines is in [Decisions: portability](#decisions-portability-2026-10-15).

### Naming

```
pg-<pgversion>-pgch-<pgchversion>-<target>.tar.gz
pg-<pgversion>-pgch-<pgchversion>-<target>.tar.gz.sha256
```

e.g. `pg-18.7-pgch-0.11.1-aarch64-apple-darwin.tar.gz`, `pg-17.12-pgch-0.11.1-x86_64-unknown-linux-musl.tar.gz`.
The full PostgreSQL version carries the major (`18.7` → 18), so there is no separate major field in the name;
`BUNDLE.json` has `postgres_version`. Names carry no build revision: a later release can publish the same
name with different bytes (a dependency was bumped), so a client keys its cache on name and sha256.

### Layout

The tarball has one top-level directory named like the archive (minus `.tar.gz`):

```
pg-18.7-pgch-0.11.1-aarch64-apple-darwin/
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
  "postgres_version": "18.7",
  "extensions": { "pg_clickhouse": "0.11.1" },
  "target": "aarch64-apple-darwin",
  "built_at": "2026-11-16T00:00:00Z",
  "source": { "repo": "sdairs/pg-bundles", "commit": "<sha>" },
  "configure": ["--with-openssl", "--without-icu", "..."]
}
```

### Release manifest

Every release carries a `manifest.json` asset that lists its bundles, so `chctl` finds the bundle for its
target and PostgreSQL major with one unauthenticated request to
`https://github.com/sdairs/pg-bundles/releases/latest/download/manifest.json` and no GitHub API:

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

`file` is relative to the manifest's own URL. There is exactly one bundle per `postgres_major` × `target`;
`sha256` and `size` are of the tarball. The `.sha256` sidecars are still published. The release job
generates the manifest from the built artifacts with `scripts/manifest.py`, and CI validates it on every
run: every expected major × target present, versions as pinned, sha256 and size equal to the files.

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

Run from an extracted copy in an unrelated temp directory, as a non-root user (PostgreSQL refuses to
run as root; see the root test below):

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
7. Assert the dependency closure: macOS (`otool -L`) only system libraries and the bundle's own, Mach-O
   minos ≤ `min_macos`; Linux (`readelf -d` and the bundled musl loader's `--list`) nothing outside the
   bundle and no `GLIBC_` symbol versions.

Linux bundles are also self-tested in other distro containers (`scripts/selftest-container.sh`):
`alpine:3.24` (musl), `centos:7` (glibc 2.17) and `debian:10` (glibc 2.28), besides the Ubuntu 24.04 runner.

**Root.** In the same containers, `scripts/selftest-root.sh` runs as root (the default user of
`docker run`) and does what a root caller has to do: keep the bundle root-owned, pick an unprivileged
user with an `/etc/passwd` entry (`nobody`, or a newly created system user), give it the instance
directory, run `initdb` and `postgres` as that user, and use the client tools and signals as root. It
runs two layouts: under root's home, which only works after `chmod o+x` on the 0700 home directory, and
outside it. The recipe and the `/dev/shm` findings are in the README ("Running as root").

Record bundle size (compressed and extracted) and time from extract to `pg_isready` success in the CI log
and in the release notes.

### CI

GitHub Actions in this repo:

- Matrix over PG majors {17, 18} × targets; macOS arm64 on `macos-15`, macOS x86_64 on `macos-15-intel`,
  Linux on `ubuntu-24.04` / `ubuntu-24.04-arm` running the build inside the Alpine container, then
  self-testing on the runner and in other distro containers (Alpine, CentOS 7, Debian 10), as an
  unprivileged user and as root.
- Every run generates and validates `manifest.json` from the built artifacts.
- On a tag (`v*`) it creates a GitHub release with every tarball + `.sha256` and `manifest.json`, and signs
  a build provenance attestation for the tarballs (`actions/attest-build-provenance`, as clickhousectl's
  release does; verify with `gh attestation verify <bundle> -R <repo>`).
- **Scheduled rebuilds** (`update.yml`, weekly and on dispatch): `scripts/check-updates.py` looks for a
  newer minor of each PostgreSQL major, a newer pg_clickhouse release and newer releases of the pinned
  dependencies that have a reliable source (OpenSSL 3.5.x, curl, lz4, zstd, zlib, util-linux), verifying
  each new tarball against the upstream-published hash. If anything is newer it commits the bump to a
  temporary branch, calls `build.yml` for that commit, and only when every self-test has passed
  fast-forwards `main` to it and publishes the next patch release. A push made with the default
  `GITHUB_TOKEN` triggers no workflow, so nothing depends on a pull request's CI: one run builds, tests
  and releases.
- Pin actions to commit SHAs (same rule as clickhousectl), images by digest.

Note: this repo is **public**, so release assets download without authentication, e.g.
`https://github.com/sdairs/pg-bundles/releases/download/<tag>/<bundle>.tar.gz`. The `chctl` prototype should
still accept a local file as well as a URL (for testing unreleased builds).

## Decisions: portability (2026-10-15)

### No glibc bundles (2026-11-16)

v0.2.0 also shipped `*-unknown-linux-gnu` bundles, built in the PyPA `manylinux2014` images (CentOS 7,
glibc 2.17). They are dropped: `chctl` only ever picks `<arch>-unknown-linux-musl`, which is its own
target triple and runs on every glibc host as well (self-tested on glibc 2.17, 2.28 and 2.39), so the
glibc bundles were four more builds per release that nothing downloaded. What a glibc build would give
(glibc collations, NSS user lookup) does not matter for local development. `build.sh` now refuses a
glibc host; the recipe is in the git history (v0.2.0) if it is ever wanted again.

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
5. **glibc bundles plus `gcompat` on Alpine**: a host package, and incomplete. Rejected.

Result: `<arch>-unknown-linux-musl` bundles run, self-tested with the pg_clickhouse foreign-table step, on
Alpine 3.24 (musl 1.2.6), CentOS 7 (glibc 2.17), Debian 10 (glibc 2.28) and Ubuntu 24.04 (glibc 2.39). The
self-test reads a backend's `/proc/self/maps` after loading pg_clickhouse and querying ClickHouse and
requires every mapped shared object, including libc, to be from the bundle. The only host requirement is
a Linux kernel (and `/bin/sh` for the things PostgreSQL itself runs through the shell, e.g. `pg_ctl`).
Naming the target `-unknown-linux-musl` matches `chctl`'s own Linux release triples, so `chctl` can pick
the bundle for its own target with no libc detection.

Costs of the musl bundles, all acceptable for local development:

- About 1 MiB larger compressed than the glibc bundle was (loader, launcher, slightly larger OpenSSL).
- `ps` shows the loader command line (`…/libexec/ld/postgres --library-path=… -- …/libexec/postgres -D …`)
  and PostgreSQL's process titles are squeezed into the `--argv0` value. `pgrep`/`pkill`/`top` show the
  right names.
- musl behaviour: collation is code-point order whatever `LC_COLLATE` says (ICU is not built anyway), the
  musl allocator is slower than glibc's, user lookup reads `/etc/passwd` (plus nscd) rather than NSS, so a
  directory-service (LDAP/sssd) user without a local passwd entry may fail `initdb`'s user lookup, and DNS
  uses `/etc/hosts` + `/etc/resolv.conf` only.
- Running a `libexec/` binary directly does not work on a glibc host (always go through `bin/`).

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
  with `pg_isready`. Postgres will not run as root: either refuse with a clear message, or drop
  privileges as `scripts/selftest-root.sh` does (README, "Running as root").
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
CLICKHOUSECTL_PG_RUNTIME=native CLICKHOUSECTL_PG_BUNDLE=file:///…/pg-18.7-pgch-0.11.1-aarch64-apple-darwin.tar.gz \
  chctl local postgres start
chctl local postgres client -q "CREATE EXTENSION pg_clickhouse; …query a ClickHouse table from Postgres…"
chctl local postgres stop
```

The write-up compares Docker vs native: download size (`postgres:18` image vs bundle), time to first
`pg_isready` (cold and warm), and the steps a new user needs. It ends with the asks:

1. Who owns building bundles long term (Postgres team, pg_clickhouse team, or clickhousectl)?
2. Hosting: `builds.clickhouse.com/postgres/…` or GitHub releases on a ClickHouse-org repo? Either way
   the client starts from one `manifest.json` URL (done, see [Release manifest](#release-manifest)).
3. Signing: sha256 files and GitHub artifact attestations are published; macOS notarization is open.
4. Which extensions ship by default (pg_clickhouse only, or also pg_re2, pgvector, …) and which platforms.
5. Does ClickHouse Cloud's managed Postgres already have a Postgres build pipeline worth reusing?

## Plan and next step

1. ~~macOS arm64 bundle, local build~~ (done).
2. ~~Linux x86_64/aarch64 bundles via a container build; same self-test~~ (done; v0.1.0 at glibc 2.28).
3. ~~GitHub Actions matrix + tagged release with assets~~ (done, v0.1.0).
4. ~~PostgreSQL 17; glibc 2.17; musl bundles that run on any Linux; macOS 11.0/10.13~~ (done, see
   decisions above).
5. ~~Licence, release manifest, build provenance, scheduled rebuilds, a root test; glibc bundles
   dropped~~ (done, this revision).
6. `clickhousectl` draft branch with the native backend described above (ClickHouse/clickhousectl#1098):
   pick the bundle from `manifest.json` by its own target triple (`*-unknown-linux-musl` on Linux) and
   the PG major.
7. `DEMO.md` with measured numbers and the asks; share.
