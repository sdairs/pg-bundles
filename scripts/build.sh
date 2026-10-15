#!/usr/bin/env bash
# Build a relocatable PostgreSQL + pg_clickhouse bundle for the host platform.
#
#   scripts/build.sh            # build for the host, write dist/<name>.tar.gz(+.sha256)
#
# Environment:
#   JOBS=<n>           parallel make jobs (default: CPU count)
#   PGB_CLEAN=1        wipe the per-target build tree first (sources cache is kept)
#   PGB_KEEP_INCLUDE=1 keep include/ and lib/postgresql/pgxs (headers for building
#                      more extensions against the bundle); dropped by default
#   PGB_COMMIT=<sha>   commit recorded in BUNDLE.json (default: git rev-parse HEAD)
#   PGB_REPO=<o/r>     repo recorded in BUNDLE.json (default: $GITHUB_REPOSITORY or sdairs/pg-bundles)
#
# Linux bundles are meant to be built inside the glibc 2.28 container via
# scripts/build-linux.sh, which calls this script.
#
# Layout of the cache (all under .build/, gitignored):
#   .build/sources/                 verified source downloads, shared by all targets
#   .build/<target>/src/            extracted sources
#   .build/<target>/deps/           static dependency prefix (never shipped)
#   .build/<target>/stage/pgbundle  PostgreSQL installed with DESTDIR (prefix=/pgbundle)
#   .build/<target>/pkg/<name>/     the bundle tree that gets tarred
#   .build/<target>/stamps/         one stamp per completed step, keyed by version
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=versions.env
. "$ROOT/scripts/versions.env"

log() { printf '\n==> [%s] %s\n' "$(date -u +%H:%M:%S)" "$*" >&2; }
die() { printf 'error: %s\n' "$*" >&2; exit 1; }

# ---------------------------------------------------------------- target ----
OS="$(uname -s)"
ARCH="$(uname -m)"
case "$OS/$ARCH" in
  Darwin/arm64)   TARGET=aarch64-apple-darwin ;;
  Darwin/x86_64)  TARGET=x86_64-apple-darwin ;;
  Linux/x86_64)   TARGET=x86_64-unknown-linux-gnu ;;
  Linux/aarch64)  TARGET=aarch64-unknown-linux-gnu ;;
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
DESTDIR_ROOT="$B/stage"
# PostgreSQL appends "/postgresql" to share/ and lib/ only when the prefix path
# does not already contain "postgres" or "pgsql". Install with a neutral prefix
# via DESTDIR so the layout is always lib/postgresql + share/postgresql no matter
# where this repo is checked out.
PG_PREFIX=/pgbundle
STAGE="$DESTDIR_ROOT$PG_PREFIX"
PKG_ROOT="$B/pkg"
PKG="$PKG_ROOT/$NAME"
STAMPS="$B/stamps"
DIST="$ROOT/dist"

[ "${PGB_CLEAN:-0}" = 1 ] && { log "cleaning $B"; rm -rf "$B"; }
mkdir -p "$SRC_CACHE" "$B/src" "$DEPS" "$STAMPS" "$DIST"

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
  export MACOSX_DEPLOYMENT_TARGET="${MACOSX_DEPLOYMENT_TARGET:-12.0}"
  export CC=/usr/bin/clang
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
fi
DEP_CFLAGS="-O2 -fPIC"

# ---------------------------------------------------------------- helpers ----
fetch() { # fetch <url> <sha256> -> path of verified file in the cache
  local url="$1" want="$2" file
  file="$SRC_CACHE/$(basename "$url")"
  if [ -f "$file" ] && [ "$(sha256 "$file" | cut -d' ' -f1)" = "$want" ]; then
    printf '%s\n' "$file"; return
  fi
  log "downloading $url"
  curl -fsSL --retry 3 -o "$file.part" "$url"
  local got; got="$(sha256 "$file.part" | cut -d' ' -f1)"
  [ "$got" = "$want" ] || { rm -f "$file.part"; die "sha256 mismatch for $url: got $got want $want"; }
  mv "$file.part" "$file"
  printf '%s\n' "$file"
}

unpack() { # unpack <url> <sha256> <dirname> -> fresh extracted dir
  local archive dir="$B/src/$3"
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

# ----------------------------------------------------------- static deps ----
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
  (cd "$d" && ./Configure "$OPENSSL_PLATFORM" --prefix="$DEPS" --libdir=lib \
      --openssldir="$OPENSSL_DIR" no-shared no-module no-tests no-docs no-apps \
      no-legacy -fPIC >/dev/null \
    && make -j"$JOBS" build_libs >/dev/null && make install_dev >/dev/null)
  mark "$s"
}

build_lz4() {
  local s="lz4-$LZ4_VERSION"; done_p "$s" && return
  log "building $s"; local d; d="$(unpack "$LZ4_URL" "$LZ4_SHA256" "$s")"
  (cd "$d" && make -C lib -j"$JOBS" liblz4.a CFLAGS="$DEP_CFLAGS" >/dev/null \
    && make -C lib install PREFIX="$DEPS" BUILD_SHARED=no >/dev/null)
  mark "$s"
}

build_zstd() {
  local s="zstd-$ZSTD_VERSION"; done_p "$s" && return
  log "building $s"; local d; d="$(unpack "$ZSTD_URL" "$ZSTD_SHA256" "$s")"
  (cd "$d" && make -C lib -j"$JOBS" libzstd.a CFLAGS="$DEP_CFLAGS" >/dev/null \
    && make -C lib install-static install-includes install-pc PREFIX="$DEPS" >/dev/null)
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
      --without-libssh --without-librtmp --without-libgsasl --without-apple-idn \
      --disable-ldap --disable-ldaps --disable-rtsp --disable-dict --disable-telnet \
      --disable-tftp --disable-pop3 --disable-imap --disable-smb --disable-smtp \
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
      --enable-widec --disable-pc-files \
      --with-default-terminfo-dir=/usr/share/terminfo \
      --with-terminfo-dirs=/etc/terminfo:/lib/terminfo:/usr/share/terminfo:/usr/lib/terminfo \
      >/dev/null \
    && make -j"$JOBS" >/dev/null && make install >/dev/null)
  mark "$s"
}

build_libedit() {
  local s="libedit-$LIBEDIT_VERSION"; done_p "$s" && return
  log "building $s"; local d; d="$(unpack "$LIBEDIT_URL" "$LIBEDIT_SHA256" "$s")"
  (cd "$d" && CFLAGS="$DEP_CFLAGS" CPPFLAGS="-I$DEPS/include -I$DEPS/include/ncursesw" \
      LDFLAGS="-L$DEPS/lib" LIBS="-lncursesw" ./configure --prefix="$DEPS" \
      --disable-shared --enable-static --disable-examples >/dev/null \
    && make -j"$JOBS" >/dev/null && make install >/dev/null)
  mark "$s"
}

# ------------------------------------------------------------ PostgreSQL ----
PG_CONFIGURE=(--prefix="$PG_PREFIX" --with-openssl --without-icu --with-lz4 --with-zstd
              --with-libedit-preferred --disable-rpath)

build_postgres() {
  local s="postgresql-$PG_VERSION"; done_p "$s" && return
  log "building $s"
  local d; d="$(unpack "$PG_URL" "$PG_SHA256" "$s")"
  # libpq's build refuses any reference to a symbol containing "exit". Statically
  # linked OpenSSL references atexit() and pthread_exit() (cleanup handlers and
  # its thread code), neither of which exits the process. Upstream skips this
  # check for statically linked infrastructure on some platforms already; widen
  # its allow-list instead of disabling it.
  sed -i.orig -e 's/grep -v -e __cxa_atexit -e __tsan_func_exit/grep -v -e atexit -e pthread_exit -e __tsan_func_exit/' \
    "$d/src/interfaces/libpq/Makefile"
  grep -q 'grep -v -e atexit -e pthread_exit' "$d/src/interfaces/libpq/Makefile" || die "libpq Makefile patch failed"
  (cd "$d" && \
    LZ4_CFLAGS="-I$DEPS/include" LZ4_LIBS="-L$DEPS/lib -llz4" \
    ZSTD_CFLAGS="-I$DEPS/include" ZSTD_LIBS="-L$DEPS/lib -lzstd" \
    ./configure "${PG_CONFIGURE[@]}" \
      --with-includes="$DEPS/include" --with-libraries="$DEPS/lib" >"$B/pg-configure.log" 2>&1 \
    || { tail -50 "$B/pg-configure.log"; config_log_tail "$d"; exit 1; })
  log "make world-bin (-j$JOBS)"
  (cd "$d" && make -j"$JOBS" world-bin >"$B/pg-make.log" 2>&1) || { tail -80 "$B/pg-make.log"; exit 1; }
  rm -rf "$DESTDIR_ROOT"
  (cd "$d" && make install-world-bin DESTDIR="$DESTDIR_ROOT" >"$B/pg-install.log" 2>&1) \
    || { tail -40 "$B/pg-install.log"; exit 1; }
  rm -f "$STAMPS/pg_clickhouse-"*  # the extension must be reinstalled into a fresh stage
  mark "$s"
}
config_log_tail() { [ -f "$1/config.log" ] && tail -60 "$1/config.log" >&2 || true; }

# --------------------------------------------------------- pg_clickhouse ----
build_pg_clickhouse() {
  local s="pg_clickhouse-$PGCH_VERSION"; done_p "$s" && return
  log "building $s"
  local d; d="$(unpack "$PGCH_URL" "$PGCH_SHA256" "$s")"
  # The release zip ships the vendored submodules but no .gitmodules; give the
  # Makefile's submodule rule an old prerequisite so it never runs git.
  touch -t 200001010000 "$d/.gitmodules"
  # pg_clickhouse links `$(CURL_CONFIG) --libs`; with a static libcurl that must
  # be the static link line (curl + OpenSSL + system libs, in that order).
  local cc="$B/curl-config-static"
  cat >"$cc" <<EOF
#!/bin/sh
case "\$1" in
  --libs) exec "$DEPS/bin/curl-config" --static-libs ;;
  *)      exec "$DEPS/bin/curl-config" "\$@" ;;
esac
EOF
  chmod +x "$cc"
  local mk=(PG_CONFIG="$STAGE/bin/pg_config" CURL_CONFIG="$cc")
  (cd "$d" && make -j"$JOBS" "${mk[@]}" >"$B/pgch-make.log" 2>&1 && make "${mk[@]}" install >>"$B/pgch-make.log" 2>&1) \
    || { tail -60 "$B/pgch-make.log"; exit 1; }
  mark "$s"
}

# ------------------------------------------------------------- packaging ----
is_macho() { file -b "$1" | grep -q '^Mach-O'; }
is_elf()   { file -b "$1" | grep -q '^ELF'; }

# Relative path from directory $1 to bundle lib/ (both inside $PKG).
rel_to_lib() {
  case "${1#"$PKG"/}" in
    bin) echo ../lib ;;
    lib) echo . ;;
    lib/postgresql) echo .. ;;
    *) die "unexpected binary dir $1" ;;
  esac
}

fix_macho() {
  local f="$1" dir rel changed=0 dep base
  dir="$(dirname "$f")"; rel="$(rel_to_lib "$dir")"
  strip -x "$f" 2>/dev/null || true
  if [ "$(dirname "$f")" = "$PKG/lib" ] && file -b "$f" | grep -q 'dynamically linked shared library'; then
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
  if otool -L "$f" | tail -n +2 | grep -q '@rpath/'; then
    local want="@loader_path/$rel"; [ "$rel" = . ] && want="@loader_path"
    otool -l "$f" | awk '/cmd LC_RPATH/{getline; getline; print $2}' | grep -qx "$want" \
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
  # load time. Make sure pg_clickhouse resolved its third-party symbols.
  local so="$PKG/lib/postgresql/pg_clickhouse.so" bad
  bad="$(nm -D --undefined-only "$so" | awk '{print $2}' \
        | grep -E '^(SSL_|OPENSSL_|EVP_|ERR_|X509_|BIO_|curl_|Curl_|LZ4_|ZSTD_|uuid_)' || true)"
  [ -z "$bad" ] || die "pg_clickhouse.so has unresolved bundled-library symbols: $(echo "$bad" | head -5 | tr '\n' ' ')"
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

  # Licences of everything statically linked into the bundle.
  local lic="$PKG/share/licenses"; mkdir -p "$lic"
  cp "$B/src/postgresql-$PG_VERSION"/*/COPYRIGHT "$lic/postgresql.txt"
  cp "$B/src/pg_clickhouse-$PGCH_VERSION"/*/LICENSE.md "$lic/pg_clickhouse.md"
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

  local f
  while IFS= read -r -d '' f; do
    [ -L "$f" ] && continue
    if [ "$OS" = Darwin ]; then is_macho "$f" && fix_macho "$f"
    else is_elf "$f" && fix_elf "$f"; fi
  done < <(find "$PKG/bin" "$PKG/lib" -maxdepth 2 -type f -print0)
  [ "$OS" = Linux ] && check_elf_undefined

  local commit repo dirty="" deps_json
  commit="${PGB_COMMIT:-$(git -C "$ROOT" rev-parse HEAD 2>/dev/null || echo unknown)}"
  if [ -z "${PGB_COMMIT:-}" ] && [ -n "$(git -C "$ROOT" status --porcelain --untracked-files=no 2>/dev/null)" ]; then
    dirty=", \"dirty\": true"
  fi
  repo="${PGB_REPO:-${GITHUB_REPOSITORY:-sdairs/pg-bundles}}"
  deps_json="\"openssl\": \"$OPENSSL_VERSION\", \"curl\": \"$CURL_VERSION\", \"lz4\": \"$LZ4_VERSION\", \"zstd\": \"$ZSTD_VERSION\""
  local platform_json
  if [ "$OS" = Linux ]; then
    deps_json="$deps_json, \"zlib\": \"$ZLIB_VERSION\", \"libedit\": \"$LIBEDIT_VERSION\", \"ncurses\": \"$NCURSES_VERSION\", \"libuuid\": \"util-linux $UTIL_LINUX_VERSION\""
    platform_json="\"min_glibc\": \"$(ldd --version | head -1 | awk '{print $NF}')\""
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
  if tar --version 2>/dev/null | grep -q 'GNU tar'; then
    tar -C "$PKG_ROOT" --owner=0 --group=0 --numeric-owner --sort=name -cf - "$NAME" | gzip -9n >"$tgz"
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
