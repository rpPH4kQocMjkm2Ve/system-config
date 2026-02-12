#!/usr/bin/env bash
# hardened_malloc version: 2026020600
set -euo pipefail

TAG="2026020600"
SRC="/tmp/hardened_malloc_build"
DEST="${CHEZMOI_SOURCE_DIR}/usr/local/lib"

mkdir -p "$DEST"

if [[ -f "${DEST}/.hardened_malloc.tag" ]] && \
   [[ "$(cat "${DEST}/.hardened_malloc.tag")" == "$TAG" ]]; then
    echo "hardened_malloc ${TAG} already built"
    exit 0
fi

rm -rf "$SRC"
git clone --depth 1 --branch "$TAG" \
    https://github.com/GrapheneOS/hardened_malloc.git "$SRC"
cd "$SRC"

echo "Building default variant..."
make -j"$(nproc)"

echo "Building light variant..."
make -j"$(nproc)" VARIANT=light

install -m 644 out/libhardened_malloc.so "${DEST}/libhardened_malloc.so"
install -m 644 out-light/libhardened_malloc-light.so "${DEST}/libhardened_malloc-light.so"

echo "$TAG" > "${DEST}/.hardened_malloc.tag"

rm -rf "$SRC"

echo "Built hardened_malloc ${TAG} into source dir"
echo "Run 'sudo chezmoi apply' to deploy"
