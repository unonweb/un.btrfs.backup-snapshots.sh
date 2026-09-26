function is_btrfs_subvol_readonly { # ${path}
    # Returns 0 if subvolume is readonly, 1 otherwise
    local path="${1}"
    if [[ "$(btrfs property get -ts "${path}" ro)" == "ro=true" ]]; then
        return 0
    else
        return 1
    fi
}