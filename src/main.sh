#!/bin/bash

# ARGS
# ====
# - SRC_DIR_SNAPSHOTS
# - DST_DIR_SNAPSHOTS

set -o pipefail

export SCRIPT_PATH="$(readlink -f "${BASH_SOURCE}")"
export SCRIPT_DIR=$(dirname -- "$(readlink -f "${BASH_SOURCE}")")
export SCRIPT_NAME=$(basename -- "$(readlink -f "${BASH_SOURCE}")")
export SCRIPT_PARENT=$(dirname "${SCRIPT_DIR}")

source "${SCRIPT_DIR}/lib/validate_snap_name.sh"
source "${SCRIPT_DIR}/lib/is_btrfs_subvolume.sh"
source "${SCRIPT_DIR}/lib/is_btrfs_subvol_readonly.sh"

SRC_DIR_SNAPSHOTS="${1}"
# /.snapshots/@var-lib-machines-dmz-db
DST_DIR_SNAPSHOTS="${2}"
# /media/snapshots/@var-lib-machines-dmz-db

function main {
	
	if [ "${UID}" -ne 0 ]; then
		echo "<3>ERROR: This script must be run as root!"
		exit 1
	fi

	if [[ -z ${SRC_DIR_SNAPSHOTS} ]]; then
		echo "<3>ERROR: argument missing: SRC_DIR_SNAPSHOTS!"
		exit 1
	fi

	if [[ -z ${DST_DIR_SNAPSHOTS} ]]; then
		echo "<3>ERROR: argument missing: DST_DIR_SNAPSHOTS!"
		exit 1
	fi

	local src_snaps_path_dirname=$(basename "${SRC_DIR_SNAPSHOTS}")
	local dst_snaps_path_dirname=$(basename "${DST_DIR_SNAPSHOTS}")

	# ensure src and dst have the same basename
	if [[ "${src_snaps_path_dirname}" != "${dst_snaps_path_dirname}" ]]; then
		echo "<3>ERROR: source and destination directories must carry the same name! Instead we have src: ${src_snaps_path_dirname} and dst: ${dst_snaps_path_dirname}."
		exit 1
	fi

	# ensure dest dir exists
	if [[ ! -e ${DST_DIR_SNAPSHOTS} ]]; then
		echo "<4>WARN: ${DST_DIR_SNAPSHOTS} does not exist. Mkdir ..."
		mkdir -p "${DST_DIR_SNAPSHOTS}"	
	fi
	# ensure dest dir is writable
	if [[ ! -w ${DST_DIR_SNAPSHOTS} ]]; then
		echo "<3>ERROR: ${DST_DIR_SNAPSHOTS} not writable!"
		exit 1
	fi
	
	shopt -s nullglob
	local src_snaps=("${SRC_DIR_SNAPSHOTS}/"*)
	local dst_snaps=("${DST_DIR_SNAPSHOTS}/"*)
	shopt -u nullglob

	if [[ ${#src_snaps[@]} -eq 0 ]]; then
		echo "<3>ERROR: No snapshots found at: ${SRC_DIR_SNAPSHOTS}"
		exit 1
	fi

	# validate dst snap names
	for snap in "${dst_snaps[@]}"; do
		local name=$(basename "${snap}")
		validate_snap_name "${name}"
		if [[ ! ${?} -eq 0 ]]; then
			echo "<3>ERROR: Invalid snapshot name format: ${name}. Skipping."
			exit 1
		fi
	done

	# Sort snapshots to ensure we process them in order
	# Using 'readarray' ensures we handle spaces in paths correctly
	readarray -t sorted_src_snaps < <(printf "%s\n" "${src_snaps[@]}" | sort)
	# /.snapshots/@var-lib-machines-dmz-db/2025-11-29-152640
	# /.snapshots/@var-lib-machines-dmz-db/2025-12-16-040002
	# /.snapshots/@var-lib-machines-dmz-db/2025-12-17-154540
	# /.snapshots/@var-lib-machines-dmz-db/2025-12-18-040013
	# /.snapshots/@var-lib-machines-dmz-db/2025-12-19-040024
	
	local prev_snap_path=""

	# loop through src snaps
	for snap_path in "${sorted_src_snaps[@]}"; do
		# the first in the loop is cronologically the first
		# the last in the loop is cronologically the last

		local snap_name=$(basename "${snap_path}")
		local prev_snap_name=$(basename "${prev_snap_path}")

		echo "<6>Checking snapshot: ${snap_name}"
		
		# validate subvol
		if ! is_btrfs_subvolume "${snap_path}"; then
			echo "<3>ERROR: Not a btrfs subvolume: ${snap_name}! Skipping."
			continue
		fi

		if ! is_btrfs_subvol_readonly "${snap_path}"; then
            echo "<3>ERROR: Subvolume ${snap_path} is READ-WRITE. Btrfs send requires Read-Only. Skipping."
            continue
        fi
		
		# validate snap_name
		validate_snap_name "${snap_name}"
		if [[ ! ${?} -eq 0 ]]; then
			echo "<3>ERROR: Invalid snapshot name format: ${snap_name}. Skipping."
			continue
		fi
		
		# If it already exists on destination, we skip sending, 
		# but we MUST update prev_snap_path so the next one can use it as a parent.
		if [[ -e "${DST_DIR_SNAPSHOTS}/${snap_name}" ]]; then
			echo "<6>Already present at destination: ${snap_name}"
			prev_snap_path="${snap_path}"
			continue
		fi

		# BACKUP LOGIC
		if [[ -z "${prev_snap_path}" ]]; then
			# Case B: Full Backup
			# first snapshot (cronologically)
			# has not been transferred yet
			echo "<6>No previous parent available. Performing full backup: ${snap_name}"
			btrfs send "${snap_path}" | btrfs receive "${DST_DIR_SNAPSHOTS}"

			if [[ ${?} -eq 0 ]]; then
				echo "<6>Successfully performed full backup of ${snap_name}"
			else
                echo "<3>ERROR: Full backup failed for ${snap_name}. Cleaning up..."
                btrfs subvolume delete "${DST_DIR_SNAPSHOTS}/${snap_name}" 2>/dev/null
                exit 1
            fi
		else
			# Case B: We have a parent (Incremental Backup)
			echo "<6>Performing incremental backup: ${snap_name} (parent: ${prev_snap_name})"
			
			# We use -p with the LOCAL path of the previous snapshot. 
			# Btrfs will find the matching subvolume on the destination using UUIDs.
			btrfs send -p "${prev_snap_path}" "${snap_path}" | btrfs receive "${DST_DIR_SNAPSHOTS}"
			if [[ ${?} -eq 0 ]]; then
				echo "<6>Successfully performed incremental backup of ${snap_name} with parent ${prev_snap_name}"
			else
                echo "<3>ERROR: Incremental backup failed for ${snap_name} with parent ${prev_snap_name}. Cleaning up..."
                btrfs subvolume delete "${DST_DIR_SNAPSHOTS}/${snap_name}" 2>/dev/null
                exit 1
            fi
		fi

		# Update prev_snap_path to the current one for the next iteration
		prev_snap_path="${snap_path}"

	done

	echo "Backup completed successfully."

}

main