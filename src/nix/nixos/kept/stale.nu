# Lists and deletes what is stale at the top of the btrfs filesystem: what
# the running system neither mounts nor binds, like the subvolume of a folder
# that is no longer kept, or the old copy a folder leaves behind when it gets
# its own subvolume. Stolon never deletes these on its own, since a
# generation you roll back to may still need them, so this asks first.
#
# With a command, it does one task. Without one, it is a menu that asks what
# to delete and then runs the same command.

# Where the built program finds common.nu, which is not next to it. Here,
# nushell finds it next to this file first.
const NU_LIB_DIRS = [r#'{{{lib}}}'#]
use common.nu *

const warning = (
  "Deleting is for good. A generation you roll back to, or a specialisation " +
  "you start, may still need what you delete, and would start without it, " +
  "or not at all."
)

# -----------------------------------------------------------------------------
# TUI
#
# The menu. It asks what to delete and calls the commands of the CLI below,
# and holds no logic of its own.
# -----------------------------------------------------------------------------

# Picks what to delete from what is stale.
def main [] {
  require-root
  let stale = (with-top { |top| find-stale $top (running-kept) | sized $top })
  if ($stale | is-empty) {
    print "Nothing is stale."
    return
  }

  let choices = ($stale | each { |entry|
    $entry | insert label $"($entry.name) \(($entry.what), ($entry.size)\)"
  })
  let picked = (
    ext-pick "What should be deleted? Space picks, Enter goes on." (
      $choices | get label
    )
  )
  if ($picked | is-empty) {
    return
  }

  print $"(ansi red_bold)($warning)(ansi reset)"
  if not (ext-confirm "Delete them for good?") {
    return
  }
  let names = ($choices | where label in $picked | get name)
  main delete ...$names --yes-lose-data
}

# -----------------------------------------------------------------------------
# CLI
#
# The commands, with all the logic.
# -----------------------------------------------------------------------------

# Lists what the running system neither mounts nor binds.
def "main list" [] {
  require-root
  with-top { |top| find-stale $top (running-kept) | sized $top } | for-output
}

# Deletes what is stale, by the names that list shows.
def "main delete" [
  ...names: string # What to delete, as list shows it
  --yes-lose-data # Delete it for good
] {
  require-root
  if not $yes_lose_data {
    fail $"($warning) Add --yes-lose-data if you are sure."
  }
  with-top --writable { |top|
    let stale = (find-stale $top (running-kept))
    let unknown = ($names | where $it not-in ($stale | each { |entry| $entry.name }))
    if ($unknown | is-not-empty) {
      fail $"Not stale: ($unknown | str join ', '). The list command shows what is."
    }
    for entry in ($stale | where name in $names) {
      ext-delete $top $entry
    }
  }
}

def running-kept [] {
  let kept = (read-record $running_system)
  if $kept == null {
    fail (
      "The running system does not record what it keeps. Restart into a " +
      "system with this version of Stolon first."
    )
  }
  $kept
}

# Subvolumes that are not mounted, old copies hidden under where a kept
# folder is mounted, and what lies in the persist volume beside what is kept.
def find-stale [top: string, kept: record] {
  let used = (
    [$root_subvolume $nix_subvolume $persist] ++
    ($kept.volumes | each { |volume| $volume.name })
  )
  let unmounted = (
    entries $top | where $it not-in $used | each { |name|
      { name: $name, what: (what-is ($top | path join $name)) }
    }
  )

  let hidden = (
    $kept.directories | each { |path|
      let name = (place-of $kept (holder-of $kept.directories $path) $path)
      let place = ($top | path join $name)
      if (without-links $place) and (has-content $place []) {
        { name: $name, what: "old copy" }
      }
    } | compact
  )

  let in_persist = (
    $kept.directories ++ $kept.files |
    where { |path| (holder-of $kept.directories $path) == null } |
    each { |path| $path | path relative-to "/" }
  )
  let loose = (
    loose-in ($top | path join $persist) $in_persist | each { |path|
      let name = ($persist | path join $path)
      { name: $name, what: (what-is ($top | path join $name)) }
    }
  )

  $unmounted ++ $hidden ++ $loose
}

def what-is [path: string] {
  if (is-subvolume $path) {
    "subvolume"
  } else if (is-folder $path) {
    "folder"
  } else if (test-path "-L" $path) {
    "link"
  } else {
    "file"
  }
}

def sized [top: string] {
  $in | each { |entry|
    $entry | insert size (ext-size ($top | path join $entry.name))
  }
}

# A table needs the width of the terminal, and scripts read JSON better.
def for-output [] {
  if (is-terminal --stdout) { $in } else { $in | to json }
}

def require-root [] {
  if not (is-admin) {
    fail "Run this as root: put sudo in front of the command."
  }
}

def fail [message: string] {
  error make --unspanned { msg: $message }
}

# -----------------------------------------------------------------------------
# EXT
#
# Everything that touches this computer, apart from the mount of the top of
# the filesystem, which both programs share.
# -----------------------------------------------------------------------------

def ext-size [path: string] {
  capture du ["--summarize" "--bytes" $path] |
  split row "\t" |
  first |
  into int |
  into filesize
}

# An old copy is the content of a folder where a kept folder is mounted, so
# the folder itself stays.
def ext-delete [top: string, entry: record] {
  let path = ($top | path join $entry.name)
  let targets = if $entry.what == "old copy" {
    entries $path | each { |name| $path | path join $name }
  } else {
    [$path]
  }
  for target in $targets {
    if (is-subvolume $target) {
      capture btrfs ["subvolume" "delete" "--recursive" $target] | ignore
    } else {
      capture rm ["--recursive" "--force" "--" $target] | ignore
    }
  }
  print $"Deleted ($entry.name)"
}

# Esc gives nothing.
def ext-pick [header: string, choices: list<string>] {
  try {
    ^gum choose --no-limit --header $header ...$choices | lines
  } catch {
    []
  }
}

def ext-confirm [prompt: string] {
  try {
    ^gum confirm $prompt
    true
  } catch {
    false
  }
}
