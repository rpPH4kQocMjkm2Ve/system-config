#!/bin/bash
# /usr/local/lib/atomic/common.sh
#
# Shared functions and configuration for the atomic-upgrade system.
# Sourced by: atomic-upgrade, atomic-gc

# ── Defaults (overridable via /etc/atomic.conf) ─────────────────────

BTRFS_MOUNT="/mnt/temp_root"
NEW_ROOT="/mnt/newroot"
ESP="/efi"
KEEP_GENERATIONS=3
MAPPER_NAME="root_crypt"
KERNEL_PKG="linux"
LOCK_FILE="/var/lock/atomic-upgrade.lock"
LOG_FILE="/var/log/atomic-upgrade.log"
# Kernel security parameters
KERNEL_PARAMS="rw slab_nomerge init_on_alloc=1 page_alloc.shuffle=1 pti=on vsyscall=none randomize_kstack_offset=on debugfs=off"

# ── Config loading (safe parser, no arbitrary code execution) ───────

CONFIG_FILE="/etc/atomic.conf"

load_config() {
    [[ -f "$CONFIG_FILE" ]] || return 0

    # Refuse to load config not owned by root
    local owner
    owner=$(stat -c %u "$CONFIG_FILE" 2>/dev/null)
    if [[ "$owner" != "0" ]]; then
        echo "ERROR: $CONFIG_FILE not owned by root (owner uid: $owner)" >&2
        return 1
    fi

    # Whitelist of allowed config keys
    local -a allowed=(BTRFS_MOUNT NEW_ROOT ESP KEEP_GENERATIONS MAPPER_NAME KERNEL_PARAMS KERNEL_PKG)

    while IFS='=' read -r key value; do
        # Strip whitespace
        key="${key// /}"

        # Skip comments and blank lines
        [[ "$key" =~ ^#.*$ || -z "$key" ]] && continue

        # Check against whitelist
        local valid=0
        for a in "${allowed[@]}"; do
            if [[ "$key" == "$a" ]]; then
                valid=1
                break
            fi
        done

        if [[ $valid -eq 1 ]]; then
            # Strip surrounding quotes (single or double)
            value="${value#\"}"
            value="${value%\"}"
            value="${value#\'}"
            value="${value%\'}"
            printf -v "$key" '%s' "$value"
        else
            echo "WARN: Unknown config key ignored: $key" >&2
        fi
    done < "$CONFIG_FILE"
}

load_config

# ── Validation ──────────────────────────────────────────────────────

validate_config() {
    [[ -d "$ESP" ]] || { echo "ERROR: ESP not found: $ESP" >&2; return 1; }
    [[ -e "/dev/mapper/${MAPPER_NAME}" ]] || { echo "ERROR: Mapper not found: $MAPPER_NAME" >&2; return 1; }
    [[ "$KEEP_GENERATIONS" =~ ^[0-9]+$ ]] || { echo "ERROR: Invalid KEEP_GENERATIONS" >&2; return 1; }
    [[ "$KEEP_GENERATIONS" -ge 1 ]] || { echo "ERROR: KEEP_GENERATIONS must be >= 1" >&2; return 1; }
    return 0
}

# ── Logging ─────────────────────────────────────────────────────────

log() {
    local level="${1:-INFO}"
    shift
    local msg="[$(date '+%Y-%m-%d %H:%M:%S')] [${level}] $*"
    echo "$msg" | tee -a "$LOG_FILE"
}

log_info()  { log "INFO" "$@"; }
log_error() { log "ERROR" "$@" >&2; }
log_warn()  { log "WARN" "$@"; }

# ── Dependency check ────────────────────────────────────────────────

check_dependencies() {
    local missing=()
    for cmd in btrfs ukify sbctl cryptsetup findmnt arch-chroot python3; do
        command -v "$cmd" >/dev/null || missing+=("$cmd")
    done
    if [[ ${#missing[@]} -gt 0 ]]; then
        echo "ERROR: Missing commands: ${missing[*]}" >&2
        return 1
    fi
    # Verify python helper modules exist
    for helper in /usr/local/lib/atomic/fstab.py /usr/local/lib/atomic/rootdev.py; do
        [[ -f "$helper" ]] || {
            echo "ERROR: Missing helper: $helper" >&2
            return 1
        }
    done
}

# ── Locking ─────────────────────────────────────────────────────────

acquire_lock() {
    local lock_dir
    lock_dir=$(dirname "$LOCK_FILE")
    [[ -d "$lock_dir" ]] || mkdir -p "$lock_dir"

    exec {LOCK_FD}>"$LOCK_FILE"
    if ! flock -n "$LOCK_FD"; then
        echo "ERROR: Another atomic operation is running" >&2
        exit 1
    fi
    export LOCK_FD
}

# ── fstab update (delegates to Python for safety) ──────────────────

update_fstab() {
    python3 /usr/local/lib/atomic/fstab.py "$@"
}

# ── Root device detection ───────────────────────────────────────────

# get_current_subvol: returns subvolume name without leading slash
get_current_subvol() {
    local raw
    raw=$(get_current_subvol_raw)
    echo "${raw#/}"
}

# get_current_subvol_raw: returns subvolume as reported by findmnt
# Uses sed instead of grep -P for portability
get_current_subvol_raw() {
    findmnt -n -o OPTIONS / | sed -n 's/.*subvol=\([^,]*\).*/\1/p'
}

# ── Btrfs mount helpers ────────────────────────────────────────────

ensure_btrfs_mounted() {
    mkdir -p "$BTRFS_MOUNT" || return 1
    if ! mountpoint -q "$BTRFS_MOUNT" 2>/dev/null; then
        mount -o subvolid=5 "/dev/mapper/${MAPPER_NAME}" "$BTRFS_MOUNT" || {
            echo "ERROR: Failed to mount Btrfs root" >&2
            return 1
        }
    fi
}

validate_subvolume() {
    local subvol="$1"
    local mount="${2:-$BTRFS_MOUNT}"

    [[ -z "$subvol" ]] && return 1

    if ! mountpoint -q "$mount" 2>/dev/null; then
        ensure_btrfs_mounted || return 1
    fi

    [[ -d "${mount}/${subvol}" ]] || return 1
    btrfs subvolume show "${mount}/${subvol}" &>/dev/null
}

# ── Space checks ───────────────────────────────────────────────────

check_btrfs_space() {
    local mount_point="$1"
    local min_percent="${2:-10}"

    # Try btrfs-native output first, fall back to df
    local free_bytes total_bytes

    free_bytes=$(btrfs filesystem usage -b "$mount_point" 2>/dev/null |
        awk '/Free \(estimated\)/ {gsub(/[^0-9]/,"",$3); print $3}')
    total_bytes=$(btrfs filesystem usage -b "$mount_point" 2>/dev/null |
        awk '/Device size/ {gsub(/[^0-9]/,"",$3); print $3}')

    # Fallback to df if btrfs output parsing failed
    if [[ -z "$free_bytes" || -z "$total_bytes" || "$total_bytes" -eq 0 ]] 2>/dev/null; then
        local df_line
        df_line=$(df -B1 --output=size,avail "$mount_point" 2>/dev/null | tail -1)
        if [[ -n "$df_line" ]]; then
            read -r total_bytes free_bytes <<< "$df_line"
        fi
    fi

    if [[ -z "$free_bytes" || -z "$total_bytes" ]] 2>/dev/null || [[ "$total_bytes" -eq 0 ]] 2>/dev/null; then
        echo "WARN: Cannot determine disk space, continuing anyway" >&2
        return 0
    fi

    local free_percent=$((free_bytes * 100 / total_bytes))
    local free_gb=$((free_bytes / 1073741824))

    if [[ $free_percent -lt $min_percent ]]; then
        echo "ERROR: Low disk space: ${free_percent}% free (~${free_gb}GB), need ${min_percent}%" >&2
        return 1
    fi

    echo "   Disk space: ${free_percent}% free (~${free_gb}GB)"
    return 0
}

check_esp_space() {
    local min_mb="${1:-100}"
    local avail_kb
    avail_kb=$(df -k "$ESP" | awk 'NR==2 {print $4}')

    if [[ -z "$avail_kb" ]]; then
        echo "WARN: Cannot check ESP space" >&2
        return 0
    fi

    local avail_mb=$((avail_kb / 1024))
    if [[ $avail_mb -lt $min_mb ]]; then
        echo "ERROR: Low ESP space: ${avail_mb}MB free (need ${min_mb}MB)" >&2
        return 1
    fi
    echo "   ESP space: ${avail_mb}MB free"
}

# ── Generation listing ──────────────────────────────────────────────

list_generations() {
    local -a gens=()
    local f
    for f in "${ESP}/EFI/Linux/arch-"*.efi; do
        [[ -e "$f" ]] || continue
        local name="${f##*/}"
        name="${name#arch-}"
        name="${name%.efi}"
        gens+=("$name")
    done
    printf '%s\n' "${gens[@]}" | sort -r
}

# ── UKI build (uses rootdev.py for cmdline auto-detection) ──────────

build_uki() {
    local gen_id="$1" new_root="$2" new_subvol="$3"
    local uki_path="${ESP}/EFI/Linux/arch-${gen_id}.efi"
    local os_release_tmp=""

    local kernel="${new_root}/boot/vmlinuz-${KERNEL_PKG}"
    local initramfs="${new_root}/boot/initramfs-${KERNEL_PKG}.img"

    [[ -f "$kernel" ]] || { echo "ERROR: No kernel: $kernel" >&2; return 1; }
    [[ -f "$initramfs" ]] || { echo "ERROR: No initramfs: $initramfs" >&2; return 1; }

    local root_cmdline
    root_cmdline=$(python3 /usr/local/lib/atomic/rootdev.py cmdline "$new_subvol") || {
        echo "ERROR: Cannot detect root device for cmdline" >&2
        return 1
    }

    local cmdline="${root_cmdline} ${KERNEL_PARAMS}"

    os_release_tmp=$(mktemp) || { echo "ERROR: Cannot create temp file" >&2; return 1; }
    trap 'rm -f "$os_release_tmp"' RETURN

    sed "s|^PRETTY_NAME=.*|PRETTY_NAME=\"Arch Linux (${gen_id})\"|" \
        "${new_root}/etc/os-release" > "$os_release_tmp" || {
        echo "ERROR: Failed to create temp os-release" >&2
        return 1
    }

    if ! ukify build \
        --linux="$kernel" \
        --initrd="$initramfs" \
        --cmdline="$cmdline" \
        --os-release="@${os_release_tmp}" \
        --output="$uki_path"; then
        echo "ERROR: ukify build failed" >&2
        return 1
    fi

    [[ -f "$uki_path" ]] || { echo "ERROR: UKI not created" >&2; return 1; }

    echo "$uki_path"
}

# ── Garbage collection ──────────────────────────────────────────────

garbage_collect() {
    local keep="${1:-$KEEP_GENERATIONS}"
    local dry_run="${2:-0}"
    local current_subvol
    current_subvol=$(get_current_subvol)

    [[ -z "$current_subvol" ]] && { echo "ERROR: Cannot determine current subvolume" >&2; return 1; }

    echo ":: Garbage collecting (keeping last ${keep} + current)..."
    echo "   Current: ${current_subvol}"

    ensure_btrfs_mounted || return 1

    local generations
    generations=$(list_generations)

    [[ -z "$generations" ]] && { echo "   No generations found"; return 0; }

    local -a to_keep=()
    local -a to_delete=()
    local count=0

    for gen_id in $generations; do
        local subvol_name="root-${gen_id}"

        # Never delete the currently booted subvolume
        if [[ "$subvol_name" == "$current_subvol" ]]; then
            to_keep+=("$gen_id (current)")
            continue
        fi

        count=$((count + 1))
        if [[ $count -le $keep ]]; then
            to_keep+=("$gen_id")
        else
            to_delete+=("$gen_id")
        fi
    done

    if [[ ${#to_keep[@]} -gt 0 ]]; then
        printf '   Keeping: %s\n' "${to_keep[@]}"
    else
        echo "   Keeping: (none)"
    fi

    if [[ ${#to_delete[@]} -eq 0 ]]; then
        echo "   Nothing to delete"
    fi

    for gen_id in "${to_delete[@]}"; do
        local subvol_name="root-${gen_id}"

        # Double safety check: never delete current
        if [[ "$subvol_name" == "$current_subvol" ]]; then
            echo "   SKIP: ${gen_id} is current (safety check)"
            continue
        fi

        if [[ "$dry_run" -eq 1 ]]; then
            echo "   Would delete: ${gen_id}"
        else
            echo "   Deleting: ${gen_id}"
            rm -f "${ESP}/EFI/Linux/arch-${gen_id}.efi"
            if [[ -d "${BTRFS_MOUNT}/root-${gen_id}" ]]; then
                btrfs subvolume delete "${BTRFS_MOUNT}/root-${gen_id}" 2>/dev/null || {
                    echo "   WARN: Failed to delete subvolume root-${gen_id}" >&2
                }
            fi
        fi
    done

    local deleted_count=${#to_delete[@]}
    if [[ $deleted_count -gt 0 && "$dry_run" -eq 0 ]]; then
        echo "   Deleted ${deleted_count} generation(s)"
    fi

    echo ":: Garbage collection done"
}
