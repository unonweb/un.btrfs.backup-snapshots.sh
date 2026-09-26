function is_btrfs_subvolume { # ${path}
	# must be run as root!
	btrfs subvolume show "${1}" > /dev/null 2>&1
}