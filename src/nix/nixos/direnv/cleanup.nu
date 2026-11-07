def last-head-move [project: string] {
  let result = (
    ^git -c "safe.directory=*" -C $project log --walk-reflogs --date=unix --max-count=1 --format=%gd HEAD |
    complete
  )
  if $result.exit_code != 0 {
    return null
  }

  let moves = ($result.stdout | parse --regex '@\{(?P<seconds>\d+)\}')
  if ($moves | is-empty) {
    return null
  }

  $moves | first | get seconds | into int
}

def main [] {
  let retention_days = (r#'{{{retentionDays}}}'# | from json)
  let seconds_per_day = 86400
  let now = (date now | format date "%s" | into int)
  let cutoff = $now - $retention_days * $seconds_per_day

  let printed = (^nix-store --gc --print-roots | complete)
  if $printed.exit_code != 0 {
    error make --unspanned {
      msg: $"nix-store failed: ($printed.stderr | str trim)"
    }
  }
  let links = (
    $printed.stdout |
    lines |
    parse "{link} -> {path}" |
    get link |
    each { |link| $link | str trim --char '"' } |
    uniq |
    where { |link| $link | str contains "/.direnv/" }
  )

  for link in $links {
    let project = ($link | split row "/.direnv/" | first)
    if not ($"($project)/.git" | path exists) {
      continue
    }

    let moved = (last-head-move $project)
    if $moved == null {
      continue
    }

    if $moved < $cutoff {
      print $"removing the gcroot of ($project)"
      rm --force $link
    }
  }
}
