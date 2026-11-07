const program = r#'{{{program}}}'#

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
  quietly umount [$settings.target_mount]
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

def backup [
  settings: record,
  target: string,
  repository: string,
  password: string,
  piped,
  repeat_position: int,
] {
  if not ($"($repository)/config" | path exists) {
    let repeated = (ask "Repeat the backup password: " $piped $repeat_position)
    if $repeated != $password {
      fail "the passwords differ"
    }
    run restic ["init" "--repo" $repository]
  }

  let drive_id = (drive-id $target)
  if ($drive_id | is-empty) {
    fail $"($target) reports neither a serial number nor a WWN"
  }

  let day = (date now | format date "%F")
  let tag = $"($drive_id)-($settings.host_name)-($day)"
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

  let repository = $"($settings.repository_mount)/($settings.repository_name)"
  let password_position = if $settings.encrypted { 1 } else { 0 }
  let password = (ask "Backup password: " $piped $password_position)
  with-env { RESTIC_PASSWORD: $password } {
    if $backing_up {
      backup $settings $target $repository $password $piped ($password_position + 1)
    } else {
      restore $settings $repository
    }
  }
}

def main [target: string, backup_partition: string] {
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
  }

  if (^id -u | str trim) != "0" {
    fail "run as root"
  }
  for device in [$target $backup_partition] {
    if not (is-block-device $device) {
      fail $"($device) is not a block device"
    }
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
  let root_partition = (
    $found | where partlabel == $settings.root_label | get name | first
  )

  let piped = if (is-terminal --stdin) { null } else { ^cat | lines }
  let outcome = (try {
    transfer $settings $target $backup_partition $root_partition $piped
    null
  } catch { |err| $err.msg })
  cleanup $settings
  if $outcome != null {
    error make --unspanned { msg: $outcome }
  }
}
