#!/usr/bin/env bash
#
# Cross-compiles OpenVPN's dependencies for one Android ABI:
#
#   OpenSSL  (static + shared)
#   LZO      (static + shared)
#   LZ4      (static + shared)
#
# Everything is installed into a single "full" prefix, which is then split into
# two prefixes containing only the static or only the shared form. The split is
# what makes the dep-mode unambiguous later: CMake's find_package(OpenSSL) and
# pkg-config both prefer shared libraries when both are present, and there is no
# reliable way to tell pkg-config otherwise.
#
# Usage: build-deps.sh <abi>
# Requires: ANDROID_NDK_ROOT, OPENSSL_VERSION (see resolve-versions.sh)

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/common.sh"

ABI="${1:?usage: build-deps.sh <abi>}"
: "${OPENSSL_VERSION:?OPENSSL_VERSION not set -- run: eval \"\$(scripts/resolve-versions.sh)\"}"

require_cmds curl cmake make tar perl

NDK="$(ndk_root)"
TOOLCHAIN_BIN="$(ndk_toolchain_bin)"
JOBS="$(nproc_or 4)"

ABI_DEPS="$DEPS_ROOT/$ABI"
STAGE_FULL="$ABI_DEPS/stage-full"
STAGE_STATIC="$ABI_DEPS/stage-static"
STAGE_SHARED="$ABI_DEPS/stage-shared"
STAMP="$ABI_DEPS/.stamp-${OPENSSL_VERSION}-${LZO_VERSION}-${LZ4_VERSION}-api${API_LEVEL}-$(ndk_revision)"

if [ -f "$STAMP" ] && [ "${FORCE_DEPS:-0}" != "1" ]; then
    log "deps for $ABI already built ($(basename "$STAMP")) -- skipping"
    exit 0
fi

rm -rf "$ABI_DEPS"
mkdir -p "$STAGE_FULL" "$SRC_DIR"

log "building dependencies for $ABI (API $API_LEVEL, NDK $(ndk_revision))"

cmake_android_args=(
    "-DCMAKE_TOOLCHAIN_FILE=$NDK/build/cmake/android.toolchain.cmake"
    "-DANDROID_ABI=$ABI"
    "-DANDROID_PLATFORM=android-$API_LEVEL"
    "-DCMAKE_BUILD_TYPE=Release"
    "-DCMAKE_INSTALL_PREFIX=$STAGE_FULL"
    "-DCMAKE_INSTALL_LIBDIR=lib"
    # CMake 4 removed compatibility with cmake_minimum_required(<3.5); LZO 2.10
    # and LZ4 1.10 both predate that. This is the documented escape hatch.
    "-DCMAKE_POLICY_VERSION_MINIMUM=3.5"
)

# ---------------------------------------------------------------------------
# OpenSSL
# ---------------------------------------------------------------------------
#
# Configured deliberately lean:
#   no-engine  -- OpenVPN's CMake build hard-disables HAVE_OPENSSL_ENGINE
#                 (config.h.cmake.in has a plain "#undef"), so engine support
#                 could not be reached anyway.
#   no-module  -- no dynamically loaded providers; nothing to ship alongside and
#                 no OPENSSL_MODULES path to configure on device.
#   no-legacy  -- follows from no-module. Legacy algorithms (BF-CBC, DES, RC4,
#                 CAST5) are therefore NOT available. Modern OpenVPN configs do
#                 not use them; documented in README.md and the release notes.
#   no-apps/docs/tests -- not shipped, halves the build time.
#
# Note: shared is left enabled, which also makes the static objects PIC, which
# consumers need in order to link libopenvpn.a into their own .so.

build_openssl() {
    local tarball="$SRC_DIR/openssl-$OPENSSL_VERSION.tar.gz"
    local src="$SRC_DIR/openssl-$OPENSSL_VERSION"

    fetch "https://github.com/openssl/openssl/releases/download/openssl-$OPENSSL_VERSION/openssl-$OPENSSL_VERSION.tar.gz" "$tarball"
    rm -rf "$src"
    tar -xzf "$tarball" -C "$SRC_DIR"

    local build="$BUILD_ROOT/openssl-$ABI"
    rm -rf "$build"; mkdir -p "$build"

    log "configuring OpenSSL $OPENSSL_VERSION for $ABI"
    (
        cd "$build"
        export ANDROID_NDK_ROOT="$NDK"
        export PATH="$TOOLCHAIN_BIN:$PATH"
        "$src/Configure" "$(abi_openssl_target "$ABI")" \
            "-D__ANDROID_API__=$API_LEVEL" \
            --prefix="$STAGE_FULL" \
            --libdir=lib \
            --openssldir=/etc/ssl \
            no-tests no-apps no-docs \
            no-engine no-module no-legacy
        make -j"$JOBS"
        make install_sw
    )
}

# ---------------------------------------------------------------------------
# LZO
# ---------------------------------------------------------------------------
#
# -fno-strict-aliasing is not optional: LZO's own build system passes it, and
# the library type-puns aggressively enough that optimised builds miscompile
# without it (this is the same class of problem ics-openvpn worked around by
# dropping armeabi-v7a to -O0).

build_lzo() {
    local tarball="$SRC_DIR/lzo-$LZO_VERSION.tar.gz"
    local src="$SRC_DIR/lzo-$LZO_VERSION"

    fetch "https://www.oberhumer.com/opensource/lzo/download/lzo-$LZO_VERSION.tar.gz" "$tarball"
    rm -rf "$src"
    tar -xzf "$tarball" -C "$SRC_DIR"

    local build="$BUILD_ROOT/lzo-$ABI"
    rm -rf "$build"

    log "building LZO $LZO_VERSION for $ABI"
    cmake -S "$src" -B "$build" "${cmake_android_args[@]}" \
        -DENABLE_STATIC=ON \
        -DENABLE_SHARED=ON \
        -DCMAKE_C_FLAGS="-fno-strict-aliasing"
    cmake --build "$build" -j"$JOBS"
    cmake --install "$build"

    # LZO installs its example programs and docs; they are Android binaries that
    # nothing will ever run, and they would otherwise end up in the tarballs.
    rm -rf "$STAGE_FULL/libexec" "$STAGE_FULL/share/doc"

    # LZO's lzo2.pc advertises "-I${includedir}/lzo", but OpenVPN includes
    # <lzo/lzo1x.h>, so the parent directory has to be on the include path too.
    local pc="$STAGE_FULL/lib/pkgconfig/lzo2.pc"
    [ -f "$pc" ] || die "LZO did not install lzo2.pc (pkg-config missing at configure time?)"
    sed -i.bak 's|^Cflags:.*|Cflags: -I${includedir} -I${includedir}/lzo|' "$pc"
    rm -f "$pc.bak"
}

# ---------------------------------------------------------------------------
# LZ4
# ---------------------------------------------------------------------------

build_lz4() {
    local tarball="$SRC_DIR/lz4-$LZ4_VERSION.tar.gz"
    local src="$SRC_DIR/lz4-$LZ4_VERSION"

    fetch "https://github.com/lz4/lz4/archive/refs/tags/v$LZ4_VERSION.tar.gz" "$tarball"
    rm -rf "$src"
    tar -xzf "$tarball" -C "$SRC_DIR"

    local build="$BUILD_ROOT/lz4-$ABI"
    rm -rf "$build"

    log "building LZ4 $LZ4_VERSION for $ABI"
    cmake -S "$src/build/cmake" -B "$build" "${cmake_android_args[@]}" \
        -DBUILD_SHARED_LIBS=ON \
        -DBUILD_STATIC_LIBS=ON \
        -DLZ4_BUILD_CLI=OFF \
        -DLZ4_BUILD_LEGACY_LZ4C=OFF \
        -DLZ4_POSITION_INDEPENDENT_LIB=ON
    cmake --build "$build" -j"$JOBS"
    cmake --install "$build"
}

# ---------------------------------------------------------------------------
# Split the full prefix into static-only and shared-only prefixes
# ---------------------------------------------------------------------------

split_stage() {
    local mode="$1" dst="$2"
    log "assembling $mode prefix: $dst"

    rm -rf "$dst"
    mkdir -p "$dst/lib/pkgconfig"
    cp -a "$STAGE_FULL/include" "$dst/include"

    case "$mode" in
        static) cp -a "$STAGE_FULL"/lib/*.a  "$dst/lib/" ;;
        shared) cp -a "$STAGE_FULL"/lib/*.so "$dst/lib/" ;;
        *) die "split_stage: bad mode $mode" ;;
    esac

    # Rewrite the baked-in prefix so pkg-config points at the split tree.
    local pc
    for pc in "$STAGE_FULL"/lib/pkgconfig/*.pc; do
        [ -e "$pc" ] || continue
        sed "s|$STAGE_FULL|$dst|g" "$pc" > "$dst/lib/pkgconfig/$(basename "$pc")"
    done
}

# ---------------------------------------------------------------------------

build_openssl
build_lzo
build_lz4

for lib in libcrypto libssl liblzo2 liblz4; do
    [ -f "$STAGE_FULL/lib/$lib.a"  ] || die "$lib.a was not built"
    [ -f "$STAGE_FULL/lib/$lib.so" ] || die "$lib.so was not built"
done

split_stage static "$STAGE_STATIC"
split_stage shared "$STAGE_SHARED"

touch "$STAMP"
log "dependencies for $ABI ready"
