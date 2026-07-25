#!/usr/bin/env bash
#
# Builds OpenVPN for one ABI in one dependency mode, producing three artifacts:
#
#   libopenvpn.a    static library   (target openvpn_static, added by the overlay)
#   libopenvpn.so   shared library   (target openvpn_shared, added by the overlay)
#   openvpn         PIE executable   (upstream's own target)
#
# Usage: build-openvpn.sh <abi> <static|shared>
#          ^ the second argument is how the *dependencies* are linked, not how
#            OpenVPN itself is linked -- all three OpenVPN forms are always built.
#
# Requires: ANDROID_NDK_ROOT, OPENVPN_TAG (see resolve-versions.sh), and
#           build-deps.sh already run for this ABI.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/common.sh"

ABI="${1:?usage: build-openvpn.sh <abi> <static|shared>}"
DEPMODE="${2:?usage: build-openvpn.sh <abi> <static|shared>}"
: "${OPENVPN_TAG:?OPENVPN_TAG not set -- run: eval \"\$(scripts/resolve-versions.sh)\"}"

case "$DEPMODE" in static|shared) ;; *) die "dep mode must be 'static' or 'shared', got '$DEPMODE'" ;; esac

require_cmds git cmake pkg-config python3

NDK="$(ndk_root)"
JOBS="$(nproc_or 4)"
STAGE="$DEPS_ROOT/$ABI/stage-$DEPMODE"
[ -d "$STAGE/lib" ] || die "no dependency prefix at $STAGE -- run build-deps.sh $ABI first"

# ---------------------------------------------------------------------------
# Source tree: cloned once, shared by every (abi, depmode) build. The overlay is
# appended in place and guarded by a marker so repeat runs cannot stack it.
# ---------------------------------------------------------------------------

OVPN_SRC="$SRC_DIR/openvpn-$OPENVPN_TAG"
OVERLAY_MARKER="# --- openvpn-android-prebuilt overlay applied ---"

prepare_source() {
    if [ ! -d "$OVPN_SRC/.git" ]; then
        log "cloning OpenVPN $OPENVPN_TAG"
        rm -rf "$OVPN_SRC"
        mkdir -p "$SRC_DIR"
        git clone --depth 1 --branch "$OPENVPN_TAG" \
            https://github.com/OpenVPN/openvpn.git "$OVPN_SRC"
    fi

    if grep -qF "$OVERLAY_MARKER" "$OVPN_SRC/CMakeLists.txt"; then
        log "overlay already applied"
        return
    fi

    log "appending CMake overlay to upstream CMakeLists.txt"
    {
        printf '\n%s\n' "$OVERLAY_MARKER"
        cat "$SCRIPT_DIR/cmake-overlay.cmake"
    } >> "$OVPN_SRC/CMakeLists.txt"
}

prepare_source

OPENVPN_COMMIT="$(git -C "$OVPN_SRC" rev-parse HEAD)"

# ---------------------------------------------------------------------------
# Configure + build
# ---------------------------------------------------------------------------

BUILD="$BUILD_ROOT/openvpn-$ABI-$DEPMODE"
rm -rf "$BUILD"

case "$DEPMODE" in
    static) openssl_static=TRUE ;;
    shared) openssl_static=FALSE ;;
esac

log "configuring OpenVPN $OPENVPN_TAG for $ABI ($DEPMODE deps)"

# PKG_CONFIG_LIBDIR (not PATH) so pkg-config sees *only* our cross-compiled
# prefix -- otherwise it happily hands back the host's liblz4/liblzo2.
# PKG_CONFIG_SYSROOT_DIR must be empty: the .pc files already carry absolute
# paths into the staging prefix.
PKG_CONFIG_LIBDIR="$STAGE/lib/pkgconfig" \
PKG_CONFIG_SYSROOT_DIR="" \
cmake -S "$OVPN_SRC" -B "$BUILD" \
    -DCMAKE_TOOLCHAIN_FILE="$NDK/build/cmake/android.toolchain.cmake" \
    -DANDROID_ABI="$ABI" \
    -DANDROID_PLATFORM="android-$API_LEVEL" \
    -DCMAKE_BUILD_TYPE=Release \
    -DUNSUPPORTED_BUILDS=ON \
    -DUSE_WERROR=OFF \
    -DBUILD_TESTING=OFF \
    -DENABLE_LZO=ON \
    -DENABLE_LZ4=ON \
    -DENABLE_PKCS11=OFF \
    -DENABLE_DNS_UPDOWN_BY_DEFAULT=OFF \
    -DDNS_UPDOWN_PATH=/not/supported/on/android \
    -DPLUGIN_DIR=/not/supported/on/android \
    -DOPENSSL_ROOT_DIR="$STAGE" \
    -DOPENSSL_USE_STATIC_LIBS="$openssl_static" \
    -DPython3_EXECUTABLE="$(command -v python3)"

log "building openvpn_static, openvpn_shared and the PIE executable"
cmake --build "$BUILD" -j"$JOBS" --target openvpn_static openvpn_shared openvpn

# ---------------------------------------------------------------------------
# Collect
# ---------------------------------------------------------------------------

RAW="$OUT_DIR/raw/$ABI/$DEPMODE"
rm -rf "$RAW"; mkdir -p "$RAW"

for f in libopenvpn.a libopenvpn.so openvpn; do
    [ -f "$BUILD/$f" ] || die "expected build output $BUILD/$f is missing"
    cp "$BUILD/$f" "$RAW/$f"
done

# config.h is generated per configuration; ship the one from the static-deps
# build so consumers can see exactly which features were compiled in.
cp "$BUILD/config.h" "$RAW/config.h"

cat > "$RAW/.buildmeta" <<EOF
OPENVPN_TAG=$OPENVPN_TAG
OPENVPN_COMMIT=$OPENVPN_COMMIT
ABI=$ABI
DEPMODE=$DEPMODE
EOF

log "built $ABI/$DEPMODE -> $RAW"
