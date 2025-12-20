#!/bin/bash

set -o pipefail
shopt -s nullglob

function validate_snap_name { # ${name}

    local snapshot_name="${1}"

    if [[ ! "${snapshot_name}" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}-[0-9]{6}$ ]]; then
        return 1
    else
		return 0
	fi
}

function is_btrfs_subvolume { # ${path}
	# must be run as root!
	btrfs subvolume show "${1}" > /dev/null 2>&1
}

function is_readonly { # ${path}
    # Returns 0 if subvolume is readonly, 1 otherwise
    local path="${1}"
    if [[ "$(btrfs property get -ts "${path}" ro)" == "ro=true" ]]; then
        return 0
    else
        return 1
    fi
}

function main { # ${src_snaps_path} ${dst_snaps_path}
	
	if [ "${UID}" -ne 0 ]; then
		echo "<3>ERROR: This script must be run as root!"
		exit 1
	fi

	local src_snaps_path="${1}" # /.snapshots/@var-lib-machines-dmz-db
	local dst_snaps_path="${2}" # /media/snapshots/@var-lib-machines-dmz-db

	if [[ -z ${src_snaps_path} ]]; then
		echo "<3>ERROR: argument missing: src_snaps_path!"
		exit 1
	fi

	if [[ -z ${dst_snaps_path} ]]; then
		echo "<3>ERROR: argument missing: dst_snaps_path!"
		exit 1
	fi

	local src_snaps_path_dirname=$(basename "${src_snaps_path}")
	local dst_snaps_path_dirname=$(basename "${dst_snaps_path}")

	# ensure src and dst have the same basename
	if [[ "${src_snaps_path_dirname}" != "${dst_snaps_path_dirname}" ]]; then
		echo "<3>ERROR: source and destination directories must carry the same name! Instead we have src: ${src_snaps_path_dirname} and dst: ${dst_snaps_path_dirname}."
		exit 1
	fi

	# ensure dest dir exists
	if [[ ! -e ${dst_snaps_path} ]]; then
		echo "<4>WARN: ${dst_snaps_path} does not exist. Mkdir ..."
		mkdir -p "${dst_snaps_path}"	
	fi
	# ensure dest dir is writable
	if [[ ! -w ${dst_snaps_path} ]]; then
		echo "<3>ERROR: ${dst_snaps_path} not writable!"
		exit 1
	fi
	
	local src_snaps=("${src_snaps_path}/"*)
	local dst_snaps=("${dst_snaps_path}/"*)

	if [[ ${#src_snaps[@]} -eq 0 ]]; then
		echo "<3>ERROR: No snapshots found at: ${src_snaps_path}"
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
		if ! is_btrfs_subvolume ${snap_path}; then
			echo "<3>ERROR: Not a btrfs subvolume: ${snap_name}! Skipping."
			continue
		fi

		if ! is_readonly "${snap_path}"; then
            echo "<3>ERROR: Subvolume ${snap_name} is READ-WRITE. Btrfs send requires Read-Only. Skipping."
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
		if [[ -e "${dst_snaps_path}/${snap_name}" ]]; then
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
			btrfs send "${snap_path}" | btrfs receive "${dst_snaps_path}"

			if [[ ${?} -eq 0 ]]; then
				echo "<6>Successfully performed full backup of ${snap_name}"
			else
                echo "<3>ERROR: Full backup failed for ${snap_name}. Cleaning up..."
                btrfs subvolume delete "${dst_snaps_path}/${snap_name}" 2>/dev/null
                exit 1
            fi
		else
			# Case B: We have a parent (Incremental Backup)
			echo "<6>Performing incremental backup: ${snap_name} (parent: ${prev_snap_name})"
			
			# We use -p with the LOCAL path of the previous snapshot. 
			# Btrfs will find the matching subvolume on the destination using UUIDs.
			btrfs send -p "${prev_snap_path}" "${snap_path}" | btrfs receive "${dst_snaps_path}"
			if [[ ${?} -eq 0 ]]; then
				echo "<6>Successfully performed incremental backup of ${snap_name} with parent ${prev_snap_name}"
			else
                echo "<3>ERROR: Incremental backup failed for ${snap_name} with parent ${prev_snap_name}. Cleaning up..."
                btrfs subvolume delete "${dst_snaps_path}/${snap_name}" 2>/dev/null
                exit 1
            fi
		fi

		# Update prev_snap_path to the current one for the next iteration
		prev_snap_path="${snap_path}"

	done

	echo "Backup completed successfully."

}

main ${@}