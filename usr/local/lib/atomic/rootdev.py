#!/usr/bin/env python3
"""
/usr/local/lib/atomic/rootdev.py

Auto-detect root device type and build kernel cmdline.
Eliminates hardcoded LUKS assumptions — works with plain btrfs,
LUKS, LVM, or combinations.

Usage:
  rootdev.py detect          → JSON with root device info
  rootdev.py cmdline SUBVOL  → kernel cmdline fragment (without extra params)

Exit codes:
  0 — success
  1 — detection failed
"""

import json
import subprocess
import sys


def run(*cmd: str) -> str:
    """Run a command, return stripped stdout or empty string on failure."""
    try:
        result = subprocess.run(
            cmd,
            capture_output=True,
            text=True,
            timeout=10,
        )
        return result.stdout.strip() if result.returncode == 0 else ""
    except (subprocess.TimeoutExpired, FileNotFoundError):
        return ""


def detect_root() -> dict:
    """Detect root filesystem device, type, and relevant UUIDs.

    Returns a dict with keys:
      source    — block device path (e.g. /dev/mapper/root_crypt)
      fstype    — filesystem type (e.g. btrfs)
      subvol    — current subvolume or None
      type      — "plain" | "luks" | "lvm" | "luks+lvm"
      luks_uuid — UUID of the LUKS container, or None
      luks_name — dm name of the LUKS mapping, or None
      root_arg  — value for root= kernel parameter
    """
    raw = run("findmnt", "-n", "-J", "-o", "SOURCE,FSTYPE,OPTIONS", "/")
    if not raw:
        return {}

    try:
        data = json.loads(raw)["filesystems"][0]
    except (json.JSONDecodeError, KeyError, IndexError):
        return {}

    source: str = data.get("source", "")
    options: str = data.get("options", "")

    # findmnt reports btrfs sources with subvolume path appended in brackets:
    #   /dev/mapper/root_crypt[/root-20260208-134725]
    # Strip the bracket suffix to get the actual block device path
    if "[" in source:
        source = source[: source.index("[")]

    # Extract subvol from mount options
    subvol = None
    for opt in options.split(","):
        if opt.startswith("subvol="):
            subvol = opt.split("=", 1)[1]
            break

    info = {
        "source": source,
        "fstype": data.get("fstype", ""),
        "subvol": subvol,
        "type": "plain",
        "luks_uuid": None,
        "luks_name": None,
        "root_arg": source,
    }

    # Check if root is on a device-mapper target (LUKS or LVM)
    if "/mapper/" in source or source.startswith("/dev/dm-"):
        mapper = source.rsplit("/", 1)[-1]
        _detect_dm_type(mapper, info)

    return info


def _detect_dm_type(mapper: str, info: dict) -> None:
    """Detect whether a device-mapper target is LUKS, LVM, or both.

    Modifies `info` in place.
    """
    # Check for dm-crypt (LUKS)
    table = run("dmsetup", "table", "--target", "crypt", mapper)
    if table:
        info["type"] = "luks"
        info["luks_name"] = mapper
        info["root_arg"] = f"/dev/mapper/{mapper}"

        # Find the underlying device and its UUID
        status = run("cryptsetup", "status", mapper)
        for line in status.splitlines():
            if "device:" in line:
                underlying = line.split()[-1]
                uuid = run("blkid", "-s", "UUID", "-o", "value", underlying)
                if uuid:
                    info["luks_uuid"] = uuid
                break
        return

    # Check for LVM
    lv_info = run(
        "lvs", "--noheadings", "-o", "vg_name,lv_name",
        f"/dev/mapper/{mapper}",
    )
    if lv_info:
        info["type"] = "lvm"
        info["root_arg"] = f"/dev/mapper/{mapper}"

        # LVM on LUKS: check if the PV is on a LUKS device
        parts = lv_info.split()
        if len(parts) >= 1:
            vg = parts[0]
            pv_raw = run(
                "pvs", "--noheadings", "-o", "pv_name", "-S", f"vg_name={vg}",
            )
            pv = pv_raw.strip()
            if pv and "/mapper/" in pv:
                pv_mapper = pv.rsplit("/", 1)[-1]
                pv_table = run("dmsetup", "table", "--target", "crypt", pv_mapper)
                if pv_table:
                    info["type"] = "luks+lvm"
                    info["luks_name"] = pv_mapper
                    pv_status = run("cryptsetup", "status", pv_mapper)
                    for line in pv_status.splitlines():
                        if "device:" in line:
                            underlying = line.split()[-1]
                            uuid = run(
                                "blkid", "-s", "UUID", "-o", "value",
                                underlying,
                            )
                            if uuid:
                                info["luks_uuid"] = uuid
                            break


def build_cmdline(info: dict, new_subvol: str) -> str:
    """Build kernel cmdline fragment from detected root info."""
    parts = []

    # Add LUKS unlock directive if applicable
    if info.get("type") in ("luks", "luks+lvm") and info.get("luks_uuid"):
        parts.append(
            f"rd.luks.name={info['luks_uuid']}={info['luks_name']}"
        )

    parts.append(f"root={info['root_arg']}")

    if info.get("fstype"):
        parts.append(f"rootfstype={info['fstype']}")

    parts.append(f"rootflags=subvol={new_subvol}")

    return " ".join(parts)


def main() -> int:
    if len(sys.argv) < 2:
        print(
            f"Usage: {sys.argv[0]} detect|cmdline|device [SUBVOL]",
            file=sys.stderr,
        )
        return 1

    command = sys.argv[1]

    if command == "detect":
        info = detect_root()
        if not info:
            print("ERROR: Failed to detect root device", file=sys.stderr)
            return 1
        json.dump(info, sys.stdout, indent=2)
        print()
        return 0

    elif command == "cmdline":
        if len(sys.argv) < 3:
            print("ERROR: SUBVOL argument required", file=sys.stderr)
            return 1
        info = detect_root()
        if not info:
            print("ERROR: Failed to detect root device", file=sys.stderr)
            return 1
        print(build_cmdline(info, sys.argv[2]))
        return 0

    elif command == "device":
        info = detect_root()
        if not info:
            print("ERROR: Failed to detect root device", file=sys.stderr)
            return 1
        print(info["source"])
        return 0

    else:
        print(f"ERROR: Unknown command: {command}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    sys.exit(main())
