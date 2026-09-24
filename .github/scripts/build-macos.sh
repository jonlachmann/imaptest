#!/usr/bin/env bash
# Build Dovecot + imaptest on macOS (Homebrew), producing a portable,
# statically-linked (3rd-party) arm64 binary. Works locally and in CI.
#
# Usage: build-macos.sh <dovecot_src_dir> <imaptest_src_dir>
#
#   <dovecot_src_dir>  a checkout of github.com/dovecot/core (main)  [source, unbuilt]
#   <imaptest_src_dir> a checkout of github.com/dovecot/imaptest
#
# Notes:
#   * imaptest links Dovecot's internal libraries, so Dovecot must be built first.
#   * On macOS, iconv lives outside libc; Dovecot's AM_ICONV misses this, so we
#     force -liconv when configuring Dovecot (else its test-charset link fails).
#   * The "portable" step re-links after making a static-only library search dir so
#     the linker picks the .a archives instead of the Homebrew .dylib files.
set -euo pipefail

CORE="${1:?usage: build-macos.sh <dovecot_src_dir> <imaptest_src_dir>}"
TEST="${2:?usage: build-macos.sh <dovecot_src_dir> <imaptest_src_dir>}"

jobs() { sysctl -n hw.ncpu 2>/dev/null || echo 4; }

# --- Homebrew paths (arch/keg-only agnostic: arm64=/opt/homebrew, Intel=/usr/local)
HB="$(brew --prefix)"
PREFIX() { brew --prefix "$1" 2>/dev/null || echo "/nonexistent-$1"; }
OPENSSL="$(PREFIX openssl@3)"
PCRE2="$(PREFIX pcre2)"
LZ4="$(PREFIX lz4)"
ZSTD="$(PREFIX zstd)"

# keg-only tooling: GNU libtool (g*) + modern bison/flex
export PATH="$HB/opt/libtool/libexec/gnubin:$HB/opt/bison/bin:$HB/opt/flex/bin:$PATH"

# let pkg-config + the compiler find keg-only OpenSSL / PCRE2 (Dovecot detects via pkg-config)
export PKG_CONFIG_PATH="$OPENSSL/lib/pkgconfig:$PCRE2/lib/pkgconfig:$LZ4/lib/pkgconfig:$ZSTD/lib/pkgconfig:$HB/lib/pkgconfig"
export CPPFLAGS="-I$OPENSSL/include -I$PCRE2/include -I$LZ4/include -I$ZSTD/include -I$HB/include"

echo "==== Step 1/3: build Dovecot libraries in: $CORE ===="
( cd "$CORE"
  autoreconf -vif
  # -liconv: iconv is outside libc on macOS.
  # i_cv_have_ssl_new_mem_funcs=yes: force the OpenSSL-3 "new mem functions"
  # code path. The autoconf probe for it can return a false "no", which makes
  # Dovecot use the legacy 1-arg signature that newer Clang rejects (and which
  # is an ABI mismatch against OpenSSL 3 anyway). Forcing it matches reality.
  env LIBS="-liconv" ./configure --with-ssl=openssl --disable-dependency-tracking \
      i_cv_have_ssl_new_mem_funcs=yes
  make -j"$(jobs)"
)

echo "==== Step 2/3: configure imaptest in: $TEST ===="
( cd "$TEST"
  ./autogen.sh
  ./configure --with-dovecot="$CORE"
)

echo "==== Step 3/3: build imaptest (statically linking 3rd-party libs) ===="
STATIC="$TEST/.build-static"
rm -rf "$STATIC"; mkdir -p "$STATIC"
echo "-- staging static archives (portable self-contained build) --"
for f in "$OPENSSL/lib/libssl.a" "$OPENSSL/lib/libcrypto.a" \
         "$PCRE2/lib/libpcre2-32.a" "$LZ4/lib/liblz4.a" "$ZSTD/lib/libzstd.a"; do
  if [ -f "$f" ]; then cp "$f" "$STATIC/"; echo "  static: $(basename "$f")"
  else echo "  MISSING (stays dynamic): $f"; fi
done
# override LDFLAGS so the linker searches the static-only dir first (no .dylib there).
( cd "$TEST"
  make clean >/dev/null 2>&1 || true
  make -j"$(jobs)" LDFLAGS="-L$STATIC"
)

echo "==== Portability check ===="
if otool -L "$TEST/src/imaptest" | grep -qE "/opt/homebrew|/usr/local"; then
  echo "WARN: still references Homebrew libs (not fully portable):"
  otool -L "$TEST/src/imaptest" | awk '{print $1}' | grep -E "/opt/homebrew|/usr/local" || true
else
  echo "OK: only /usr/lib system libs -> portable to any Mac of this CPU arch."
fi
echo "-- otool -L --"; otool -L "$TEST/src/imaptest"