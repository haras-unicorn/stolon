const program = r#'{{{program}}}'#

# Linux follows at most this many links while it resolves a path, and a
# migration follows the links of an old system the same way.
const max_links = 40

def fail [message: string] {
  error make --unspanned { msg: $"($program): ($message)" }
}

def run [command: string, arguments: list<string>] {
  ^$command ...$arguments
  if $env.LAST_EXIT_CODE != 0 {
    fail $"($command) failed"
  }
}

def capture [command: string, arguments: list<string>] {
  let result = (^$command ...$arguments | complete)
  if $result.exit_code != 0 {
    fail $"($command) failed: ($result.stderr | str trim)"
  }
  $result.stdout
}

def quietly [command: string, arguments: list<string>] {
  ^$command ...$arguments | complete | ignore
}

# Nushell's input waits for a terminal, so answers that are piped in are read
# all at once beforehand, and picked by position.
def ask [prompt: string, piped, position: int] {
  if $piped == null {
    let answer = (input --suppress-output $prompt)
    print --stderr ""
    $answer
  } else if ($piped | length) > $position {
    $piped | get $position
  } else {
    fail $"no answer for: ($prompt)"
  }
}

def is-block-device [path: string] {
  (^test -b $path | complete).exit_code == 0
}

def partitions [target: string] {
  capture lsblk ["--json" "--paths" "--output" "NAME,PARTLABEL,FSTYPE" $target] |
  from json |
  get blockdevices |
  first |
  get --optional children |
  default []
}

def labels [found: list] {
  $found | each { |partition|
    let label = ($partition.partlabel | default "")
    let filesystem = ($partition.fstype | default "")
    $"($label):($filesystem)"
  } | sort
}

def open-target [settings: record, target: string, root_partition: string, piped] {
  if not $settings.encrypted {
    return $root_partition
  }

  let passphrase = (ask $"Passphrase of ($target): " $piped 0)
  let result = (
    $passphrase |
    ^cryptsetup open --key-file=- $root_partition $settings.mapper |
    complete
  )
  if $result.exit_code != 0 {
    fail $"could not open ($target): ($result.stderr | str trim)"
  }
  $"/dev/mapper/($settings.mapper)"
}

def cleanup [settings: record] {
  # A migration mounts the old system inside the target mount.
  quietly umount ["--recursive" $settings.target_mount]
  quietly umount [$settings.repository_mount]
  if $settings.encrypted {
    quietly cryptsetup ["close" $settings.mapper]
  }
}

def drive-id [target: string] {
  let serial = (
    capture lsblk ["--nodeps" "--noheadings" "--output" "SERIAL" $target] |
    str replace --all " " "" |
    str trim
  )
  if not ($serial | is-empty) {
    return $serial
  }

  capture lsblk ["--nodeps" "--noheadings" "--output" "WWN" $target] |
  str replace --all " " "" |
  str trim
}

# The name of a backup: what it was made from, the configuration and the day.
def backup-tag [settings: record, origin: string] {
  let day = (date now | format date "%F")
  $"($origin)-($settings.host_name)-($day)"
}

def backup [
  settings: record,
  repository: string,
  password: string,
  piped,
  repeat_position: int,
  tag: string,
] {
  if not ($"($repository)/config" | path exists) {
    let repeated = (ask "Repeat the backup password: " $piped $repeat_position)
    if $repeated != $password {
      fail "the passwords differ"
    }
    run restic ["init" "--repo" $repository]
  }

  let paths = (
    $settings.volumes | each { |volume| $"($settings.target_mount)/($volume)" }
  )
  run restic (
    [
      "backup"
      "--repo" $repository
      "--host" $settings.host_name
      "--compression" $settings.compression
      "--tag" $tag
    ] ++ $paths
  )
}

def restore [settings: record, repository: string] {
  run restic [
    "restore" "latest"
    "--no-lock"
    "--repo" $repository
    "--host" $settings.host_name
    "--target" "/"
  ]
}

def transfer [
  settings: record,
  target: string,
  backup_partition: string,
  root_partition: string,
  piped,
] {
  let backing_up = $settings.direction == "backup"
  let target_mode = if $backing_up { "ro" } else { "rw" }
  let repository_mode = if $backing_up { "rw" } else { "ro" }

  mkdir $settings.target_mount $settings.repository_mount
  let btrfs_device = (open-target $settings $target $root_partition $piped)
  # subvol=/ is the top of the filesystem, where every subvolume shows up.
  run mount ["-o" $"subvol=/,($target_mode)" $btrfs_device $settings.target_mount]
  run mount ["-o" $repository_mode $backup_partition $settings.repository_mount]

  for volume in $settings.volumes {
    if ($"($settings.target_mount)/($volume)" | path type) != "dir" {
      fail $"($target) has no subvolume ($volume)"
    }
  }

  let tag = if $backing_up {
    let drive_id = (drive-id $target)
    if ($drive_id | is-empty) {
      fail $"($target) reports neither a serial number nor a WWN"
    }
    backup-tag $settings $drive_id
  } else {
    null
  }

  let repository = $"($settings.repository_mount)/($settings.repository_name)"
  let password_position = if $settings.encrypted { 1 } else { 0 }
  let password = (ask "Backup password: " $piped $password_position)
  with-env { RESTIC_PASSWORD: $password } {
    if $backing_up {
      (
        backup $settings $repository $password $piped ($password_position + 1)
          $tag
      )
    } else {
      restore $settings $repository
    }
  }
}

# A backup of an old system, made to look like one of a Stolon disk, so that
# a restore puts it back the same way. Each kept path of the old system is
# mounted where its volume sits at the top of a Stolon disk, inside an empty
# tmpfs, and what the old system does not have stays empty.
def migrate [
  settings: record,
  old_system: string,
  backup_partition: string,
  piped,
] {
  mkdir $settings.target_mount $settings.repository_mount
  run mount ["-t" "tmpfs" "-o" "mode=0755" "tmpfs" $settings.target_mount]
  run mount ["-o" "rw" $backup_partition $settings.repository_mount]
  for volume in $settings.volumes {
    mkdir $"($settings.target_mount)/($volume)"
  }

  let missing = ($settings.migration | each { |entry|
    let source = (resolve-in $old_system $entry.source)
    let destination = $"($settings.target_mount)/($entry.destination)"
    if $source == null or ($source | path type) != $entry.type {
      return $entry.source
    }
    if $entry.type == "file" {
      mkdir ($destination | path dirname)
      touch $destination
    }
    run mount ["-o" "bind,ro" $source $destination]
    null
  } | compact)

  let repository = $"($settings.repository_mount)/($settings.repository_name)"
  let password = (ask "Backup password: " $piped 0)
  with-env { RESTIC_PASSWORD: $password } {
    let tag = (backup-tag $settings "migrated")
    backup $settings $repository $password $piped 1 $tag
  }

  for path in $missing {
    print --stderr (
      $"($program): ($old_system) has no ($path), so it is left empty"
    )
  }
}

# Where a path of the old system really is, following its links the way the
# old system would: an absolute link starts again at the root of the old
# system, and .. never leaves it. Following them from here would end up on
# this system instead. Gives null for a loop of links.
def resolve-in [root: string, path: string] {
  mut resolved = []
  mut pending = ($path | path split | skip 1)
  mut links = 0
  while ($pending | is-not-empty) {
    let part = ($pending | first)
    $pending = ($pending | skip 1)
    if $part == "." {
      continue
    }
    if $part == ".." {
      $resolved = ($resolved | drop 1)
      continue
    }

    let candidate = ($resolved | append $part)
    let full = ([$root ...$candidate] | path join)
    if ($full | path type) != "symlink" {
      $resolved = $candidate
      continue
    }

    $links += 1
    if $links > $max_links {
      return null
    }
    let target = (capture readlink ["--" $full] | str replace --regex '\n$' "")
    let target_parts = ($target | path split)
    if ($target | str starts-with "/") {
      $resolved = []
      $pending = [...($target_parts | skip 1) ...$pending]
    } else {
      $pending = [...$target_parts ...$pending]
    }
  }
  [$root ...$resolved] | path join
}

# Fails unless the disk has the layout of this configuration and is not in
# use, and gives its root partition.
def check-disk [settings: record, target: string] {
  if not (is-block-device $target) {
    fail $"($target) is not a block device"
  }

  # A disk this system runs from has something mounted, and it must not be
  # backed up or restored while it is in use.
  let mounted = (
    capture lsblk ["--noheadings" "--output" "MOUNTPOINTS" $target] | str trim
  )
  if not ($mounted | is-empty) {
    fail $"($target) is in use, so run this from another system, for example a live USB"
  }

  let found = (partitions $target)
  if (labels $found) != ($settings.expected_partitions | sort) {
    fail $"($target) does not have the layout of ($settings.host_name)"
  }
  $found | where partlabel == $settings.root_label | get name | first
}

# Backs up or restores the Stolon disk of this configuration. When migrating,
# it backs up an old system that is mounted at the target instead, as well as
# it can, for a restore onto a new Stolon disk.
def main [
  target: string # The Stolon disk, or the mounted old system when migrating
  backup_partition: string # The partition of the backups
] {
  let settings = {
    direction: r#'{{{direction}}}'#
    host_name: r#'{{{hostName}}}'#
    compression: r#'{{{compression}}}'#
    encrypted: (r#'{{{encrypted}}}'# | from json)
    mapper: r#'{{{mapper}}}'#
    target_mount: r#'{{{targetMount}}}'#
    repository_mount: r#'{{{repositoryMount}}}'#
    repository_name: r#'{{{repositoryName}}}'#
    root_label: r#'{{{rootLabel}}}'#
    expected_partitions: (r#'{{{expectedPartitions}}}'# | from json)
    volumes: (r#'{{{volumes}}}'# | from json)
    migration: (r#'{{{migration}}}'# | from json)
  }
  let migrating = $settings.direction == "migrate"

  if (^id -u | str trim) != "0" {
    fail "run as root"
  }
  if not (is-block-device $backup_partition) {
    fail $"($backup_partition) is not a block device"
  }
  # The old system is mounted by hand, since its layout can be anything, so
  # that is the one thing a migration checks.
  let root_partition = if $migrating {
    if (^mountpoint --quiet $target | complete).exit_code != 0 {
      fail $"nothing is mounted at ($target), so mount the old system there first"
    }
    null
  } else {
    check-disk $settings $target
  }

  let piped = if (is-terminal --stdin) { null } else { ^cat | lines }
  let outcome = (try {
    if $migrating {
      migrate $settings $target $backup_partition $piped
    } else {
      transfer $settings $target $backup_partition $root_partition $piped
    }
    null
  } catch { |err| $err.msg })
  cleanup $settings
  if $outcome != null {
    error make --unspanned { msg: $outcome }
  }
}
