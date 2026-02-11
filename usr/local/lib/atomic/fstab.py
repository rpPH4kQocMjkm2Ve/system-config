#!/usr/bin/env python3
"""
/usr/local/lib/atomic/fstab.py

Safe fstab manipulation for atomic-upgrade.
Handles subvol= replacement for the root (/) mount entry.

Usage: fstab.py <fstab_path> <old_subvol> <new_subvol>

Safety features:
  - Only modifies entries with mountpoint == "/"
  - Creates .bak backup before writing
  - Atomic write via tmp+rename
  - Post-write verification with auto-rollback
  - Preserves leading slash style in subvol= values
"""

import os
import stat as stat_mod
import sys
import shutil
from pathlib import Path
from dataclasses import dataclass


@dataclass
class FstabEntry:
    """Represents a single fstab line (data or comment/blank)."""

    raw: str
    device: str = ""
    mountpoint: str = ""
    fstype: str = ""
    options: str = ""
    dump: str = "0"
    passno: str = "0"
    is_data: bool = False

    @classmethod
    def parse(cls, line: str) -> "FstabEntry":
        """Parse a single fstab line. Non-data lines are preserved as-is."""
        stripped = line.strip()
        if not stripped or stripped.startswith("#"):
            return cls(raw=line)

        parts = stripped.split()
        if len(parts) < 4:
            return cls(raw=line)

        return cls(
            raw=line,
            device=parts[0],
            mountpoint=parts[1],
            fstype=parts[2],
            options=parts[3],
            dump=parts[4] if len(parts) > 4 else "0",
            passno=parts[5] if len(parts) > 5 else "0",
            is_data=True,
        )

    def replace_subvol(self, old: str, new: str) -> bool:
        """Replace subvol=<old> with subvol=<new> in mount options.

        Preserves the leading slash style: if the original value had
        a leading /, the replacement will too, and vice versa.

        Returns True if a replacement was made.
        """
        if not self.is_data:
            return False

        opts = self.options.split(",")
        changed = False
        result = []

        old_norm = old.strip("/")
        new_norm = new.strip("/")

        for opt in opts:
            if opt.startswith("subvol="):
                val = opt[len("subvol="):]
                if val.lstrip("/") == old_norm:
                    # Preserve leading slash if original had one
                    prefix = "/" if val.startswith("/") else ""
                    result.append(f"subvol={prefix}{new_norm}")
                    changed = True
                    continue
            result.append(opt)

        if changed:
            self.options = ",".join(result)
        return changed

    def format(self) -> str:
        """Format entry back to fstab line.

        Data entries are re-formatted with tabs; comments and blank
        lines are returned unchanged.
        """
        if not self.is_data:
            return self.raw
        return (
            f"{self.device}\t{self.mountpoint}\t{self.fstype}"
            f"\t{self.options}\t{self.dump} {self.passno}\n"
        )


def update_fstab(path_str: str, old_subvol: str, new_subvol: str) -> bool:
    """Update the root entry's subvol= in fstab.

    Steps:
      1. Back up original to .bak
      2. Parse all lines, modify only mountpoint=="/" entries
      3. Write to .tmp, then atomically rename over original
      4. Re-read and verify the new subvol is present
      5. On verification failure, restore from .bak

    Returns True on success, False on any error.
    """
    path = Path(path_str)

    if not path.is_file():
        print(f"ERROR: fstab not found: {path}", file=sys.stderr)
        return False

    # Create backup before any modification
    backup = path.with_suffix(".bak")
    shutil.copy2(path, backup)

    lines = path.read_text().splitlines(keepends=True)
    entries = [FstabEntry.parse(line) for line in lines]

    # Find root mount entries (mountpoint == "/")
    root_entries = [e for e in entries if e.is_data and e.mountpoint == "/"]

    if not root_entries:
        print("ERROR: No root (/) entry found in fstab", file=sys.stderr)
        return False

    updated = 0
    for entry in root_entries:
        if entry.replace_subvol(old_subvol, new_subvol):
            updated += 1

    if updated == 0:
        print(
            f"ERROR: Root entry exists but subvol={old_subvol} not found",
            file=sys.stderr,
        )
        return False

    if updated > 1:
        print(
            f"WARN: Multiple root entries updated ({updated}), review fstab",
            file=sys.stderr,
        )

    # Atomic write: preserve original permissions
    tmp = path.with_suffix(".tmp")
    original_stat = path.stat()
    tmp.write_text("".join(e.format() for e in entries))

    os.chown(tmp, original_stat.st_uid, original_stat.st_gid)
    os.chmod(tmp, stat_mod.S_IMODE(original_stat.st_mode))

    tmp.replace(path)

    # Post-write verification
    new_norm = new_subvol.strip("/")
    text = path.read_text()
    if f"subvol=/{new_norm}" not in text and f"subvol={new_norm}" not in text:
        print("ERROR: Verification failed, restoring backup", file=sys.stderr)
        shutil.copy2(backup, path)
        return False

    return True


if __name__ == "__main__":
    if len(sys.argv) != 4:
        print(
            f"Usage: {sys.argv[0]} FSTAB_PATH OLD_SUBVOL NEW_SUBVOL",
            file=sys.stderr,
        )
        sys.exit(1)
    sys.exit(0 if update_fstab(*sys.argv[1:]) else 1)
