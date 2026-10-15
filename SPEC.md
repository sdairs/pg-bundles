# pg-bundles: portable Postgres + pg_clickhouse builds

Status: **prototype**. This repo exists to answer one question for the wider team: *should ClickHouse
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

### Non-goals

- Publishing to `builds.clickhouse.com`, code signing/notarization, SBOMs, provenance beyond sha256.
- Windows. Extensions other than pg_clickhouse (pg_re2, pgvector, PostGIS come later, if ever).
- Production-quality `chctl` code: no docs, help-text rewrite, migration of existing Docker instances or
  full test suite in the prototype branch.

## What a bundle is

### Versions

- PostgreSQL majors **17** and **18**, latest minor of each (18.6, 17.11 as of 2026-10). Start with 18 only.
- pg_clickhouse: latest release tag (v0.11.0 as of 2026-10; requires PG ≥ 14). It builds with PGXS and has a
  git submodule (`vendor/pg-clickhouse-c`, header-only), so clone with `--recurse-submodules` or use the
  release zip.

### Targets

| Target triple | Build host | Priority |
| --- | --- | --- |
| `aarch64-apple-darwin` | macOS arm64 (native) | 1 — do first |
| `x86_64-unknown-linux-gnu` | Linux container, old glibc baseline | 2 |
| `aarch64-unknown-linux-gnu` | Linux container, old glibc baseline | 2 |
| `x86_64-apple-darwin` | macOS (cross or Intel runner) | 3 |

Linux baseline: glibc **2.28** (e.g. build inside a `manylinux_2_28` / AlmaLinux 8 / Debian 10-era image) so
the binaries run on any reasonably current distro. Fully static musl is an acceptable alternative if glibc
turns out harder; record whichever is chosen and why.

### Naming

```
pg-<pgversion>-pgch-<pgchversion>-<target>.tar.gz
pg-<pgversion>-pgch-<pgchversion>-<target>.tar.gz.sha256
```

e.g. `pg-18.6-pgch-0.11.0-aarch64-apple-darwin.tar.gz`.

### Layout

The tarball has one top-level directory named like the archive (minus `.tar.gz`):

```
pg-18.6-pgch-0.11.0-aarch64-apple-darwin/
  bin/      postgres initdb pg_ctl psql pg_isready pg_dump pg_restore pg_config createdb …
  lib/      libpq.*, postgresql/*.so (incl. pg_clickhouse.so, contrib modules), any bundled dylibs/.so
  share/    postgresql/… (timezone data, extension/*.control + *.sql incl. pg_clickhouse)
  include/  optional; drop if size matters
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
5. Stop with `bin/pg_ctl -D $TMP/data stop -m fast`.
6. Assert the dependency closure (`otool -L` / `ldd` / `readelf -d`) contains only allowed system libraries.

Record bundle size (compressed and extracted) and time from extract to `pg_isready` success in the CI log
and in the release notes.

### CI

GitHub Actions in this repo:

- Matrix over targets (and PG majors once 18 works); macOS arm64 on `macos-14`/`macos-15`, Linux on
  `ubuntu-latest` / `ubuntu-24.04-arm` running the build inside the glibc-2.28 container.
- Runs the self-test, then on a tag (`v*`) creates a GitHub release with every tarball + `.sha256`.
- Pin actions to commit SHAs (same rule as clickhousectl).

Note: this repo is **public**, so release assets download without authentication, e.g.
`https://github.com/sdairs/pg-bundles/releases/download/<tag>/<bundle>.tar.gz`. The `chctl` prototype should
still accept a local file as well as a URL (for testing unreleased builds).

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

1. **Next step — macOS arm64 bundle, local build.** Write `scripts/build.sh` that builds PG 18.6 + pg_clickhouse
   0.11.0 with static OpenSSL/curl/lz4/zstd on this Mac, packages the tarball with `BUNDLE.json`, and a
   `scripts/selftest.sh` that runs the self-test above. Done when the tarball, extracted to a random
   directory with Homebrew's lib dirs hidden from it, passes the self-test including `CREATE EXTENSION
   pg_clickhouse`, and `otool -L` shows only system libraries. Commit with a `README.md` covering how to
   build and test.
2. Linux x86_64/aarch64 bundles via a glibc-2.28 container build; same self-test.
3. GitHub Actions matrix + tagged release with assets.
4. `clickhousectl` draft branch with the native backend described above.
5. `DEMO.md` with measured numbers and the asks; share.
