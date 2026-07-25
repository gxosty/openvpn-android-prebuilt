#!/usr/bin/env bash
#
# Resolves the "floating" parts of versions.env to concrete versions and prints
# them as shell assignments. Used by both the builder and the upstream poller so
# the two can never disagree about what a build key means.
#
#   eval "$(scripts/resolve-versions.sh)"
#
# Requires curl. GH_TOKEN / GITHUB_TOKEN is used when present to avoid the 60
# req/h unauthenticated rate limit.

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/versions.env"

gh_api() {
    local url="$1"
    local -a auth=()
    local token="${GH_TOKEN:-${GITHUB_TOKEN:-}}"
    [ -n "$token" ] && auth=(-H "Authorization: Bearer $token")
    curl -fsSL --retry 3 --retry-delay 2 \
        -H "Accept: application/vnd.github+json" \
        -H "X-GitHub-Api-Version: 2022-11-28" \
        "${auth[@]}" "$url"
}

# Sort a list of dotted versions, newest last.
version_sort() { sort -t. -k1,1n -k2,2n -k3,3n; }

# --- OpenSSL -----------------------------------------------------------------
# OPENSSL_LINE may be a full version (3.5.7 -> used as-is) or a line (3.5 ->
# resolved to the newest patch release on that line).
resolve_openssl() {
    if [[ "$OPENSSL_LINE" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
        printf '%s' "$OPENSSL_LINE"
        return
    fi

    local newest
    newest="$(gh_api 'https://api.github.com/repos/openssl/openssl/releases?per_page=100' \
        | grep -o '"tag_name": *"openssl-[0-9][^"]*"' \
        | sed 's/.*"openssl-\(.*\)"/\1/' \
        | grep -E "^${OPENSSL_LINE//./\\.}\.[0-9]+$" \
        | version_sort | tail -n1)"

    [ -n "$newest" ] || { echo "could not resolve newest OpenSSL on line $OPENSSL_LINE" >&2; exit 1; }
    printf '%s' "$newest"
}

# --- OpenVPN -----------------------------------------------------------------
# Newest stable release on the highest X.Y line. Deliberately not GitHub's
# "latest" pointer: OpenVPN publishes 2.6.x and 2.7.x on the same day, so
# "latest" can point back at the older line.
resolve_openvpn() {
    local tags line newest
    tags="$(gh_api 'https://api.github.com/repos/OpenVPN/openvpn/releases?per_page=100' \
        | python3 -c '
import json, sys, re
rels = json.load(sys.stdin)
out = []
for r in rels:
    if r.get("draft") or r.get("prerelease"):
        continue
    m = re.fullmatch(r"v(\d+)\.(\d+)\.(\d+)", r["tag_name"])
    if m:
        out.append(tuple(int(x) for x in m.groups()))
for major, minor, patch in sorted(out):
    print(f"{major}.{minor}.{patch}")
')"
    [ -n "$tags" ] || { echo "no stable OpenVPN releases found" >&2; exit 1; }

    line="$(printf '%s\n' "$tags" | sed 's/\.[0-9]*$//' | version_sort | tail -n1)"
    newest="$(printf '%s\n' "$tags" | grep -E "^${line//./\\.}\.[0-9]+$" | version_sort | tail -n1)"
    printf 'v%s' "$newest"
}

OPENSSL_VERSION="$(resolve_openssl)"

if [ "${RESOLVE_OPENVPN:-1}" = "1" ]; then
    OPENVPN_TAG="${OPENVPN_TAG_OVERRIDE:-$(resolve_openvpn)}"
fi

# The build key: everything that affects the produced binaries. When it changes,
# a new release is warranted even if the OpenVPN version itself did not move.
BUILD_KEY="openvpn=${OPENVPN_TAG};openssl=${OPENSSL_VERSION};lzo=${LZO_VERSION};lz4=${LZ4_VERSION};ndk=${NDK_VERSION};api=${API_LEVEL}"

# Emitted as exports so that `eval "$(scripts/resolve-versions.sh)"` makes these
# visible to build-deps.sh / build-openvpn.sh / package.sh, which run as child
# processes and would otherwise see none of them.
cat <<EOF
export OPENVPN_TAG='${OPENVPN_TAG}'
export OPENVPN_VERSION='${OPENVPN_TAG#v}'
export OPENSSL_VERSION='${OPENSSL_VERSION}'
export LZO_VERSION='${LZO_VERSION}'
export LZ4_VERSION='${LZ4_VERSION}'
export NDK_VERSION='${NDK_VERSION}'
export API_LEVEL='${API_LEVEL}'
export ABIS='${ABIS}'
export BUILD_KEY='${BUILD_KEY}'
EOF
