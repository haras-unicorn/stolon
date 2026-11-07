root_device='{{{rootDevice}}}'
root_subvolume='{{{rootSubvolume}}}'
btrfs='{{{btrfs}}}'

mkdir /btrfs
# subvol=/ is the top of the filesystem, where every subvolume shows up.
mount -o subvol=/ "$root_device" /btrfs
trap 'umount /btrfs' EXIT
if [ -e "/btrfs/$root_subvolume" ]; then
  "$btrfs" subvolume delete --recursive "/btrfs/$root_subvolume"
fi
"$btrfs" subvolume create "/btrfs/$root_subvolume"
