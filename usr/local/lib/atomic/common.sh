#!/bin/bash
# /usr/local/lib/atomic/common.sh

BTRFS_MOUNT="/mnt/temp_root"
NEW_ROOT="/mnt/newroot"
ESP="/efi"
KEEP_GENERATIONS=3
MAPPER_NAME="root_crypt"

get_luks_uuid() {
    local mapper_name="${1:-$MAPPER_NAME}"
    
    local device
    device=$(cryptsetup status "$mapper_name" 2>/dev/null | grep "device:" | awk '{print $2}')
    
    if [[ -z "$device" ]]; then
        echo "ERROR: Cannot find device for mapper ${mapper_name}" >&2
        return 1
    fi
    
    blkid -s UUID -o value "$device"
}

get_current_subvol() {
    findmnt -n -o OPTIONS / | grep -oP 'subvol=/\Kroot-[^,]+' || echo ""
}

get_current_subvol_raw() {
    findmnt -n -o OPTIONS / | grep -oP 'subvol=\K[^,]+'
}

ensure_btrfs_mounted() {
    mkdir -p "$BTRFS_MOUNT"
    if ! mountpoint -q "$BTRFS_MOUNT" 2>/dev/null; then
        mount -o subvolid=5 "/dev/mapper/${MAPPER_NAME}" "$BTRFS_MOUNT"
    fi
}

list_generations() {
    ls -1 "${ESP}/EFI/Linux/arch-"*.efi 2>/dev/null | \
        sed 's|.*/arch-||' | sed 's|\.efi$||' | sort -r
}

build_uki() {
    local gen_id="$1"
    local new_root="$2"
    local new_subvol="$3"
    local uki_path="${ESP}/EFI/Linux/arch-${gen_id}.efi"

    local luks_uuid
    luks_uuid=$(get_luks_uuid)
    
    local os_release_tmp
    os_release_tmp=$(mktemp)
    
    sed "s|^PRETTY_NAME=.*|PRETTY_NAME=\"Arch Linux (${gen_id})\"|" \
        "${new_root}/etc/os-release" > "$os_release_tmp"
    
    local cmdline="rd.luks.name=${luks_uuid}=root_crypt root=/dev/mapper/${MAPPER_NAME} rootflags=subvol=${new_subvol} rw slab_nomerge init_on_alloc=1 page_alloc.shuffle=1 pti=on vsyscall=none randomize_kstack_offset=on debugfs=off"
    
    ukify build \
        --linux="${new_root}/boot/vmlinuz-linux" \
        --initrd="${new_root}/boot/initramfs-linux.img" \
        --cmdline="$cmdline" \
	--os-release="$(cat ${os_release_tmp})" \
        --output="$uki_path"
    
    rm -f "$os_release_tmp"
    
    echo "$uki_path"
}

garbage_collect() {
    local keep="${1:-$KEEP_GENERATIONS}"
    local current_subvol
    current_subvol=$(get_current_subvol_raw | sed 's|^/||')
    
    echo ":: Garbage collecting (keeping last ${keep})..."
    echo "   Current: ${current_subvol}"
    
    ensure_btrfs_mounted
    
    local generations
    generations=$(list_generations)
    
    if [[ -z "$generations" ]]; then
        echo "   WARNING: No generations found!"
        return
    fi
    
    local kept=0
    for gen_id in $generations; do
        
        if [[ "root-${gen_id}" == "$current_subvol" ]]; then
            echo "   Keeping: ${gen_id} (current)"
            continue
        fi
        
        kept=$((kept + 1))  
        
        if [[ $kept -le $keep ]]; then
            echo "   Keeping: ${gen_id}"
            continue
        fi
        
        echo "   Deleting: ${gen_id}"
        rm -f "${ESP}/EFI/Linux/arch-${gen_id}.efi"
        
        if [[ -d "${BTRFS_MOUNT}/root-${gen_id}" ]]; then
            btrfs subvolume delete "${BTRFS_MOUNT}/root-${gen_id}"
        fi
    done
    
    echo ":: Garbage collection done"
}

