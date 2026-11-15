# What both programs need: the record a system keeps of what it keeps, and
# the top of the btrfs filesystem, where every subvolume shows up next to
# the persist volume and the root.

const record = r#'{{{record}}}'#
export const persist_mount = r#'{{{persistMount}}}'#
export const persist = r#'{{{persist}}}'#
export const root_subvolume = r#'{{{rootSubvolume}}}'#
export const nix_subvolume = r#'{{{nixSubvolume}}}'#
export const root_label = r#'{{{rootLabel}}}'#
const root_device = r#'{{{rootDevice}}}'#

export const running_system = "/run/current-system"

# Btrfs numbers the files of each subvolume on their own, and the root folder
# of a subvolume always gets this number. btrfs-progs tells a subvolume apart
# the same way.
const subvolume_inode = "256"

# What the system keeps and how its disk is set up, or null for a system
# without Stolon or with an older one, which records nothing.
export def read-record [system: string] {
  let path = ($system | path join "etc" $record)
  if ($path | path exists) { open $path } else { null }
}

# The deepest kept folder above the path, or null.
export def holder-of [directories: list<string>, path: string] {
  $directories |
  where { |other| $path | str starts-with $"($other)/" } |
  each { |other| { path: $other, length: ($other | str length) } } |
  sort-by length |
  reverse |
  get --optional 0.path
}

export def volume-of [kept: record, path: string] {
  $kept.volumes | where path == $path | get 0.name
}

# Where the path sits at the top of the filesystem, inside the volume of the
# given kept folder above it, or inside the persist volume.
export def place-of [kept: record, holder, path: string] {
  if $holder == null {
    $persist | path join ($path | path relative-to "/")
  } else {
    volume-of $kept $holder | path join ($path | path relative-to $holder)
  }
}

# What is kept below the path, relative to it.
export def kept-inside [kept: record, path: string] {
  $kept.directories ++ $kept.files |
  where { |other| $other | str starts-with $"($path)/" } |
  each { |other| $other | path relative-to $path }
}

# Whether anything is in a folder apart from the given kept paths, as
# loose-in finds it, or whether anything but a folder is there.
export def has-content [folder: string, kept: list<string>] {
  if (is-folder $folder) {
    loose-in $folder $kept | is-not-empty
  } else {
    occupied $folder
  }
}

# What lies in a folder apart from the given kept paths, relative to it, and
# the folders on the way to them, which hold what is kept or where it is
# mounted. It never looks inside what is kept, since all of that is kept too.
export def loose-in [folder: string, kept: list<string>] {
  entries $folder | each { |name|
    let path = ($folder | path join $name)
    let below = (
      $kept |
      where { |other| $other | str starts-with $"($name)/" } |
      each { |other| $other | path relative-to $name }
    )
    if $name in $kept {
      []
    } else if ($below | is-not-empty) and (is-folder $path) {
      loose-in $path $below | each { |inner| $name | path join $inner }
    } else {
      [$name]
    }
  } | flatten
}

export def entries [folder: string] {
  ls --all --short-names $folder | each { |entry| $entry.name }
}

# Whether the path goes through no link, which could point anywhere.
export def without-links [path: string] {
  (^realpath --canonicalize-missing $path | str trim) == $path
}

export def occupied [path: string] {
  (test-path "-e" $path) or (test-path "-L" $path)
}

export def is-folder [path: string] {
  (test-path "-d" $path) and not (test-path "-L" $path)
}

export def is-plain-file [path: string] {
  (test-path "-f" $path) and not (test-path "-L" $path)
}

export def is-subvolume [path: string] {
  (is-folder $path) and (^stat --format "%i" $path | str trim) == $subvolume_inode
}

export def test-path [flag: string, path: string] {
  (^test $flag $path | complete).exit_code == 0
}

# Mounts the top of the filesystem for the closure, and unmounts it after,
# even when the closure fails.
export def with-top [action: closure, --writable] {
  let mode = if $writable { "rw" } else { "ro" }
  let top = (capture mktemp ["--directory" "/run/stolon.XXXXXX"] | str trim)
  capture mount ["-o" $"subvol=/,($mode)" $root_device $top]
  let outcome = (try {
    { value: (do $action $top) }
  } catch { |error|
    { error: $error.msg }
  })
  capture umount [$top]
  capture rmdir [$top]
  if $outcome.error? != null {
    error make --unspanned { msg: $outcome.error }
  }
  $outcome.value
}

export def capture [command: string, arguments: list<string>] {
  let result = (^$command ...$arguments | complete)
  if $result.exit_code != 0 {
    error make --unspanned {
      msg: $"($command) failed: ($result.stderr | str trim)"
    }
  }
  $result.stdout
}
