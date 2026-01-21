#!/bin/bash
# /usr/local/lib/atomic/common.sh

CONFIG_FILE="/etc/atomic.conf"
[[ -f "$CONFIG_FILE" ]] && source "$CONFIG_FILE"

validate_config() {
    [[ -d "$ESP" ]] || { echo "ERROR: ESP not found: $ESP" >&2; return 1; }
    [[ -e "/dev/mapper/${MAPPER_NAME}" ]] || { echo "ERROR: Mapper not found: $MAPPER_NAME" >&2; return 1; }
    [[ "$KEEP_GENERATIONS" =~ ^[0-9]+$ ]] || { echo "ERROR: Invalid KEEP_GENERATIONS" >&2; return 1; }
    return 0
}

BTRFS_MOUNT="/mnt/temp_root"
NEW_ROOT="/mnt/newroot"
ESP="/efi"
KEEP_GENERATIONS=3
MAPPER_NAME="root_crypt"
LOCK_FILE="/var/lock/atomic-upgrade.lock"
LOG_FILE="/var/log/atomic-upgrade.log"

log() {
    local msg="[$(date '+%Y-%m-%d %H:%M:%S')] $*"
    echo "$msg" | tee -a "$LOG_FILE"
}

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
    exec {LOCK_FD}>"$LOCK_FILE"
    if ! flock -n "$LOCK_FD"; then
        echo "ERROR: Another atomic operation is running" >&2
        exit 1
    fi
    export LOCK_FD
}

update_fstab() {
    local fstab="$1" old_subvol="$2" new_subvol="$3"
    local old_escaped new_escaped
    
    old_escaped=$(printf '%s\n' "$old_subvol" | sed 's/[[\.*^$()+?{|]/\\&/g')
    new_escaped=$(printf '%s\n' "$new_subvol" | sed 's/[&/\]/\\&/g')
    
    sed -i "/[[:space:]]\/[[:space:]]/ s|subvol=/*${old_escaped}|subvol=/${new_escaped}|" "$fstab"
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
    findmnt -n -o OPTIONS / | grep -oP 'subvol=/\Kroot-[^,]+' || echo ""
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

list_generations() {
    ls -1 "${ESP}/EFI/Linux/arch-"*.efi 2>/dev/null | \
        sed 's|.*/arch-||' | sed 's|\.efi$||' | sort -r
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
    trap "rm -f '$os_release_tmp'" RETURN
    
    sed "s|^PRETTY_NAME=.*|PRETTY_NAME=\"Arch Linux (${gen_id})\"|" \
        "${new_root}/etc/os-release" > "$os_release_tmp"
    
    local cmdline="rd.luks.name=${luks_uuid}=root_crypt root=/dev/mapper/${MAPPER_NAME} rootflags=subvol=${new_subvol} rw slab_nomerge init_on_alloc=1 page_alloc.shuffle=1 pti=on vsyscall=none randomize_kstack_offset=on debugfs=off"
    
    ukify build \
        --linux="${new_root}/boot/vmlinuz-linux" \
        --initrd="${new_root}/boot/initramfs-linux.img" \
        --cmdline="$cmdline" \
        --os-release="@${os_release_tmp}" \
        --output="$uki_path" || {
            echo "ERROR: ukify build failed" >&2
            return 1
        }
    
    [[ -f "$uki_path" ]] || { echo "ERROR: UKI not created" >&2; return 1; }

    echo "$uki_path"
}

garbage_collect() {
    local keep="${1:-$KEEP_GENERATIONS}"
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
    
    printf '   Keeping: %s\n' "${to_keep[@]}"
    
    for gen_id in "${to_delete[@]}"; do
        echo "   Deleting: ${gen_id}"
        rm -f "${ESP}/EFI/Linux/arch-${gen_id}.efi"
        [[ -d "${BTRFS_MOUNT}/root-${gen_id}" ]] && \
            btrfs subvolume delete "${BTRFS_MOUNT}/root-${gen_id}" 2>/dev/null || true
    done
    
    echo ":: Garbage collection done"
}

