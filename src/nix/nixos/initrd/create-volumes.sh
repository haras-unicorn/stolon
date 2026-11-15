root_device='{{{rootDevice}}}'
root_subvolume='{{{rootSubvolume}}}'
persist='{{{persist}}}'
staging='{{{staging}}}'
btrfs='{{{btrfs}}}'
chattr='{{{chattr}}}'

top=/stolon-volumes
mkdir -p "$top"
# subvol=/ is the top of the filesystem, where every subvolume shows up.
mount -o subvol=/ "$root_device" "$top"
trap 'umount "$top"' EXIT

# A path that goes through a link could point anywhere, even outside of the
# filesystem, so nothing is copied from or to it.
through_link() {
  [ "$(realpath -m "$1")" != "$1" ]
}

# Within one kind of volume, a reflink shares the data instead of writing it
# again. Nothing is deleted from where it is copied, so a generation that
# still uses the old place finds it there.
copy_into() {
  source="$top/$2"
  if through_link "$source"; then
    echo "stolon: $2 goes through a link, so it is not copied" >&2
  elif [ -d "$source" ]; then
    cp -a --reflink=auto "$source/." "$1/"
  fi
}

# A volume is made in the staging folder and renamed into place once it is
# whole, so a boot that stops halfway leaves no volume that looks finished.
# What such a boot left there is only ever a half-made copy.
mkdir -p "$top/$staging"
for leftover in "$top/$staging"/*; do
  if [ -e "$leftover" ]; then
    "$btrfs" subvolume delete --recursive "$leftover"
  fi
done

while IFS=$'\t' read -r name holder within no_cow; do
  if [ -z "$name" ] || [ -e "$top/$name" ]; then
    continue
  fi

  new="$top/$staging/$name"
  "$btrfs" subvolume create "$new"
  if [ "$no_cow" = true ]; then
    "$chattr" +C "$new"
  fi
  # Under a kept folder, the root only holds empty places where it is bound.
  if [ "$holder" = "$persist" ]; then
    copy_into "$new" "$root_subvolume/$within"
  fi
  copy_into "$new" "$holder/$within"
  mv "$new" "$top/$name"
done <<'VOLUMES'
{{{volumes}}}
VOLUMES

rmdir "$top/$staging"

while IFS=$'\t' read -r path holder within; do
  target="$top/$holder/$within"
  source="$top/$root_subvolume$path"
  if [ -z "$path" ] || [ -e "$target" ] || [ -L "$target" ]; then
    continue
  fi
  if through_link "$source" || [ ! -f "$source" ]; then
    continue
  fi

  parent="$(dirname "$target")"
  if through_link "$parent"; then
    echo "stolon: $holder/$within goes through a link, so $path is not copied" >&2
    continue
  fi
  mkdir -p "$parent"
  cp -a --reflink=auto "$source" "$target"
done <<'FILES'
{{{files}}}
FILES
