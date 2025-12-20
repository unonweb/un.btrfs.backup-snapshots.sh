REQUIREMENTS
============

This script expects **a directory with a timeline of snapshots of the same origin subvolume**.
These snapshots must be named like `date +%Y-%m-%d-%H%M%S`.
These snapshots must be readonly.

Warning: If you ever manually flip a *destination* snapshot to read-write to change something, you will break the incremental chain. 
Its UUID signature will change, and future -p attempts against it will fail!

```sh
ls -l /.snapshots/@name-of-origin-subvolume
# 2025-12-19-040024
# 2025-12-19-134114
# 2025-12-20-040011
```

USAGE
=====

```sh
un.btrfs.backup /path/to/source/snapshots /path/to/dest/snapshots
```

NOTES
=====

```sh
local latest_src_snap_path=$(printf "%s\n" "${src_snaps[@]}" | sort | tail -n 1)
local latest_src_snap_name=$(basename "${latest_src_snap_path}")
```

Why this works without a complex "Ancestry Check"

- **The UUID Magic**: When you do btrfs send -p /src/snap1 /src/snap2, the "send" stream includes the UUID of snap1. When the destination receives this, it looks at all subvolumes in the destination directory. If it finds one where the Received UUID matches snap1's UUID, it succeeds.

- **The Chain**: By updating prev_snap="${snap}" at the end of every loop iteration, you ensure that even if the destination already has 5 snapshots, the script will skip them, set prev_snap to the 5th one, and then use that as the parent for the 6th (the first missing one).