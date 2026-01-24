#!/bin/bash
# /usr/local/lib/atomic/common.sh

BTRFS_MOUNT="/mnt/temp_root"
NEW_ROOT="/mnt/newroot"
ESP="/efi"
KEEP_GENERATIONS=3
MAPPER_NAME="root_crypt"
LOCK_FILE="/var/lock/atomic-upgrade.lock"
LOG_FILE="/var/log/atomic-upgrade.log"
# Kernel security parameters (can be overridden in /etc/atomic.conf)
KERNEL_PARAMS="rw slab_nomerge init_on_alloc=1 page_alloc.shuffle=1 pti=on vsyscall=none randomize_kstack_offset=on debugfs=off"

CONFIG_FILE="/etc/atomic.conf"
[[ -f "$CONFIG_FILE" ]] && source "$CONFIG_FILE"

validate_config() {
    [[ -d "$ESP" ]] || { echo "ERROR: ESP not found: $ESP" >&2; return 1; }
    [[ -e "/dev/mapper/${MAPPER_NAME}" ]] || { echo "ERROR: Mapper not found: $MAPPER_NAME" >&2; return 1; }
    [[ "$KEEP_GENERATIONS" =~ ^[0-9]+$ ]] || { echo "ERROR: Invalid KEEP_GENERATIONS" >&2; return 1; }
    [[ "$KEEP_GENERATIONS" -ge 1 ]] || { echo "ERROR: KEEP_GENERATIONS must be >= 1" >&2; return 1; }
    return 0
}

log() {
    local level="${1:-INFO}"
    shift
    local msg="[$(date '+%Y-%m-%d %H:%M:%S')] [${level}] $*"
    echo "$msg" | tee -a "$LOG_FILE"
}

log_info()  { log "INFO" "$@"; }
log_error() { log "ERROR" "$@" >&2; }
log_warn()  { log "WARN" "$@"; }

check_dependencies() {
    local missing=()
    for cmd in btrfs ukify sbctl cryptsetup findmnt arch-chroot; do
        command -v "$cmd" >/dev/null || missing+=("$cmd")
    done
    if [[ ${#missing[@]} -gt 0 ]]; then
        echo "ERROR: Missing commands: ${missing[*]}" >&2
        return 1
    fi
}

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

update_fstab() {
    local fstab="$1" old_subvol="$2" new_subvol="$3"
    
    [[ -f "$fstab" ]] || { echo "ERROR: fstab not found: $fstab" >&2; return 1; }
    
    local old_escaped new_escaped
    old_escaped=$(printf '%s\n' "$old_subvol" | sed 's/[][\.*^$()+?{|]/\\&/g')
    new_escaped=$(printf '%s\n' "$new_subvol" | sed 's/[&/\]/\\&/g')
    
    sed -i "/[[:space:]]\/[[:space:]]/ s|subvol=/*${old_escaped}|subvol=/${new_escaped}|" "$fstab" || {
        echo "ERROR: Failed to update fstab" >&2
        return 1
    }
}

get_luks_uuid() {
    local mapper_name="${1:-$MAPPER_NAME}"
    local device
    device=$(cryptsetup status "$mapper_name" 2>/dev/null | grep "device:" | awk '{print $2}')
    
    [[ -z "$device" ]] && { echo "ERROR: Cannot find device for mapper ${mapper_name}" >&2; return 1; }
    
    local uuid
    uuid=$(blkid -s UUID -o value "$device") || { 
        echo "ERROR: Cannot get UUID for ${device}" >&2
        return 1 
    }
    
    [[ -z "$uuid" ]] && { echo "ERROR: Empty UUID for ${device}" >&2; return 1; }
    echo "$uuid"
}

get_current_subvol() {
    local raw
    raw=$(get_current_subvol_raw)
    echo "${raw#/}"
}

get_current_subvol_raw() {
    findmnt -n -o OPTIONS / | grep -oP 'subvol=\K[^,]+'
}

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

check_btrfs_space() {
    local mount_point="$1"
    local min_percent="${2:-10}"
    
    local free_bytes total_bytes
    free_bytes=$(btrfs filesystem usage -b "$mount_point" 2>/dev/null | 
            awk '/Free \(estimated\)/ {gsub(/[^0-9]/,"",$3); print $3}')
    total_bytes=$(btrfs filesystem usage -b "$mount_point" 2>/dev/null |
            awk '/Device size/ {gsub(/[^0-9]/,"",$3); print $3}')
    
    if [[ -z "$free_bytes" || -z "$total_bytes" || "$total_bytes" -eq 0 ]]; then
        echo "WARN: Cannot determine disk space, continuing anyway" >&2
        return 0
    fi
    
    local free_percent=$((free_bytes * 100 / total_bytes))
    local free_gb=$(( free_bytes / 1073741824 ))
    
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

build_uki() {
    local gen_id="$1" new_root="$2" new_subvol="$3"
    local uki_path="${ESP}/EFI/Linux/arch-${gen_id}.efi"
    local os_release_tmp=""
    local luks_uuid=""

    [[ -f "${new_root}/boot/vmlinuz-linux" ]] || { echo "ERROR: No kernel" >&2; return 1; }
    [[ -f "${new_root}/boot/initramfs-linux.img" ]] || { echo "ERROR: No initramfs" >&2; return 1; }

    luks_uuid=$(get_luks_uuid) || return 1

    os_release_tmp=$(mktemp) || { echo "ERROR: Cannot create temp file" >&2; return 1; }
    
    trap 'rm -f "$os_release_tmp"' RETURN
    
    sed "s|^PRETTY_NAME=.*|PRETTY_NAME=\"Arch Linux (${gen_id})\"|" \
        "${new_root}/etc/os-release" > "$os_release_tmp" || {
        echo "ERROR: Failed to create temp os-release" >&2
        return 1
    }
    
    local cmdline="rd.luks.name=${luks_uuid}=${MAPPER_NAME} root=/dev/mapper/${MAPPER_NAME} rootflags=subvol=${new_subvol} ${KERNEL_PARAMS}"
    
    if ! ukify build \
        --linux="${new_root}/boot/vmlinuz-linux" \
        --initrd="${new_root}/boot/initramfs-linux.img" \
        --cmdline="$cmdline" \
        --os-release="@${os_release_tmp}" \
        --output="$uki_path"; then
        echo "ERROR: ukify build failed" >&2
        return 1
    fi
    
    [[ -f "$uki_path" ]] || { echo "ERROR: UKI not created" >&2; return 1; }

    echo "$uki_path"
}

garbage_collect() {
    local keep="${1:-$KEEP_GENERATIONS}"
    local dry_run="${2:-0}"
    local current_subvol
    current_subvol=$(get_current_subvol_raw | sed 's|^/||')
    
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

