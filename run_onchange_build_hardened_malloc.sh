#!/usr/bin/env bash
# build: hardened_malloc=2026020600 fake_rlimit=2
set -euo pipefail

TAG="2026020600"
FAKE_RLIMIT_VER="2"
BUILD_TAG="${TAG}-fakerl${FAKE_RLIMIT_VER}"
SRC="/tmp/hardened_malloc_build"
DEST="${CHEZMOI_SOURCE_DIR}/usr/local/lib"

mkdir -p "$DEST"

if [[ -f "${DEST}/.hardened_malloc.tag" ]] && \
   [[ "$(cat "${DEST}/.hardened_malloc.tag")" == "$BUILD_TAG" ]]; then
    echo "hardened_malloc ${BUILD_TAG} already built"
    # Still ensure ld.so.preload is correct
    cat > /etc/ld.so.preload << 'PRELOAD'
/usr/local/lib/libfake_rlimit.so
/usr/local/lib/libhardened_malloc-light.so
PRELOAD
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

rm -rf "$SRC"

echo "Built hardened_malloc ${TAG}"

# ── Build fake_rlimit for glycin/RLIMIT_AS compatibility ──────────
cat > /tmp/fake_rlimit.c << 'EOF'
#define _GNU_SOURCE
#include <stddef.h>
#include <dlfcn.h>
#include <unistd.h>
#include <sys/resource.h>
#include <sys/syscall.h>

int prlimit64(__pid_t pid, enum __rlimit_resource resource,
              const struct rlimit64 *new_limit, struct rlimit64 *old_limit) {
    if (resource == RLIMIT_AS && new_limit != NULL) {
        if (old_limit) {
            return syscall(SYS_prlimit64, pid, resource, NULL, old_limit);
        }
        return 0;
    }
    return syscall(SYS_prlimit64, pid, resource, new_limit, old_limit);
}

int setrlimit(__rlimit_resource_t resource, const struct rlimit *rlim) {
    if (resource == RLIMIT_AS)
        return 0;
    static int (*real_setrlimit)(__rlimit_resource_t, const struct rlimit *) = NULL;
    if (!real_setrlimit)
        real_setrlimit = dlsym(RTLD_NEXT, "setrlimit");
    return real_setrlimit(resource, rlim);
}
EOF

gcc -shared -fPIC -O2 -o /tmp/libfake_rlimit.so /tmp/fake_rlimit.c -ldl
install -m 644 /tmp/libfake_rlimit.so "${DEST}/libfake_rlimit.so"
rm -f /tmp/fake_rlimit.c /tmp/libfake_rlimit.so

echo "Built libfake_rlimit.so"

# ── Write tag after everything succeeds ───────────────────────────
echo "$BUILD_TAG" > "${DEST}/.hardened_malloc.tag"

# ── Deploy ld.so.preload ──────────────────────────────────────────
cat > /etc/ld.so.preload << 'PRELOAD'
/usr/local/lib/libfake_rlimit.so
/usr/local/lib/libhardened_malloc-light.so
PRELOAD

echo "Updated /etc/ld.so.preload"
echo "Run 'sudo chezmoi apply' again to deploy libraries"
