#!/usr/bin/env bash
#
# Turns the raw build outputs for one ABI into the published release assets.
#
# Per dependency mode (static / shared):
#   libopenvpn-<abi>-<mode>-deps.a      static library
#   libopenvpn-<abi>-<mode>-deps.so     shared library
#   libopenvpnexec-<abi>-<mode>-deps.so PIE executable
#
# Plus, once per ABI, the dependencies themselves in both forms, a drop-in
# tarball per mode, and build-info.json describing exactly what was linked.
#
# Usage: package.sh <abi>

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/common.sh"

ABI="${1:?usage: package.sh <abi>}"
: "${OPENVPN_TAG:?OPENVPN_TAG not set}"
: "${OPENSSL_VERSION:?OPENSSL_VERSION not set}"

require_cmds tar sha256sum python3

TOOLCHAIN_BIN="$(ndk_toolchain_bin)"
AR="$TOOLCHAIN_BIN/llvm-ar"
NM="$TOOLCHAIN_BIN/llvm-nm"
OBJCOPY="$TOOLCHAIN_BIN/llvm-objcopy"
STRIP="$TOOLCHAIN_BIN/llvm-strip"
READELF="$TOOLCHAIN_BIN/llvm-readelf"

OPENVPN_VERSION="${OPENVPN_TAG#v}"
STAGE_FULL="$DEPS_ROOT/$ABI/stage-full"
DIST="$OUT_DIR/dist"
mkdir -p "$DIST"

DEP_LIBS=(libcrypto libssl liblzo2 liblz4)

# --- helpers ---------------------------------------------------------------

sha256_of() { sha256sum "$1" | cut -d' ' -f1; }

# DT_NEEDED entries of an ELF file, as a JSON array.
needed_json() {
    "$READELF" -d "$1" 2>/dev/null \
        | sed -n 's/.*Shared library: \[\(.*\)\].*/\1/p' \
        | python3 -c 'import json,sys; print(json.dumps([l.strip() for l in sys.stdin if l.strip()]))'
}

# Members of a static archive that came from a bundled dependency, as JSON.
bundled_json() {
    local mode="$1"
    if [ "$mode" = "static" ]; then
        printf '["libcrypto.a","libssl.a","liblzo2.a","liblz4.a"]'
    else
        printf '[]'
    fi
}

artifacts_json=()

record_artifact() {
    local path="$1" kind="$2" mode="$3" needed="$4" bundled="$5"
    local name size sha
    name="$(basename "$path")"
    size="$(wc -c < "$path" | tr -d '[:space:]')"
    sha="$(sha256_of "$path")"
    artifacts_json+=("$(python3 -c '
import json, sys
name, kind, mode, size, sha, needed, bundled = sys.argv[1:8]
print(json.dumps({
    "name": name, "kind": kind, "deps": mode,
    "size": int(size), "sha256": sha,
    "needed": json.loads(needed), "bundled": json.loads(bundled),
}))' "$name" "$kind" "$mode" "$size" "$sha" "$needed" "$bundled")")
}

# --- OpenVPN artifacts -----------------------------------------------------

for MODE in static shared; do
    RAW="$OUT_DIR/raw/$ABI/$MODE"
    [ -d "$RAW" ] || die "no raw output at $RAW -- run build-openvpn.sh $ABI $MODE first"

    suffix="$ABI-$MODE-deps"
    work="$BUILD_ROOT/package-$ABI-$MODE"
    rm -rf "$work"; mkdir -p "$work"

    # --- static library ---
    #
    # openvpn.c defines both openvpn_main() and main(). Pulling the archive
    # member in for openvpn_main() would therefore also drag main() in and
    # collide with the consumer's own main(). Demoting main() to a local symbol
    # keeps the archive usable from an executable that has its own entry point.
    cp "$RAW/libopenvpn.a" "$work/libopenvpn.a"
    "$OBJCOPY" --localize-symbol=main "$work/libopenvpn.a"

    if [ "$MODE" = "static" ]; then
        # Fat archive: merge the dependencies in so the result links standalone.
        log "merging dependencies into libopenvpn-$suffix.a"
        "$AR" -M <<EOF
create $work/libopenvpn-fat.a
addlib $work/libopenvpn.a
addlib $STAGE_FULL/lib/libcrypto.a
addlib $STAGE_FULL/lib/libssl.a
addlib $STAGE_FULL/lib/liblzo2.a
addlib $STAGE_FULL/lib/liblz4.a
save
end
EOF
        mv "$work/libopenvpn-fat.a" "$DIST/libopenvpn-$suffix.a"
    else
        mv "$work/libopenvpn.a" "$DIST/libopenvpn-$suffix.a"
    fi

    # --- shared library and PIE executable ---
    cp "$RAW/libopenvpn.so" "$DIST/libopenvpn-$suffix.so"
    cp "$RAW/openvpn"       "$DIST/libopenvpnexec-$suffix.so"
    "$STRIP" --strip-unneeded "$DIST/libopenvpn-$suffix.so" "$DIST/libopenvpnexec-$suffix.so"

    record_artifact "$DIST/libopenvpn-$suffix.a"       static-library "$MODE" '[]' "$(bundled_json "$MODE")"
    record_artifact "$DIST/libopenvpn-$suffix.so"      shared-library "$MODE" "$(needed_json "$DIST/libopenvpn-$suffix.so")" "$(bundled_json "$MODE")"
    record_artifact "$DIST/libopenvpnexec-$suffix.so"  pie-executable "$MODE" "$(needed_json "$DIST/libopenvpnexec-$suffix.so")" "$(bundled_json "$MODE")"
done

# --- dependency libraries --------------------------------------------------

for lib in "${DEP_LIBS[@]}"; do
    cp "$STAGE_FULL/lib/$lib.a"  "$DIST/$lib-$ABI.a"
    cp "$STAGE_FULL/lib/$lib.so" "$DIST/$lib-$ABI.so"
    "$STRIP" --strip-unneeded "$DIST/$lib-$ABI.so"
    record_artifact "$DIST/$lib-$ABI.a"  dependency-static "-" '[]' '[]'
    record_artifact "$DIST/$lib-$ABI.so" dependency-shared "-" "$(needed_json "$DIST/$lib-$ABI.so")" '[]'
done

# --- drop-in tarballs ------------------------------------------------------

for MODE in static shared; do
    name="openvpn-$OPENVPN_VERSION-android$API_LEVEL-$ABI-$MODE-deps"
    root="$BUILD_ROOT/tar/$name"
    rm -rf "$root"
    mkdir -p "$root/jniLibs/$ABI" "$root/lib" "$root/include"

    cp "$DIST/libopenvpn-$ABI-$MODE-deps.so"     "$root/jniLibs/$ABI/libopenvpn.so"
    cp "$DIST/libopenvpnexec-$ABI-$MODE-deps.so" "$root/jniLibs/$ABI/libopenvpnexec.so"
    cp "$DIST/libopenvpn-$ABI-$MODE-deps.a"      "$root/lib/libopenvpn.a"

    if [ "$MODE" = "shared" ]; then
        for lib in "${DEP_LIBS[@]}"; do
            cp "$DIST/$lib-$ABI.so" "$root/jniLibs/$ABI/$lib.so"
        done
    fi

    cp "$REPO_ROOT/include/openvpn-lib.h" "$root/include/openvpn-lib.h"
    cp "$OUT_DIR/raw/$ABI/$MODE/config.h" "$root/include/openvpn-config.h"

    cat > "$root/BUILD-INFO.txt" <<EOF
OpenVPN prebuilt for Android
============================

OpenVPN      $OPENVPN_VERSION ($OPENVPN_TAG)
OpenSSL      $OPENSSL_VERSION
LZO          $LZO_VERSION
LZ4          $LZ4_VERSION
NDK          $(ndk_revision) (requested $NDK_VERSION)
Min API      $API_LEVEL
ABI          $ABI
Dependencies linked $MODE

Contents
--------
  jniLibs/$ABI/libopenvpn.so       shared library, exports openvpn_main()
  jniLibs/$ABI/libopenvpnexec.so   PIE executable -- spawn it, do not link it
$( [ "$MODE" = "shared" ] && printf '  jniLibs/%s/lib{crypto,ssl,lzo2,lz4}.so  dependencies, required at runtime\n' "$ABI" )
  lib/libopenvpn.a                 static library$( [ "$MODE" = "static" ] && printf ' (dependencies merged in)' )
  include/openvpn-lib.h            declares openvpn_main()
  include/openvpn-config.h         the config.h this build was compiled with

Usage
-----
  Copy jniLibs/ into src/main/ of your Android module -- the filenames inside
  are already the ones Android requires. Then either link libopenvpn.so from
  your JNI code and call openvpn_main(), or spawn libopenvpnexec.so as a child
  process and drive it over the OpenVPN management interface.

  Do NOT rename the files inside jniLibs/: Android only extracts entries
  matching lib*.so, and it matches on the exact name.

Not compiled in: PKCS#11, DCO, OpenSSL legacy provider (BF-CBC, DES, RC4,
CAST5), engine support, --dns-updown.

OpenVPN is licensed under the GNU GPL version 2 with an OpenSSL linking
exception. Sources: https://github.com/OpenVPN/openvpn/tree/$OPENVPN_TAG
EOF

    tar -czf "$DIST/$name.tar.gz" -C "$BUILD_ROOT/tar" "$name"
    record_artifact "$DIST/$name.tar.gz" bundle "$MODE" '[]' '[]'
done

# --- build-info.json -------------------------------------------------------

CLANG_VERSION="$("$TOOLCHAIN_BIN/clang" --version | head -n1)"
OPENVPN_COMMIT="$(sed -n 's/^OPENVPN_COMMIT=//p' "$OUT_DIR/raw/$ABI/static/.buildmeta")"

mkdir -p "$OUT_DIR/build-info"
{
    printf '{\n'
    printf '  "abi": "%s",\n' "$ABI"
    printf '  "openvpn": {"tag": "%s", "version": "%s", "commit": "%s"},\n' \
        "$OPENVPN_TAG" "$OPENVPN_VERSION" "$OPENVPN_COMMIT"
    printf '  "openssl": "%s",\n' "$OPENSSL_VERSION"
    printf '  "lzo": "%s",\n' "$LZO_VERSION"
    printf '  "lz4": "%s",\n' "$LZ4_VERSION"
    printf '  "ndk": "%s",\n' "$(ndk_revision)"
    printf '  "ndk_requested": "%s",\n' "$NDK_VERSION"
    printf '  "clang": "%s",\n' "$CLANG_VERSION"
    printf '  "api_level": %s,\n' "$API_LEVEL"
    printf '  "build_key": "%s",\n' "${BUILD_KEY:-}"
    printf '  "artifacts": [\n'
    for i in "${!artifacts_json[@]}"; do
        printf '    %s' "${artifacts_json[$i]}"
        # if/then, not `&& printf` -- under `set -e` a false test as the final
        # command of the list would abort the script on the last element.
        if [ "$i" -lt $(( ${#artifacts_json[@]} - 1 )) ]; then printf ','; fi
        printf '\n'
    done
    printf '  ]\n'
    printf '}\n'
} > "$OUT_DIR/build-info/$ABI.json"

python3 -c 'import json,sys; json.load(open(sys.argv[1]))' "$OUT_DIR/build-info/$ABI.json" \
    || die "generated build-info/$ABI.json is not valid JSON"

log "packaged $ABI -> $DIST (${#artifacts_json[@]} artifacts)"
