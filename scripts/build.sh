#!/usr/bin/env bash
# Build a relocatable PostgreSQL + pg_clickhouse bundle for the host platform.
#
#   scripts/build.sh                 # PostgreSQL 18 for the host, write dist/<name>.tar.gz(+.sha256)
#   PG_MAJOR=17 scripts/build.sh     # PostgreSQL 17
#
# Environment:
#   PG_MAJOR=<17|18>   PostgreSQL major to build (default 18; versions in versions.env)
#   JOBS=<n>           parallel make jobs (default: CPU count)
#   PGB_CLEAN=1        wipe the per-target build tree first (sources cache is kept)
#   PGB_KEEP_INCLUDE=1 keep include/ and lib/postgresql/pgxs (headers for building
#                      more extensions against the bundle); dropped by default
#   PGB_COMMIT=<sha>   commit recorded in BUNDLE.json (default: git rev-parse HEAD)
#   PGB_DIRTY=1        with PGB_COMMIT: mark the commit as having local changes
#   PGB_REPO=<o/r>     repo recorded in BUNDLE.json (default: $GITHUB_REPOSITORY or sdairs/pg-bundles)
#
# Linux bundles are meant to be built inside a container via
# scripts/build-linux.sh, which calls this script: manylinux2014 (glibc 2.17)
# for *-unknown-linux-gnu, Alpine for *-unknown-linux-musl. On a musl host
# (/lib/ld-musl-<arch>.so.1 exists) the target is *-unknown-linux-musl.
#
# Layout of the cache (all under .build/, gitignored):
#   .build/sources/                     verified source downloads, shared by all targets
#   .build/<target>/src/                extracted dependency sources
#   .build/<target>/deps/               dependency prefix (never shipped as a whole)
#   .build/<target>/stamps/             one stamp per completed dependency step
#   .build/<target>/pg-<ver>/src/       PostgreSQL and pg_clickhouse sources
#   .build/<target>/pg-<ver>/stage/pgbundle  PostgreSQL installed with DESTDIR (prefix=/pgbundle)
#   .build/<target>/pg-<ver>/pkg/<name>/     the bundle tree that gets tarred
#   .build/<target>/pg-<ver>/stamps/    stamps for the PostgreSQL / pg_clickhouse steps
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=versions.env
. "$ROOT/scripts/versions.env"

log() { printf '\n==> [%s] %s\n' "$(date -u +%H:%M:%S)" "$*" >&2; }
die() { printf 'error: %s\n' "$*" >&2; exit 1; }

# ---------------------------------------------------------------- target ----
OS="$(uname -s)"
ARCH="$(uname -m)"
LIBC=""
if [ "$OS" = Linux ]; then
  LIBC=gnu
  [ -e "/lib/ld-musl-$ARCH.so.1" ] && LIBC=musl
fi
case "$OS/$ARCH" in
  Darwin/arm64)   TARGET=aarch64-apple-darwin ;;
  Darwin/x86_64)  TARGET=x86_64-apple-darwin ;;
  Linux/x86_64)   TARGET=x86_64-unknown-linux-$LIBC ;;
  Linux/aarch64)  TARGET=aarch64-unknown-linux-$LIBC ;;
  *) die "unsupported host $OS/$ARCH" ;;
esac
# Cross builds are not supported; TARGET may only restate the host target.
if [ -n "${PGB_TARGET:-}" ] && [ "$PGB_TARGET" != "$TARGET" ]; then
  die "PGB_TARGET=$PGB_TARGET but host builds $TARGET (cross builds unsupported)"
fi

if [ "$OS" = Darwin ]; then
  JOBS="${JOBS:-$(sysctl -n hw.ncpu)}"
else
  JOBS="${JOBS:-$(nproc)}"
fi

NAME="pg-${PG_VERSION}-pgch-${PGCH_VERSION}-${TARGET}"
SRC_CACHE="$ROOT/.build/sources"
B="$ROOT/.build/$TARGET"
DEPS="$B/deps"
# PostgreSQL / pg_clickhouse build trees are per PostgreSQL version, so both
# majors can be built from the same dependency prefix without rebuilding.
PB="$B/pg-$PG_VERSION"
DESTDIR_ROOT="$PB/stage"
# PostgreSQL appends "/postgresql" to share/ and lib/ only when the prefix path
# does not already contain "postgres" or "pgsql". Install with a neutral prefix
# via DESTDIR so the layout is always lib/postgresql + share/postgresql no matter
# where this repo is checked out.
PG_PREFIX=/pgbundle
STAGE="$DESTDIR_ROOT$PG_PREFIX"
PKG_ROOT="$PB/pkg"
PKG="$PKG_ROOT/$NAME"
STAMPS="$B/stamps"
PG_STAMPS="$PB/stamps"
DIST="$ROOT/dist"

[ "${PGB_CLEAN:-0}" = 1 ] && { log "cleaning $B"; rm -rf "$B"; }
mkdir -p "$SRC_CACHE" "$B/src" "$PB/src" "$DEPS" "$STAMPS" "$PG_STAMPS" "$DIST"

# ----------------------------------------------------------- environment ----
# Keep the build hermetic: nothing from Homebrew (or any other package manager
# prefix) may be found by compilers, linkers, configure scripts or pkg-config.
unset CPATH C_INCLUDE_PATH CPLUS_INCLUDE_PATH LIBRARY_PATH LD_LIBRARY_PATH \
      DYLD_LIBRARY_PATH DYLD_FALLBACK_LIBRARY_PATH PKG_CONFIG_PATH \
      CFLAGS CPPFLAGS LDFLAGS LIBS CC CXX || true
export PKG_CONFIG_LIBDIR="$DEPS/lib/pkgconfig"
export PKG_CONFIG_PATH="$DEPS/lib/pkgconfig"

if [ "$OS" = Darwin ]; then
  export PATH=/usr/bin:/bin:/usr/sbin:/sbin
  # Oldest macOS the bundle runs on. 11.0 is the first release for Apple
  # silicon; 10.13 is the oldest deployment target current Xcode supports.
  case "$ARCH" in arm64) MIN_MACOS=11.0 ;; *) MIN_MACOS=10.13 ;; esac
  export MACOSX_DEPLOYMENT_TARGET="${MACOSX_DEPLOYMENT_TARGET:-$MIN_MACOS}"
  # Explicit -arch: under Rosetta (arch -x86_64) configure's child processes
  # would otherwise compile for arm64.
  export CC="/usr/bin/clang -arch $ARCH"
  sha256() { shasum -a 256 "$@"; }
  OPENSSL_PLATFORM="darwin64-${ARCH}-cc"
  # /etc/ssl/cert.pem is the system CA bundle on macOS.
  OPENSSL_DIR=/private/etc/ssl
else
  export CC="${CC_LINUX:-gcc}"
  sha256() { sha256sum "$@"; }
  OPENSSL_PLATFORM="linux-${ARCH}"
  # Debian/Ubuntu/Alpine/Arch keep hashed CA certs in /etc/ssl/certs. Other
  # distros can point OpenSSL at their bundle with SSL_CERT_FILE / SSL_CERT_DIR.
  OPENSSL_DIR=/etc/ssl
  # configure run-tests and build-time tools must find the shared OpenSSL/lz4/
  # zstd in the deps prefix; the shipped binaries get $ORIGIN RUNPATHs instead.
  export LD_LIBRARY_PATH="$DEPS/lib"
fi
DEP_CFLAGS="-O2 -fPIC"
PG_CFLAGS="-O2"
if [ "$OS" = Darwin ]; then
  # Fail the build (and configure checks) on any use of an API newer than the
  # deployment target that is not guarded by an availability check; otherwise
  # such a symbol links fine and only fails at load time on an older macOS.
  DEP_CFLAGS="$DEP_CFLAGS -Werror=unguarded-availability-new"
  PG_CFLAGS="$PG_CFLAGS -Werror=unguarded-availability-new"
fi

# ---------------------------------------------------------------- helpers ----
fetch() { # fetch "<url> [<mirror-url>...]" <sha256> -> path of verified file in the cache
  local urls="$1" want="$2" file url got
  # shellcheck disable=SC2086 # the URL list is space-separated on purpose
  set -- $urls
  file="$SRC_CACHE/$(basename "$1")"
  if [ -f "$file" ] && [ "$(sha256 "$file" | cut -d' ' -f1)" = "$want" ]; then
    printf '%s\n' "$file"; return
  fi
  for url in "$@"; do
    log "downloading $url"
    rm -f "$file.part"
    if ! curl -fsSL --retry 5 --retry-delay 3 --connect-timeout 30 -o "$file.part" "$url"; then
      log "download failed: $url"; continue
    fi
    got="$(sha256 "$file.part" | cut -d' ' -f1)"
    if [ "$got" = "$want" ]; then
      mv "$file.part" "$file"; printf '%s\n' "$file"; return
    fi
    log "sha256 mismatch for $url: got $got want $want"
  done
  rm -f "$file.part"
  die "could not download a file with sha256 $want from: $urls"
}

unpack() { # unpack <url> <sha256> <dirname> [<parent>] -> fresh extracted dir
  local archive dir="${4:-$B/src}/$3"
  archive="$(fetch "$1" "$2")"
  rm -rf "$dir"; mkdir -p "$dir"
  case "$archive" in
    *.zip) (cd "$dir" && unzip -q "$archive") ;;
    *)     tar -xf "$archive" -C "$dir" ;;
  esac
  # Most archives contain a single top-level dir; descend into it.
  local inner; inner="$(find "$dir" -mindepth 1 -maxdepth 1)"
  if [ "$(printf '%s\n' "$inner" | wc -l | tr -d ' ')" = 1 ] && [ -d "$inner" ]; then
    printf '%s\n' "$inner"
  else
    printf '%s\n' "$dir"
  fi
}

done_p() { [ -f "$STAMPS/$1" ]; }
mark()   { touch "$STAMPS/$1"; }
pg_done_p() { [ -f "$PG_STAMPS/$1" ]; }
pg_mark()   { touch "$PG_STAMPS/$1"; }

# ------------------------------------------------------------------ deps ----
# OpenSSL, lz4 and zstd are shared libraries shipped in the bundle's lib/ (they
# are used by many binaries). zlib, libedit, ncurses, libuuid and curl have one
# or two consumers each and are linked statically.
build_zlib() {
  local s="zlib-$ZLIB_VERSION"; done_p "$s" && return
  log "building $s"; local d; d="$(unpack "$ZLIB_URL" "$ZLIB_SHA256" "$s")"
  (cd "$d" && CFLAGS="$DEP_CFLAGS" ./configure --static --prefix="$DEPS" >/dev/null \
    && make -j"$JOBS" >/dev/null && make install >/dev/null)
  mark "$s"
}

build_openssl() {
  local s="openssl-$OPENSSL_VERSION"; done_p "$s" && return
  log "building $s ($OPENSSL_PLATFORM, openssldir=$OPENSSL_DIR)"
  local d; d="$(unpack "$OPENSSL_URL" "$OPENSSL_SHA256" "$s")"
  # Shared: libcrypto is used by postgres, libpq, pg_dump & co, pgcrypto,
  # sslinfo and pg_clickhouse; static linking would copy it into each of them.
  (cd "$d" && ./Configure "$OPENSSL_PLATFORM" --prefix="$DEPS" --libdir=lib \
      --openssldir="$OPENSSL_DIR" shared no-module no-tests no-docs no-apps \
      no-legacy >/dev/null \
    && make -j"$JOBS" build_libs >/dev/null && make install_dev >/dev/null)
  rm -f "$DEPS/lib/libssl.a" "$DEPS/lib/libcrypto.a"
  mark "$s"
}

build_lz4() {
  local s="lz4-$LZ4_VERSION"; done_p "$s" && return
  log "building $s"; local d; d="$(unpack "$LZ4_URL" "$LZ4_SHA256" "$s")"
  (cd "$d" && make -C lib -j"$JOBS" lib PREFIX="$DEPS" CFLAGS="$DEP_CFLAGS" >/dev/null \
    && make -C lib install PREFIX="$DEPS" BUILD_STATIC=no >/dev/null)
  mark "$s"
}

build_zstd() {
  local s="zstd-$ZSTD_VERSION"; done_p "$s" && return
  log "building $s"; local d; d="$(unpack "$ZSTD_URL" "$ZSTD_SHA256" "$s")"
  (cd "$d" && make -C lib -j"$JOBS" libzstd PREFIX="$DEPS" CFLAGS="$DEP_CFLAGS" >/dev/null \
    && make -C lib install-shared install-includes install-pc PREFIX="$DEPS" >/dev/null)
  mark "$s"
}

build_curl() {
  local s="curl-$CURL_VERSION"; done_p "$s" && return
  log "building $s (HTTP/HTTPS only, OpenSSL)"
  local d; d="$(unpack "$CURL_URL" "$CURL_SHA256" "$s")"
  (cd "$d" && CFLAGS="$DEP_CFLAGS" CPPFLAGS="-I$DEPS/include" LDFLAGS="-L$DEPS/lib" \
    ./configure --prefix="$DEPS" --disable-shared --enable-static --with-pic \
      --with-openssl="$DEPS" --without-ca-bundle --without-ca-path --with-ca-fallback \
      --without-zlib --without-brotli --without-zstd --without-libpsl --without-libidn2 \
      --without-nghttp2 --without-nghttp3 --without-ngtcp2 --without-libssh2 \
      --without-libssh --without-libgsasl --without-apple-idn \
      --disable-ldap --disable-ldaps --disable-rtsp --disable-dict --disable-telnet \
      --disable-tftp --disable-pop3 --disable-imap --disable-smtp \
      --disable-gopher --disable-mqtt --disable-ftp --disable-file --disable-ipfs \
      --disable-websockets --disable-manual --disable-docs --disable-ntlm \
      --disable-kerberos-auth --disable-negotiate-auth --disable-aws \
      >/dev/null \
    && make -j"$JOBS" >/dev/null && make install >/dev/null)
  mark "$s"
}

build_libuuid() {
  local s="libuuid-$UTIL_LINUX_VERSION"; done_p "$s" && return
  log "building $s"; local d; d="$(unpack "$UTIL_LINUX_URL" "$UTIL_LINUX_SHA256" "util-linux-$UTIL_LINUX_VERSION")"
  (cd "$d" && CFLAGS="$DEP_CFLAGS" ./configure --prefix="$DEPS" --disable-all-programs \
      --enable-libuuid --disable-shared --enable-static --without-python \
      --disable-bash-completion --without-systemd --disable-nls --disable-liblastlog2 >/dev/null \
    && make -j"$JOBS" >/dev/null && make install >/dev/null)
  mark "$s"
}

build_ncurses() {
  local s="ncurses-$NCURSES_VERSION"; done_p "$s" && return
  log "building $s (static, termlib for libedit)"
  local d; d="$(unpack "$NCURSES_URL" "$NCURSES_SHA256" "$s")"
  # The terminfo database is read from the host at runtime (no db installed).
  (cd "$d" && CFLAGS="$DEP_CFLAGS" ./configure --prefix="$DEPS" --without-shared \
      --without-debug --without-cxx --without-cxx-binding --without-ada \
      --without-manpages --without-progs --without-tests --disable-db-install \
      --disable-widec --disable-pc-files \
      --with-default-terminfo-dir=/usr/share/terminfo \
      --with-terminfo-dirs=/etc/terminfo:/lib/terminfo:/usr/share/terminfo:/usr/lib/terminfo \
      >/dev/null \
    && make -j"$JOBS" >/dev/null && make install >/dev/null)
  mark "$s"
}

build_libedit() {
  local s="libedit-$LIBEDIT_VERSION"; done_p "$s" && return
  log "building $s"; local d; d="$(unpack "$LIBEDIT_URL" "$LIBEDIT_SHA256" "$s")"
  (cd "$d" && CFLAGS="$DEP_CFLAGS" CPPFLAGS="-I$DEPS/include -I$DEPS/include/ncurses" \
      LDFLAGS="-L$DEPS/lib" ./configure --prefix="$DEPS" \
      --disable-shared --enable-static --disable-examples >/dev/null \
    && make -j"$JOBS" >/dev/null && make install >/dev/null)
  mark "$s"
}

# ------------------------------------------------------------ PostgreSQL ----
PG_CONFIGURE=(--prefix="$PG_PREFIX" --with-openssl --without-icu --with-lz4 --with-zstd
              --with-libedit-preferred --disable-rpath)

build_postgres() {
  local s="postgresql-$PG_VERSION"; pg_done_p "$s" && return
  log "building $s"
  local d; d="$(unpack "$PG_URL" "$PG_SHA256" "$s" "$PB/src")"
  (cd "$d" && CFLAGS="$PG_CFLAGS" \
    LZ4_CFLAGS="-I$DEPS/include" LZ4_LIBS="-L$DEPS/lib -llz4" \
    ZSTD_CFLAGS="-I$DEPS/include" ZSTD_LIBS="-L$DEPS/lib -lzstd" \
    ./configure "${PG_CONFIGURE[@]}" \
      --with-includes="$DEPS/include" --with-libraries="$DEPS/lib" >"$PB/pg-configure.log" 2>&1 \
    || { tail -50 "$PB/pg-configure.log"; config_log_tail "$d"; exit 1; })
  log "make world-bin (-j$JOBS)"
  (cd "$d" && make -j"$JOBS" world-bin >"$PB/pg-make.log" 2>&1) || { tail -80 "$PB/pg-make.log"; exit 1; }
  rm -rf "$DESTDIR_ROOT"
  (cd "$d" && make install-world-bin DESTDIR="$DESTDIR_ROOT" >"$PB/pg-install.log" 2>&1) \
    || { tail -40 "$PB/pg-install.log"; exit 1; }
  rm -f "$PG_STAMPS/pg_clickhouse-"*  # the extension must be reinstalled into a fresh stage
  pg_mark "$s"
}
config_log_tail() { [ -f "$1/config.log" ] && tail -60 "$1/config.log" >&2 || true; }

# --------------------------------------------------------- pg_clickhouse ----
build_pg_clickhouse() {
  local s="pg_clickhouse-$PGCH_VERSION"; pg_done_p "$s" && return
  log "building $s for PostgreSQL $PG_VERSION"
  local d; d="$(unpack "$PGCH_URL" "$PGCH_SHA256" "$s" "$PB/src")"
  # The release zip ships the vendored submodules but no .gitmodules; give the
  # Makefile's submodule rule an old prerequisite so it never runs git.
  touch -t 200001010000 "$d/.gitmodules"
  # pg_clickhouse links `$(CURL_CONFIG) --libs`; with a static libcurl that must
  # be the static link line (curl + OpenSSL + system libs, in that order).
  local cc="$PB/curl-config-static"
  cat >"$cc" <<EOF
#!/bin/sh
case "\$1" in
  --libs) exec "$DEPS/bin/curl-config" --static-libs ;;
  *)      exec "$DEPS/bin/curl-config" "\$@" ;;
esac
EOF
  chmod +x "$cc"
  local mk=(PG_CONFIG="$STAGE/bin/pg_config" CURL_CONFIG="$cc")
  if [ "$LIBC" = musl ]; then
    # Alpine's GCC 15 defaults to C23, where clickhouse-c uses unreachable()
    # from <stddef.h>, which musl's header does not define yet: build as C17.
    # pg_clickhouse also uses -Werror -Wclobbered, and GCC 15 reports
    # "might be clobbered" warnings GCC 10 and clang do not; CFLAGS_SL comes
    # after the extension's -Werror on the compile line, so keep that one a
    # warning there.
    mk+=(COPT=-std=gnu17 CFLAGS_SL="-fPIC -Wno-error=clobbered")
  fi
  (cd "$d" && make -j"$JOBS" "${mk[@]}" >"$PB/pgch-make.log" 2>&1 && make "${mk[@]}" install >>"$PB/pgch-make.log" 2>&1) \
    || { tail -60 "$PB/pgch-make.log"; exit 1; }
  pg_mark "$s"
}

# ------------------------------------------------------------- packaging ----
is_macho() { file -b "$1" | grep '^Mach-O' >/dev/null; }
is_elf()   { file -b "$1" | grep '^ELF' >/dev/null; }

# Relative path from directory $1 to bundle lib/ (both inside $PKG).
rel_to_lib() {
  case "${1#"$PKG"/}" in
    bin|libexec) echo ../lib ;;
    lib) echo . ;;
    lib/postgresql) echo .. ;;
    *) die "unexpected binary dir $1" ;;
  esac
}

fix_macho() {
  local f="$1" dir rel changed=0 dep base
  dir="$(dirname "$f")"; rel="$(rel_to_lib "$dir")"
  strip -x "$f" 2>/dev/null || true
  if [ "$(dirname "$f")" = "$PKG/lib" ] && file -b "$f" | grep 'dynamically linked shared library' >/dev/null; then
    install_name_tool -id "@rpath/$(basename "$f")" "$f" 2>/dev/null
  fi
  # Rewrite every non-system dependency to @rpath/<basename>; it must be bundled.
  while read -r dep; do
    case "$dep" in
      /usr/lib/*|/System/Library/*|@rpath/*|@loader_path/*|@executable_path/*) ;;
      *)
        base="$(basename "$dep")"
        [ -e "$PKG/lib/$base" ] || die "$f depends on $dep which is not bundled"
        install_name_tool -change "$dep" "@rpath/$base" "$f" 2>/dev/null
        changed=1 ;;
    esac
  done < <(otool -L "$f" | tail -n +2 | awk '{print $1}')
  # Drop absolute LC_RPATHs, then add the bundle-relative one if needed.
  while read -r rp; do
    case "$rp" in @*) ;; *) install_name_tool -delete_rpath "$rp" "$f" 2>/dev/null ;; esac
  done < <(otool -l "$f" | awk '/cmd LC_RPATH/{getline; getline; print $2}')
  if otool -L "$f" | tail -n +2 | grep '@rpath/' >/dev/null; then
    local want="@loader_path/$rel"; [ "$rel" = . ] && want="@loader_path"
    otool -l "$f" | awk '/cmd LC_RPATH/{getline; getline; print $2}' | grep -x "$want" >/dev/null \
      || install_name_tool -add_rpath "$want" "$f" 2>/dev/null
  fi
  : "$changed"
  codesign -f -s - "$f" 2>/dev/null
}

fix_elf() {
  local f="$1" dir rel needs_bundled=0 n
  dir="$(dirname "$f")"; rel="$(rel_to_lib "$dir")"
  strip --strip-unneeded "$f"
  for n in $(patchelf --print-needed "$f"); do
    [ -e "$PKG/lib/$n" ] && needs_bundled=1
  done
  if [ "$needs_bundled" = 1 ]; then
    local want='$ORIGIN'; [ "$rel" != . ] && want="\$ORIGIN/$rel"
    patchelf --set-rpath "$want" "$f"
  else
    patchelf --remove-rpath "$f"
  fi
}

check_elf_undefined() {
  # Static archives are order-sensitive with GNU ld; a shared object linked in
  # the wrong order still links (undefined symbols are allowed) but fails at
  # load time. Make sure pg_clickhouse resolved its statically linked curl and
  # libuuid, and links the bundled shared OpenSSL/lz4/zstd.
  local so="$PKG/lib/postgresql/pg_clickhouse.so" bad n
  bad="$(nm -D --undefined-only "$so" | awk '$1 == "U" {print $2}' \
        | grep -E '^(curl_|Curl_|uuid_)' || true)"
  [ -z "$bad" ] || die "pg_clickhouse.so has unresolved statically linked symbols: $(echo "$bad" | sed -n 1,5p | tr '\n' ' ')"
  for n in libssl.so.3 libcrypto.so.3 liblz4.so.1 libzstd.so.1; do
    patchelf --print-needed "$so" | grep -x "$n" >/dev/null || die "pg_clickhouse.so does not link $n"
  done
}

# Highest GLIBC_x.y symbol version any bundled ELF file needs.
max_glibc_symbol() {
  find "$PKG/bin" "$PKG/lib" -type f -exec objdump -T {} + 2>/dev/null \
    | grep -o 'GLIBC_[0-9][0-9.]*' | sed 's/GLIBC_//' | sort -t. -k1,1n -k2,2n -k3,3n | tail -1 || true
}

# musl: ship the build image's dynamic loader (which is also musl's libc) and
# a launcher per executable.
LDSO="ld-musl-$ARCH.so.1"
package_musl_runtime() {
  local v
  v="$("/lib/$LDSO" 2>&1 | sed -n 's/^Version //p' || true)"
  [ "$v" = "$MUSL_VERSION" ] || die "build image has musl $v, versions.env pins MUSL_VERSION=$MUSL_VERSION"
  cp -L "/lib/$LDSO" "$PKG/lib/$LDSO"
  chmod 755 "$PKG/lib/$LDSO"
  local d; d="$(unpack "$MUSL_URL" "$MUSL_SHA256" "musl-$MUSL_VERSION")"
  cp "$d/COPYRIGHT" "$PKG/share/licenses/musl.txt"
  "$CC" -static -Os -s -Wall -Werror -o "$PB/launcher" "$ROOT/scripts/launcher.c"
  # One launcher, hard-linked under every program name (it finds its own name
  # via /proc/self/exe), so the tarball stores it once; and a symlink to the
  # loader per program, which sets the process name (see launcher.c).
  local f n first=""
  mkdir -p "$PKG/libexec/ld"
  for f in "$PKG/libexec/"*; do
    [ -f "$f" ] || continue
    n="$(basename "$f")"
    if [ -z "$first" ]; then
      first="$PKG/bin/$n"; cp "$PB/launcher" "$first"
    else
      ln "$first" "$PKG/bin/$n"
    fi
    ln -s "../../lib/$LDSO" "$PKG/libexec/ld/$n"
  done
}

json_list() { local first=1 x; printf '['; for x in "$@"; do [ $first = 1 ] || printf ', '; first=0; printf '"%s"' "$x"; done; printf ']'; }

package() {
  log "packaging $NAME"
  rm -rf "$PKG_ROOT"; mkdir -p "$PKG"
  cp -a "$STAGE/." "$PKG/"
  if [ "${PGB_KEEP_INCLUDE:-0}" != 1 ]; then
    rm -rf "$PKG/include" "$PKG/lib/postgresql/pgxs"
  fi
  rm -rf "$PKG/lib/pkgconfig"
  find "$PKG/lib" -maxdepth 1 -name '*.a' -delete
  # Shared dependencies (and their version symlinks).
  local pat
  for pat in 'libssl.*' 'libcrypto.*' 'liblz4.*' 'libzstd.*'; do
    find "$DEPS/lib" -maxdepth 1 -name "$pat" \( -name '*.so*' -o -name '*.dylib' \) -exec cp -a {} "$PKG/lib/" \;
  done

  # Licences of everything statically linked into the bundle.
  local lic="$PKG/share/licenses"; mkdir -p "$lic"
  cp "$PB/src/postgresql-$PG_VERSION"/*/COPYRIGHT "$lic/postgresql.txt"
  cp "$PB/src/pg_clickhouse-$PGCH_VERSION"/*/LICENSE.md "$lic/pg_clickhouse.md"
  cp "$B/src/openssl-$OPENSSL_VERSION"/*/LICENSE.txt "$lic/openssl.txt"
  cp "$B/src/curl-$CURL_VERSION"/*/COPYING "$lic/curl.txt"
  cp "$B/src/lz4-$LZ4_VERSION"/*/lib/LICENSE "$lic/lz4.txt"
  cp "$B/src/zstd-$ZSTD_VERSION"/*/LICENSE "$lic/zstd.txt"
  if [ "$OS" = Linux ]; then
    cp "$B/src/zlib-$ZLIB_VERSION"/*/LICENSE "$lic/zlib.txt"
    cp "$B/src/libedit-$LIBEDIT_VERSION"/*/COPYING "$lic/libedit.txt"
    cp "$B/src/ncurses-$NCURSES_VERSION"/*/COPYING "$lic/ncurses.txt"
    cp "$B/src/util-linux-$UTIL_LINUX_VERSION"/*/libuuid/COPYING "$lic/libuuid.txt"
  fi

  # musl: the real executables move to libexec/; bin/ gets launchers that run
  # them through the bundled loader (see scripts/launcher.c).
  [ "$LIBC" = musl ] && { mkdir -p "$PKG/libexec"; mv "$PKG/bin/"* "$PKG/libexec/"; }

  local f bindirs=("$PKG/bin" "$PKG/lib")
  [ "$LIBC" = musl ] && bindirs=("$PKG/libexec" "$PKG/lib")
  while IFS= read -r -d '' f; do
    [ -L "$f" ] && continue
    if [ "$OS" = Darwin ]; then is_macho "$f" && fix_macho "$f"
    else is_elf "$f" && fix_elf "$f"; fi
  done < <(find "${bindirs[@]}" -maxdepth 2 -type f -print0)
  [ "$OS" = Linux ] && check_elf_undefined
  [ "$LIBC" = musl ] && package_musl_runtime

  local commit repo dirty="" deps_json
  commit="${PGB_COMMIT:-$(git -C "$ROOT" rev-parse HEAD 2>/dev/null || echo unknown)}"
  if [ -n "${PGB_COMMIT:-}" ]; then
    [ "${PGB_DIRTY:-0}" = 1 ] && dirty=", \"dirty\": true"
  elif [ -n "$(git -C "$ROOT" status --porcelain --untracked-files=no 2>/dev/null)" ]; then
    dirty=", \"dirty\": true"
  fi
  repo="${PGB_REPO:-${GITHUB_REPOSITORY:-sdairs/pg-bundles}}"
  deps_json="\"openssl\": \"$OPENSSL_VERSION\", \"curl\": \"$CURL_VERSION\", \"lz4\": \"$LZ4_VERSION\", \"zstd\": \"$ZSTD_VERSION\""
  local platform_json
  if [ "$LIBC" = gnu ]; then
    deps_json="$deps_json, \"zlib\": \"$ZLIB_VERSION\", \"libedit\": \"$LIBEDIT_VERSION\", \"ncurses\": \"$NCURSES_VERSION\", \"libuuid\": \"util-linux $UTIL_LINUX_VERSION\""
    platform_json="\"libc\": \"glibc\", \"min_glibc\": \"$(max_glibc_symbol)\""
  elif [ "$LIBC" = musl ]; then
    deps_json="$deps_json, \"zlib\": \"$ZLIB_VERSION\", \"libedit\": \"$LIBEDIT_VERSION\", \"ncurses\": \"$NCURSES_VERSION\", \"libuuid\": \"util-linux $UTIL_LINUX_VERSION\", \"musl\": \"$MUSL_VERSION\""
    platform_json="\"libc\": \"musl\", \"bundled_loader\": \"lib/$LDSO\", \"host_libc\": [\"glibc\", \"musl\"]"
  else
    platform_json="\"min_macos\": \"$MACOSX_DEPLOYMENT_TARGET\""
  fi
  cat >"$PKG/BUNDLE.json" <<EOF
{
  "postgres_version": "$PG_VERSION",
  "extensions": { "pg_clickhouse": "$PGCH_VERSION" },
  "target": "$TARGET",
  "built_at": "$(date -u +%Y-%m-%dT%H:%M:%SZ)",
  "source": { "repo": "$repo", "commit": "$commit"$dirty },
  "configure": $(json_list "${PG_CONFIGURE[@]}"),
  "dependencies": { $deps_json },
  "platform": { $platform_json, "openssldir": "$OPENSSL_DIR" }
}
EOF

  local tgz="$DIST/$NAME.tar.gz"
  rm -f "$tgz" "$tgz.sha256"
  if tar --version 2>/dev/null | grep 'GNU tar' >/dev/null; then
    # Sorted member list (GNU tar 1.26 in CentOS 7 has no --sort=name).
    (cd "$PKG_ROOT" && find "$NAME" -print0 | LC_ALL=C sort -z \
      | tar --owner=0 --group=0 --numeric-owner --no-recursion --null -T - -cf -) | gzip -9n >"$tgz"
  else
    COPYFILE_DISABLE=1 tar -C "$PKG_ROOT" --uid 0 --gid 0 --no-xattrs --no-mac-metadata -cf - "$NAME" | gzip -9n >"$tgz"
  fi
  (cd "$DIST" && sha256 "$NAME.tar.gz" >"$NAME.tar.gz.sha256")
  local csize esize
  csize="$(wc -c <"$tgz" | tr -d ' ')"
  esize="$(du -sk "$PKG" | awk '{print $1*1024}')"
  log "wrote $tgz"
  awk -v n="$NAME" -v c="$csize" -v e="$esize" -v h="$(cut -d' ' -f1 "$tgz.sha256")" 'BEGIN {
    printf "bundle: %s\ncompressed: %d bytes (%.1f MiB)\nextracted:  %d bytes (%.1f MiB)\nsha256: %s\n", n, c, c/1048576, e, e/1048576, h }'
}

# ------------------------------------------------------------------ main ----
START=$(date +%s)
log "target $TARGET, $JOBS jobs, bundle $NAME"
if [ "$OS" = Linux ]; then
  build_zlib
  build_ncurses
  build_libedit
  build_libuuid
fi
build_openssl
build_lz4
build_zstd
build_curl
build_postgres
build_pg_clickhouse
package
log "done in $(( $(date +%s) - START ))s"
