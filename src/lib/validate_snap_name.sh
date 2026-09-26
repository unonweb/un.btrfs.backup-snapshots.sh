function validate_snap_name { # ${name}

    local snapshot_name="${1}"

    if [[ ! "${snapshot_name}" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}-[0-9]{6}$ ]]; then
        return 1
    else
		return 0
	fi
}