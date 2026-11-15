# Refuses to switch to a system that would not start, or that would copy all
# of something, delete something or bring old data back at its next boot.
# What is kept is mounted when the system starts, so the initrd changes it at
# the next boot, and this runs before that, while the user can still decide.

# Where the built program finds common.nu, which is not next to it. Here,
# nushell finds it next to this file first.
const NU_LIB_DIRS = [r#'{{{lib}}}'#]
use common.nu *

const main_label = "the new system"

def main [incoming: string, action: string] {
  let live = $action in ["switch" "test"]
  let running = (read-record $running_system)
  let systems = (incoming-systems $incoming)
  let enabled = ($systems | where record != null)

  if ($enabled | is-empty) {
    if $running != null {
      refuse [(turned-off $main_label)]
    }
    return
  }
  refuse (
    ($systems | where record == null | each { |system| turned-off $system.label }) ++
    (disagreements $enabled)
  )

  if $running == null {
    if not (is-mount-point $persist_mount) {
      refuse [(
        "this system does not run on Stolon, so it would start without the " +
        "disk layout of the new one. Install the machine with the installer " +
        "instead."
      )]
    }
    if $live {
      refuse [(
        "the running system was built with an older Stolon, which does not " +
        "record what it keeps, so what is kept can only change at boot. Run " +
        "nixos-rebuild boot and restart, once."
      )]
    }
    return
  }

  refuse ($enabled | each { |system| locked $running $system } | flatten)

  let compared = (
    $enabled | each { |system|
      $system | insert change (compare $running $system.record)
    }
  )
  let main_change = ($compared | first | get change)
  if $live and not (unchanged $main_change) {
    refuse [([
      "what is kept changes, and that can only happen at boot:"
      (describe $main_change)
      "Run nixos-rebuild boot and restart instead."
    ] | str join "\n")]
  }

  let findings = if ($compared | all { |system| unchanged $system.change }) {
    []
  } else {
    with-top { |top|
      $compared | each { |system| findings $top $running $system } | flatten
    }
  }
  refuse (
    $findings | where { |found| $found.refused } | each { |found| $found.message }
  )

  for system in $compared {
    if not (unchanged $system.change) {
      let heading = if $system.label == $main_label {
        "what is kept changes at the next boot:"
      } else {
        $"what ($system.label) keeps changes when it boots:"
      }
      print --stderr $"stolon: ($heading)\n(describe $system.change)"
    }
  }
  for found in ($findings | where { |found| not $found.refused }) {
    print --stderr $"stolon: ($found.message)"
  }
  if ($compared | any { |system| ($system.change.removed | is-not-empty) }) {
    print --stderr (
      "stolon: what is no longer kept stays on the disk. stolon-stale lists " +
      "it and deletes it."
    )
  }
  if ($enabled | first | get record.bootSize) != $running.bootSize {
    print --stderr "stolon: stolon.bootSize changes at the next install."
  }
}

# The new system and its specialisations, which the boot menu can start
# without a check.
def incoming-systems [incoming: string] {
  let folder = ($incoming | path join "specialisation")
  let specialisations = if ($folder | path exists) {
    entries $folder | each { |name|
      {
        label: $"specialisation ($name)"
        record: (read-record ($folder | path join $name))
      }
    }
  } else {
    []
  }
  [{ label: $main_label, record: (read-record $incoming) }] ++ $specialisations
}

def turned-off [label: string] {
  (
    $"($label) turns Stolon off, so it would start without its disk layout. " +
    "Install the machine again instead, after a backup."
  )
}

# A path kept in different ways breaks when the boot menu starts one system
# after another, and only one encryption and one disk exist.
def disagreements [systems: list] {
  let settings = (
    [
      { key: "encryption", option: "stolon.encryption.enable" }
      { key: "device", option: "stolon.device" }
    ] |
    where { |setting|
      ($systems | each { |system| $system.record | get $setting.key } | uniq | length) > 1
    } |
    each { |setting|
      $"the new system and its specialisations set ($setting.option) differently."
    }
  )

  let ways = (
    $systems | each { |system|
      $system.record.directories ++ $system.record.files | each { |path|
        { path: $path, kind: (kind-of $system.record $path), label: $system.label }
      }
    } | flatten
  )
  let paths = (
    $ways | group-by path | values | where { |rows|
      ($rows | get kind | uniq | length) > 1
    } | each { |rows|
      let kinds = (
        $rows | group-by kind | items { |kind, labelled|
          $"as a ($kind) in ($labelled | get label | str join ', ')"
        } | str join " and "
      )
      (
        $"($rows | first | get path) is kept ($kinds). Starting one after the " +
        "other would break it, so keep it the same way in all of them."
      )
    }
  )
  $settings ++ $paths
}

# Settings that only the installer can change.
def locked [running: record, system: record] {
  let next = $system.record
  [
    (if $next.encryption != $running.encryption {
      let turns = if $next.encryption { "on" } else { "off" }
      (
        $"($system.label) turns encryption ($turns), so it would look for its " +
        "root where it is not and would not start. Install the machine again " +
        "instead, after a backup."
      )
    })
    (if $next.device != $running.device and not (runs-from $next.device) {
      (
        $"($system.label) sets stolon.device to ($next.device), which is not " +
        "the disk this system runs from. The installer erases that disk, so it " +
        "must name this one."
      )
    })
  ] | compact
}

def runs-from [device: string] {
  let partition = $"/dev/disk/by-partlabel/($root_label)"
  if not ((occupied $device) and (occupied $partition)) {
    return false
  }
  let disk = (
    ^lsblk --noheadings --nodeps --paths --output PKNAME $partition | complete
  )
  $disk.exit_code == 0 and (
    ($disk.stdout | str trim) == (^realpath $device | str trim)
  )
}

def is-mount-point [path: string] {
  (^mountpoint --quiet $path | complete).exit_code == 0
}

def kind-of [kept: record, path: string] {
  if $path in $kept.files {
    "file"
  } else if $path in $kept.noCowDirectories {
    "folder for databases and virtual machines"
  } else {
    "normal folder"
  }
}

def compare [running: record, next: record] {
  let before = ($running.directories ++ $running.files)
  let after = ($next.directories ++ $next.files)
  {
    kinds: (
      $after | where $it in $before | each { |path|
        {
          path: $path
          before: (kind-of $running $path)
          after: (kind-of $next $path)
        }
      } | where { |row| $row.before != $row.after }
    )
    added_directories: ($next.directories | where $it not-in $before)
    added_files: ($next.files | where $it not-in $before)
    removed: ($before | where $it not-in $after)
  }
}

def unchanged [change: record] {
  [$change.kinds $change.added_directories $change.added_files $change.removed] |
  all { |paths| $paths | is-empty }
}

def describe [change: record] {
  (
    ($change.added_directories ++ $change.added_files | each { |path|
      $"  newly kept: ($path)"
    }) ++
    ($change.removed | each { |path| $"  no longer kept: ($path)" }) ++
    ($change.kinds | each { |row|
      $"  kept as a ($row.after) instead of a ($row.before): ($row.path)"
    })
  ) | str join "\n"
}

def findings [top: string, running: record, system: record] {
  let next = $system.record
  let change = $system.change
  let removed_directories = (
    $change.removed | where $it in $running.directories
  )
  let found = (
    ($change.kinds | each { |row| kind-changes $row }) ++
    ($change.added_directories | each { |path|
      added-directory $top $running $next $path
    } | flatten) ++
    ($change.added_files | each { |path|
      added-file $running $next $path
    } | flatten) ++
    ($removed_directories | each { |path|
      removed-directory $top $running $next $path
    } | flatten)
  )
  if $system.label == $main_label {
    $found
  } else {
    $found | each { |item|
      $item | update message $"($system.label): ($item.message)"
    }
  }
}

def refused [message: string] {
  { refused: true, message: $message }
}

def note [message: string] {
  { refused: false, message: $message }
}

def kind-changes [row: record] {
  let steps = if $row.before == "file" {
    $"move ($persist_mount)($row.path) out of the way"
  } else {
    "copy out what you need and delete its subvolume with stolon-stale"
  }
  refused (
    $"($row.path) changes from a kept ($row.before) to a kept ($row.after), " +
    "and a path cannot change its kind in place. Stop keeping it and " +
    $"restart, then ($steps), and keep it again."
  )
}

def added-directory [
  top: string
  running: record
  next: record
  path: string
] {
  let places = [$path $"($persist_mount)($path)"]
  let in_the_way = (
    $places | where { |place| (occupied $place) and not (is-folder $place) }
  )
  if ($in_the_way | is-not-empty) {
    return ($in_the_way | each { |place|
      refused (
        $"($path) is newly kept as a folder, but ($place) is not a folder. " +
        "Move it out of the way first."
      )
    })
  }

  let left = (left-behind $running $next $path)
  if $left != null {
    return [$left]
  }

  let kind = (kind-of $next $path)
  let kept = (kept-inside $next $path)
  let has_now = ($places | any { |place| has-content $place $kept })
  let volume = (volume-of $next $path)
  let old_volume = ($top | path join $volume)
  if (occupied $old_volume) {
    let old_no_cow = (is-no-cow $old_volume)
    if $old_no_cow != ($path in $next.noCowDirectories) {
      let old_kind = if $old_no_cow {
        "folder for databases and virtual machines"
      } else {
        "normal folder"
      }
      return [(refused (
        $"($path) is newly kept as a ($kind), but its old subvolume " +
        $"($volume), from when it was kept before, was made for a " +
        $"($old_kind). Copy out what you need, delete the subvolume with " +
        "stolon-stale, and try again."
      ))]
    }
    if $has_now {
      return [(refused (
        $"($path) is newly kept, but its old subvolume ($volume), from when " +
        "it was kept before, is still on the disk, and it would come back in " +
        $"place of what is in ($path) now. Empty ($path), or delete the " +
        "subvolume with stolon-stale, and try again."
      ))]
    }
    return [(note $"($path) comes back with its old subvolume ($volume).")]
  }

  let holder = (holder-of $next.directories $path)
  let holder_kind = if $holder == null { "normal folder" } else {
    kind-of $next $holder
  }
  if $holder_kind != $kind and $has_now {
    return [(refused (
      $"($path) is newly kept as a ($kind), but what is in it now sits in a " +
      $"($holder_kind), so the boot would have to copy all of it. Move what " +
      $"is in ($path) out, restart, and move it back in."
    ))]
  }

  if $holder == null {
    let old_copy = $"($persist_mount)($path)"
    if (has-content $old_copy $kept) {
      if (has-content $path $kept) {
        return [(refused (
          $"($path) is newly kept, but ($old_copy) still holds an old copy " +
          $"from before, which would mix into what is in ($path) now. Move " +
          "one of them out of the way, and try again."
        ))]
      }
      return [(note $"($path) comes back with what is in ($old_copy).")]
    }
  }
  []
}

def added-file [running: record, next: record, path: string] {
  let places = [$path $"($persist_mount)($path)"]
  let in_the_way = (
    $places | where { |place| (occupied $place) and not (is-plain-file $place) }
  )
  if ($in_the_way | is-not-empty) {
    return ($in_the_way | each { |place|
      refused (
        $"($path) is newly kept as a file, but ($place) is not a plain file. " +
        "Move it out of the way first."
      )
    })
  }

  let left = (left-behind $running $next $path)
  if $left != null {
    return [$left]
  }

  let old_copy = $"($persist_mount)($path)"
  let unheld = (
    (holder-of $running.directories $path) == null and
    (holder-of $next.directories $path) == null
  )
  if $unheld and (occupied $old_copy) {
    if (occupied $path) {
      return [(refused (
        $"($path) is newly kept, but ($old_copy) still holds an old copy " +
        $"from before, which would come back in place of ($path). Delete one " +
        "of them, and try again."
      ))]
    }
    return [(note $"($path) comes back from ($old_copy).")]
  }
  []
}

# The boot takes what a newly kept path holds from where the new system has
# it, so when the kept folder that holds it now stops being kept, it would
# be left behind there.
def left-behind [running: record, next: record, path: string] {
  let holder = (holder-of $running.directories $path)
  if $holder == null or $holder in $next.directories {
    return null
  }
  refused (
    $"($path) is newly kept while ($holder) above it stops being kept, so " +
    $"what is in ($path) now would be left behind. Keep ($path) first and " +
    $"restart, then stop keeping ($holder)."
  )
}

# A folder inside another kept folder that stops being kept on its own would
# leave a hole there: what is in it now would disappear, and what was there
# before it was kept on its own would show up instead.
def removed-directory [
  top: string
  running: record
  next: record
  path: string
] {
  let holder = (holder-of $next.directories $path)
  if $holder == null {
    return []
  }

  let kept = (kept-inside $next $path)
  let has_now = (has-content $"($persist_mount)($path)" $kept)
  let lasting = (
    holder-of ($running.directories | where $it in $next.directories) $path
  )
  let old_copy = (place-of $running $lasting $path)
  let old_place = ($top | path join $old_copy)
  let has_old = (
    (without-links $old_place) and (has-content $old_place $kept)
  )
  if not ($has_now or $has_old) {
    return []
  }

  let what = (
    [
      (if $has_now { $"what is in it now would disappear from ($holder)" })
      (if $has_old {
        $"an old copy from before it was kept on its own would show up there"
      })
    ] | compact | str join ", and "
  )
  let steps = (
    [
      (if $has_now { $"move what you need out of ($path)" })
      (if $has_old { $"delete the old copy ($old_copy) with stolon-stale" })
    ] | compact | str join ", "
  )
  [(refused (
    $"($path) is no longer kept on its own, but ($holder) above it still is, " +
    $"so ($what). First ($steps), and try again."
  ))]
}

def is-no-cow [path: string] {
  ^lsattr -d $path | split row " " | first | str contains "C"
}

def refuse [problems: list<string>] {
  if ($problems | is-empty) {
    return
  }
  print --stderr ($problems | each { |problem| $"stolon: ($problem)" } | str join "\n")
  exit 1
}
