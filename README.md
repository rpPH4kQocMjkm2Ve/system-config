# root-chezmoi — Arch Linux system configuration

System-level configuration files (`/etc`, `/efi`, `/usr/local`) managed with
[chezmoi](https://www.chezmoi.io/) using `destDir = "/"`.

Includes an atomic upgrade system for Arch Linux on Btrfs + UKI + Secure Boot.

## What's included

- **Atomic upgrades**: NixOS/Silverblue-style generational updates on plain Arch
- **Boot**: systemd-boot with signed UKI (Secure Boot via sbctl)
- **Filesystem**: Btrfs on LUKS, automated snapshots via btrbk
- **Network**: systemd-networkd (wired + wifi)
- **Containers**: Podman with btrfs storage driver
- **Hardening**: kernel sysctl, faillock, coredump off, USB lock, pam, hardened_malloc

## hardened_malloc

[hardened_malloc](https://github.com/GrapheneOS/hardened_malloc) is built from source via `run_onchange_build_hardened_malloc.sh` and deployed to `/usr/local/lib/`.

Both variants are built:
- **default** (`libhardened_malloc.so`) — full hardening, used per-app via bwrap `LD_PRELOAD`
- **light** (`libhardened_malloc-light.so`) — balanced, loaded system-wide via `/etc/ld.so.preload`

A `libfake_rlimit.so` shim is also built and preloaded before hardened_malloc. It intercepts `prlimit64(RLIMIT_AS)` calls from GTK4's glycin image loaders, which set a 16 GB virtual memory limit incompatible with hardened_malloc's ~240 GB guard region reservation.

`/etc/ld.so.preload` is managed by the build script (not as a chezmoi file) to ensure libraries exist before the preload file references them.

### Updating

```bash
# 1. Check latest tag
git ls-remote --tags https://github.com/GrapheneOS/hardened_malloc.git | grep -oP 'refs/tags/\K[0-9]{10}$' | sort -n | tail -5

# 2. Update TAG (and FAKE_RLIMIT_VER if shim changed) in run_onchange_build_hardened_malloc.sh

# 3. Rebuild and deploy
sudo chezmoi apply  # builds into source dir + writes /etc/ld.so.preload
sudo chezmoi apply  # deploys .so files to /usr/local/lib/
```

### Compatibility

Applications with custom allocators (Chromium/PartitionAlloc, Firefox/mozjemalloc) are incompatible and must have hardened_malloc disabled in their bwrap wrappers. See [user dotfiles](https://gitlab.com/fkzys/dotfiles) for details.

GTK4 applications work via the `libfake_rlimit.so` shim.

### Configuration

- `/etc/ld.so.preload` — `libfake_rlimit.so` + `libhardened_malloc-light.so` (managed by build script)
- `/etc/sysctl.d/20-hardened-malloc.conf` — `vm.max_map_count = 1048576` for guard slabs

## Atomic upgrade system

Generational updates: snapshot → chroot upgrade → UKI build → sign → reboot.

```
pacman -Syu  →  blocked by guard/wrapper
                ↓
         sudo atomic-upgrade
                ↓
    1. Btrfs snapshot of current root
    2. Mount snapshot, arch-chroot into it
    3. pacman -Syu inside chroot
    4. Update fstab (subvol=)
    5. Build UKI (ukify)
    6. Sign with sbctl (Secure Boot)
    7. Garbage collect old generations
                ↓
         reboot → new generation active
```

Rollback: select a previous UKI entry in systemd-boot at boot time.

### Usage

```bash
sudo atomic-upgrade            # full system upgrade
sudo atomic-upgrade --dry-run  # preview without changes
sudo atomic-gc                 # clean old generations (keep last 3 + current)
sudo atomic-gc --dry-run 2     # preview: keep last 2
```

### Configuration

`/etc/atomic.conf`:

| Parameter | Default | Description |
|-----------|---------|-------------|
| `BTRFS_MOUNT` | `/mnt/temp_root` | Btrfs top-level mount point |
| `NEW_ROOT` | `/mnt/newroot` | New snapshot mount point |
| `ESP` | `/efi` | EFI System Partition |
| `KEEP_GENERATIONS` | `3` | Generations to keep (excluding current) |
| `MAPPER_NAME` | `root_crypt` | dm-crypt mapper name |
| `KERNEL_PKG` | `linux` | Kernel package (linux/linux-lts/linux-zen) |
| `KERNEL_PARAMS` | *(security defaults)* | Kernel command line parameters |

### Components

| File | Role |
|------|------|
| `atomic-upgrade` | Main upgrade script |
| `atomic-gc` | Garbage collection of old generations |
| `atomic-guard` | Pacman hook — blocks direct `-Syu` |
| `pacman` (wrapper) | Suggests `atomic-upgrade` on `-Syu` |
| `common.sh` | Shared library (config, locking, btrfs, UKI build, GC) |
| `fstab.py` | Safe fstab editing (atomic write + verification + rollback) |
| `rootdev.py` | Auto-detect root device type (LUKS/LVM/plain) |

## Structure

```
.
├── efi/loader/              # systemd-boot config
├── etc/
│   ├── atomic.conf.tmpl     # atomic-upgrade config (per-host kernel params)
│   ├── btrbk/               # Btrfs snapshot policy
│   ├── containers/          # Podman (btrfs driver, per-host graphroot)
│   ├── mkinitcpio.*         # Initramfs (per-host nvidia modules)
│   ├── modprobe.d/          # Kernel modules (nvidia)
│   ├── pacman.d/hooks/      # Pacman hooks
│   ├── pam.d/               # PAM (gnome-keyring auto-unlock)
│   ├── polkit-1/            # Polkit rules (sing-box DNS)
│   ├── security/            # faillock
│   ├── sysctl.d/            # Kernel parameters + hardened_malloc vm.max_map_count
│   ├── systemd/             # networkd, journald, coredump, zram
│   └── tmpfiles.d/          # Battery, USB lock
├── root/
│   └── dot_zshrc            # Root shell config
├── run_onchange_build_hardened_malloc.sh
└── usr/local/
    ├── bin/                 # atomic-upgrade tooling + pacman wrapper
    └── lib/
        ├── atomic/                     # Shared library + Python helpers
        ├── libfake_rlimit.so           # (built, gitignored) glycin RLIMIT_AS shim
        ├── libhardened_malloc.so       # (built, gitignored)
        └── libhardened_malloc-light.so # (built, gitignored)
```

## Per-host configuration

Feature flags are set via `chezmoi init` prompts and stored in `/root/.config/chezmoi/chezmoi.toml`:

| Variable | Description |
|---|---|
| `nvidia` | NVIDIA GPU (mkinitcpio modules, modprobe config) |
| `tpm2_unlock` | TPM2 LUKS auto-unlock (`rd.luks.options=tpm2-device=auto`) |
| `laptop` | Battery charge thresholds (tmpfiles) |

Per-host data (btrbk targets, podman graphroot) is stored in `secrets.enc.yaml`, keyed by hostname.

## Secrets

Encrypted with [SOPS](https://github.com/getsops/sops) + [age](https://github.com/FiloSottile/age).

Each machine has its own age key, stored separately from this repo.

### Structure

```yaml
# secrets.enc.yaml (decrypted view)
polkit:
    username: "actual_username"
```

Templates access secrets via:

```
{{ $s := output "sops" "-d" (joinPath .chezmoi.sourceDir "secrets.enc.yaml") | fromYaml -}}
{{ index $s "polkit" "username" }}
```

### Setup on a new machine

1. Create age key:
```bash
sudo mkdir -p /root/.config/chezmoi
sudo age-keygen -o /root/.config/chezmoi/key.txt
```

2. Add public key to `.sops.yaml` and re-encrypt:
```bash
# Edit .sops.yaml, add new recipient
sops updatekeys secrets.enc.yaml
```

3. Apply:
```bash
sudo chezmoi init --apply <GIT_URL>
sudo chezmoi apply  # second run to deploy built libraries
```

## Post-install

```bash
# Enable zram
sudo systemctl start systemd-zram-setup@zram0.service

# Create snapshot directories for btrbk
sudo mkdir -p /snapshots/{root,home}
sudo systemctl enable --now btrbk.timer
```

## Dependencies

### Required

- `btrfs-progs` — Btrfs operations
- `systemd-ukify` — UKI build
- `sbctl` — Secure Boot signing
- `python` ≥ 3.10 — fstab.py, rootdev.py
- `chezmoi` — configuration management
- `sops` + `age` — secret encryption
- `base-devel` + `gcc` — building hardened_malloc and libfake_rlimit

### Optional

- `btrbk` — automated Btrfs snapshots
- `podman` — containers (btrfs storage driver)
