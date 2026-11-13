# The installer of the machines of a flake. With a command, it does one task
# and asks nothing but the passphrases. Without one, it is a menu that asks
# the questions, explains the steps and then runs the same commands. The menu
# holds no logic of its own, so when it breaks, the commands still work.
#
# An offline installer carries the built system and scripts of its one machine,
# and runs them from its own store, so it needs neither the flake nor a
# network.
#
# STOLON_INSTALLER_DRY_RUN=1 changes nothing and only says what it would run.
# STOLON_INSTALLER_FAKE=1 also makes up the drives and the network it finds,
# for trying out the menu on any computer.

let repository = r#'{{{repository}}}'#
let remote_flake_ref = r#'{{{remoteFlakeRef}}}'#
let this_system = r#'{{{system}}}'#
let machine_summaries = r#'{{{machines}}}'# | from json
let offline_builds = r#'{{{offlineBuilds}}}'# | from json
let offline = ($offline_builds | is-not-empty)
let external_mount = r#'{{{externalMount}}}'#
let hardware_reports = r#'{{{hardwareReports}}}'#

# Running for real on made-up drives would change the wrong ones, so a fake run
# is always a dry run too.
let fake = ($env.STOLON_INSTALLER_FAKE? | default r#'{{{fake}}}'#) == "1"
let dry_run = (
  $fake or ($env.STOLON_INSTALLER_DRY_RUN? | default "0") == "1"
)

# The console of the live USB only draws ASCII, so everything the installer
# prints sticks to it, and so do the errors and tables of Nushell.
$env.config.error_style = "plain"
$env.config.table.mode = "basic"

# The machines need flakes, and the binary caches of the flake save hours of
# building. These go after any settings of the user, and add to them.
const nix_config = (
  "extra-experimental-features = nix-command flakes\n" +
  "accept-flake-config = true"
)

# Filesystems that cannot hold a report or a backup: the live USB, and
# partitions that are encrypted or swap.
const unusable_filesystems = ["iso9660" "squashfs" "crypto_LUKS" "swap"]

# How long each binary cache gets to answer before it counts as unreachable.
const cache_timeout_seconds = 5

# gum wraps paragraphs at this width, so they fit an 80 column console.
const text_width = 76
# gum spins braille dots by default, and this one is ASCII.
const spinner = "line"
# The ANSI 256 colors of titles and of warnings.
const title_color = "212"
const warning_color = "196"

# The entries of the menu, which the tasks also name when they say what to
# pick next.
const save_report = (
  "Save this computer's hardware report to the external drive"
)
const back_up = "Back up this computer to the external drive"
const migrate = "Back up a system that does not use stolon yet"
const install = "Install a machine on this computer"
const install_elsewhere = "Install a machine onto a disk for another computer"
const wifi = "Connect to Wi-Fi"
const update = "Get the latest installer"
const restart = "Restart the computer"
const look_around = "Leave the menu and look around myself"

# The Nix settings that a fake run finds.
const fake_nix_settings = {
  substituters: "https://cache.nixos.org/"
  "trusted-substituters": ""
  "extra-platforms": "aarch64-linux i686-linux"
}
# How long a fake run pretends to check a binary cache, so the spinner shows.
const fake_check_seconds = 1

# The drives that a fake run finds, as lsblk lists them: the disk of the fake
# laptop, an external drive and the USB stick of the installer.
const fake_block_devices = [
  {
    name: "/dev/nvme0n1", pkname: null, type: "disk", size: "476.9G",
    fstype: null, label: null, model: "Fake NVMe SSD", tran: "nvme"
  }
  {
    name: "/dev/nvme0n1p1", pkname: "/dev/nvme0n1", type: "part",
    size: "1G", fstype: "vfat", label: null, model: null, tran: null
  }
  {
    name: "/dev/nvme0n1p2", pkname: "/dev/nvme0n1", type: "part",
    size: "475.9G", fstype: "crypto_LUKS", label: null, model: null,
    tran: null
  }
  {
    name: "/dev/sda", pkname: null, type: "disk", size: "931.5G",
    fstype: null, label: null, model: "Fake External Drive", tran: "usb"
  }
  {
    name: "/dev/sda1", pkname: "/dev/sda", type: "part", size: "931.5G",
    fstype: "ext4", label: "backups", model: null, tran: null
  }
  {
    name: "/dev/sdb", pkname: null, type: "disk", size: "14.9G",
    fstype: null, label: null, model: "Fake USB Stick", tran: "usb"
  }
  {
    name: "/dev/sdb1", pkname: "/dev/sdb", type: "part", size: "14.9G",
    fstype: "iso9660", label: "stolon-installer", model: null, tran: null
  }
]

# -----------------------------------------------------------------------------
# TUI
#
# The menu. It asks the questions, explains the steps and calls the commands
# of the CLI below, and holds no logic of its own.
# -----------------------------------------------------------------------------

# The menu. Esc in any of its questions goes back.
def main [] {
  require-root

  say --first "Hi!" (
    "This sets up your machines. Pick what you want to do. Every step says " +
    "what it does and why before it runs, and nothing is erased without " +
    "asking you first."
  ) (
    "In every menu, the arrow keys move, Enter picks and Esc goes back."
  )
  if $fake {
    say --warning "Fake run" (
      "The machines, drives and network are made up, and nothing is " +
      "changed. Every step only says what it would run."
    )
  } else if $dry_run {
    say --warning "Dry run" (
      "Nothing is changed. Every step only says what it would run."
    )
  }
  say-connection

  let wifi_entry = if (ext-has-wifi-tool) { [$wifi] } else { [] }
  let update_entry = if $offline { [] } else { [$update] }
  let entries = [
    $save_report
    $back_up
    $migrate
    $install
    $install_elsewhere
    ...$wifi_entry
    ...$update_entry
    $restart
    $look_around
  ]

  loop {
    let choice = (pick "What do you want to do?" $entries)
    if $choice == $save_report {
      attempt { menu-save-report }
    } else if $choice == $back_up {
      attempt { menu-back-up }
    } else if $choice == $migrate {
      attempt { menu-migrate }
    } else if $choice == $install {
      attempt { menu-install }
    } else if $choice == $install_elsewhere {
      attempt { menu-install --elsewhere }
    } else if $choice == $wifi {
      attempt { menu-wifi }
    } else if $choice == $update {
      attempt { menu-update }
    } else if $choice == $restart {
      attempt { menu-restart }
    } else if $choice == $look_around {
      menu-look-around
      break
    } else {
      break
    }
  }
}

def menu-save-report [] {
  say "Save the hardware report" (
    "The configuration needs to know the hardware of a machine: its disks, " +
    "CPU, GPU and so on. This scans this computer and saves the report on " +
    "the external drive, so you can add it to the flake from another " +
    "computer."
  )

  let name = (
    ask-text "What is this machine called?" "for example laptop"
      --value ((guess-machine) | default "")
  )
  if $name == null or $name == "" {
    return
  }
  let partition = (pick-partition (
    "Which partition of the external drive should the report go on?"
  ))
  if $partition == null {
    return
  }

  main save-report $name $partition

  say "Done" (
    "The report is on the external drive as " +
    $"($hardware_reports)/($name).json."
  ) (
    "Next, on another computer: add it to the flake, then commit and push. " +
    $"After that, come back here and pick: ($update), and then: ($install)."
  )
}

def menu-back-up [] {
  say "Back up" (
    "This copies everything the machine keeps between boots, like your " +
    "home folder and its secrets, onto the external drive. The backup is " +
    "locked with a password you choose."
  ) (
    "It runs from the live USB because the disk of the machine must not be " +
    "in use."
  )

  let machine = (pick-machine "Which machine is on the disk of this computer?")
  if $machine == null {
    return
  }
  let partition = (
    pick-partition
      "Which partition of the external drive should the backup go on?"
      --skip-disk (machine-disk $machine)
  )
  if $partition == null {
    return
  }

  say "What you will be asked" (
    "First the disk passphrase: the one you type at every boot."
  ) (
    "Then a backup password. The first time, you type it twice. Remember " +
    "it: nothing can open the backup without it."
  )

  main back-up $machine $partition

  say "Done" "The backup is on the external drive." (
    $"To put it back, pick: ($install), and say yes when it asks about a " +
    "backup."
  )
}

def menu-migrate [] {
  say "Back up a system that does not use stolon yet" (
    "This backs up what the machine you pick keeps, like your home folder " +
    "and its secrets, from the old system of this computer, so you can put " +
    "it back when you install the machine. It copies what it finds, and " +
    "says what it did not find."
  ) (
    "Mount the old system yourself first, for example at /mnt, with its " +
    "other partitions like /home in place. To do that, pick: " +
    $"($look_around), and type stolon-installer to come back here."
  )

  let machine = (pick-machine "Which machine will the old system become?")
  if $machine == null {
    return
  }
  let summary = (check-machine $machine)
  let old_system = (
    ask-text "Where is the old system mounted?" "for example /mnt"
  )
  if $old_system == null or $old_system == "" {
    return
  }
  let partition = (
    pick-partition
      "Which partition of the external drive should the backup go on?"
      --skip-disk $summary.disk
  )
  if $partition == null {
    return
  }

  say "What you will be asked" (
    "A backup password. The first time, you type it twice. Remember it: " +
    "nothing can open the backup without it."
  )

  main migrate $machine $old_system $partition

  say "Done" (
    "The backup is on the external drive. What the old system did not have " +
    "is listed above, and starts empty."
  ) (
    "Unmount the old system first, for example with umount -R /mnt. Then " +
    $"pick: ($install), and say yes when it asks about a backup."
  )
}

# With --elsewhere the disk goes into another computer afterwards.
def menu-install [--elsewhere] {
  if $elsewhere {
    say "Install onto a disk for another computer" (
      "This erases a disk, sets it up for the machine you pick, and " +
      "installs the system, so the disk is ready to go into that machine's " +
      "computer. It can also put a backup from the external drive back " +
      "onto it."
    ) (
      "Connect the disk the same way it sits in the other computer, for " +
      "example in an M.2 slot and not in a USB case, so it keeps its name."
    )
  } else {
    say "Install a machine" (
      "This erases the disk of this computer, sets it up for the machine " +
      "you pick, and installs the system. It can also put a backup from the " +
      "external drive back onto it."
    )
  }

  let machine = (pick-machine "Which machine is this disk for?")
  if $machine == null {
    return
  }
  let disk = (machine-disk $machine)

  let restore = (ask-yes (
    "Put a backup from the external drive back onto the disk? Pick Yes " +
    "when you reinstall a machine, move it to new hardware or move it onto " +
    "stolon."
  ))
  let partition = if $restore {
    (
      pick-partition "Which partition of the external drive has the backup?"
        --skip-disk $disk
    )
  } else {
    null
  }
  if $restore and $partition == null {
    return
  }

  say --warning "This erases the disk" (
    $"Everything on ($disk) \((describe-disk $disk)\) will be gone."
  )
  let typed = (ask-text (
    $"Type ($machine) to erase the disk. Anything else stops here."
  ) "")
  if $typed != $machine {
    say "Stopped" "Nothing was erased."
    return
  }

  let restore_questions = if $restore {
    [(
      "For the restore, you are asked for the new disk passphrase again " +
      "and then the backup password."
    )]
  } else {
    []
  }
  say "What you will be asked" (
    "A new disk passphrase, twice. You type it at every boot, so pick one " +
    "you will remember."
  ) ...$restore_questions

  if $restore {
    main install $machine --yes-wipe-disk --restore $partition
  } else {
    main install $machine --yes-wipe-disk
  }

  if $elsewhere {
    say "Done" "The disk is ready to go into the other computer."
  } else {
    say "Done" "The machine is installed." (
      $"Pick: ($restart), and take out the USB stick when the screen goes " +
      "dark."
    )
  }
}

def menu-wifi [] {
  say "Connect to Wi-Fi" "Pick a network and type its password. Esc goes back."
  ext-unblock-wifi
  ext-connect-wifi
  say-connection
}

def menu-update [] {
  say "Get the latest installer" (
    "Downloads the newest installer and machine list from " +
    $"($remote_flake_ref) and starts it in place of this one. Use it after " +
    "you push a new machine or hardware report."
  )
  ext-update
}

def menu-restart [] {
  let question = (
    "Restart now? Take out the USB stick when the screen goes dark."
  )
  if (ask-yes $question) {
    ext-reboot
  }
}

def menu-look-around [] {
  say "Look around" (
    "The usual disk, hardware and network tools are installed, and each " +
    "has --help. Anything else is one nix run nixpkgs#<name> away."
  ) (
    "Type stolon-installer to open the menu again, and stolon-installer " +
    "--help to see the commands it runs."
  )
}

def say-connection [] {
  let caches = (check-caches)
  let results = ($caches | each { |cache|
    if $cache.reachable {
      $"[ok] ($cache.cache)"
    } else {
      $"[fail] ($cache.cache)"
    }
  })
  let status = (connection-status $caches)
  if $offline {
    let reachable = if $status == "none" {
      ["Nix is not set to download from any binary cache."]
    } else {
      ["In case it needs them after all:" ...$results]
    }
    say "Offline installer" (
      "Everything this installer installs is on the USB stick, so it does " +
      "not need a network."
    ) ...$reachable
  } else if $status == "online" {
    say "Online" "This computer can reach the binary caches." ...$results
  } else if $status == "partly" {
    say --warning "Partly online" (
      "Some binary caches cannot be reached, so installing builds more " +
      "from source, or stops when it needs them."
    ) ...$results
  } else if $status == "offline" {
    say --warning "Offline" (
      "This computer cannot reach the binary caches yet, and installing " +
      $"needs them. Plug in a network cable, or pick: ($wifi)."
    ) ...$results
  } else {
    say --warning "No binary caches" (
      "Nix is not set to download from any binary cache, so installing " +
      "builds everything from source."
    )
  }
}

# Lets the user pick a machine, with the one whose disk is in this computer
# picked already.
def pick-machine [header: string] {
  let names = ($machine_summaries | columns)
  let guess = (guess-machine)
  if $guess == null {
    pick $header $names
  } else {
    let explained = (
      $"($header)\n($guess) is picked already, because its disk is in " +
      "this computer."
    )
    pick $explained $names --selected $guess
  }
}

def pick-partition [header: string, --skip-disk: string] {
  let partitions = (list-partitions $skip_disk)
  if ($partitions | is-empty) {
    say --warning "No partition found" (
      "Plug in the external drive, wait a few seconds, and try again."
    )
    return null
  }

  let separator = " | "
  let options = ($partitions | each { |partition|
    [
      $partition.partition
      $partition.size
      $partition.filesystem
      $partition.label
      $partition.model
      $partition.transport
    ] |
    compact |
    each { str trim } |
    where $it != "" |
    str join $separator
  })
  let picked = (pick $header $options)
  if $picked == null { null } else { $picked | split row $separator | first }
}

# Runs a task of the menu, and goes back to the menu when it fails.
def attempt [task: closure] {
  try {
    do $task
  } catch { |error|
    print ""
    print (
      ext-gum style --bold --foreground $warning_color $"[fail] ($error.msg)"
    )
    print (ext-gum style --width $text_width (
      "The rest of this task was skipped. Fix what it says, then pick the " +
      "same thing again from the menu. Starting over is always fine."
    ))
  }
}

def say [title: string, --warning, --first, ...lines: string] {
  let color = if $warning { $warning_color } else { $title_color }
  if not $first {
    print ""
  }
  print (ext-gum style --bold --foreground $color $title)
  if ($lines | is-not-empty) {
    print (ext-gum style --width $text_width ...$lines)
  }
}

# Gives the picked option, or null when the user goes back.
def pick [header: string, options: list<string>, --selected: string] {
  print ""
  let preselect = if $selected == null { [] } else { ["--selected" $selected] }
  let picked = (try {
    (
      ext-gum choose --no-show-help --header $header ...$preselect
        ...$options
    )
  } catch {
    null
  })
  if $picked == null { null } else { $picked | str trim }
}

# Gives the typed text, or null when the user goes back.
def ask-text [header: string, placeholder: string, --value: string = ""] {
  print ""
  let typed = (try {
    (
      ext-gum input --no-show-help --header $header
        --placeholder $placeholder --value $value
    )
  } catch {
    null
  })
  if $typed == null { null } else { $typed | str trim }
}

def ask-yes [question: string] {
  try { ext-gum confirm --no-show-help $question; true } catch { false }
}

# -----------------------------------------------------------------------------
# CLI
#
# The commands, and all the logic behind them. The menu above calls these, so
# the tests of the commands also cover what the menu does.
# -----------------------------------------------------------------------------

# Lists the machines, and whether the disk of each is in this computer. Prints
# JSON when the output is not a terminal.
def "main machines" [] {
  list-machines | for-output
}

# Lists the partitions that can hold a hardware report or a backup. A drive
# with a filesystem and no partitions counts as one. Prints JSON when the
# output is not a terminal.
def "main partitions" [
  --skip-disk: string # Leave out this disk and its partitions
] {
  list-partitions $skip_disk | for-output
}

# Checks which binary caches of Nix this computer can reach, since installing
# downloads from them. Prints JSON when the output is not a terminal.
def "main caches" [] {
  check-caches | for-output
}

# Scans the hardware of this computer and saves the report on the external
# drive, so the machine can be added to the flake from another computer.
def "main save-report" [
  name: string # The name of the machine
  partition: string # The partition of the external drive
] {
  require-root
  if not ($name =~ '^[a-z][a-z0-9-]*$') {
    fail (
      "A machine name has lowercase letters, digits and dashes, and starts " +
      "with a letter."
    )
  }
  check-partition $partition
  if $name in ($machine_summaries | columns) {
    print (
      $"($name) already exists. That is fine when its hardware changed: " +
      "the new report replaces the old one once you commit it."
    )
  }

  let report = $"($hardware_reports)/($name).json"
  with-external $partition {
    step "Scan the hardware" (
      $"Saves the report as ($report) on the external drive."
    ) {
      ext-scan-hardware $report
    }
  }
}

# Backs up what the machine keeps between boots onto the external drive. Asks
# for the disk passphrase and a backup password, or reads them from the input,
# one per line.
def "main back-up" [
  machine: string # The machine on the disk of this computer
  partition: string # The partition of the external drive
] {
  require-root
  let disk = (machine-disk $machine)
  check-partition $partition --not-on $disk

  step "Back up the machine" (
    "Copies what the machine keeps into the stolon folder on the external " +
    "drive."
  ) {
    ext-run-disk-script $machine stolonBackup $disk $partition
  }
}

# Backs up what the machine keeps from an old system that does not use stolon
# yet, as well as it can, so that installing the machine with --restore puts
# it back. Mount the old system first, with all of its partitions. Asks for a
# backup password, or reads it from the input.
def "main migrate" [
  machine: string # The machine the old system becomes
  old_system: string # Where the old system is mounted
  partition: string # The partition of the external drive
] {
  require-root
  let summary = (check-machine $machine)
  # Installing the machine erases its disk, which is often the one the old
  # system is on.
  check-partition $partition --not-on $summary.disk

  step "Back up the old system" (
    "Copies what the machine keeps from the old system into the stolon " +
    "folder on the external drive."
  ) {
    ext-run-disk-script $machine stolonMigrate $old_system $partition
  }
}

# Erases the disk of the machine, sets it up and installs the system. With
# --restore, it puts the latest backup of the machine back before installing,
# and asks for the passphrases like back-up does.
def "main install" [
  machine: string # The machine to install
  --restore: string # The partition of the external drive with the backup
  --yes-wipe-disk # Agree that everything on the disk is erased
] {
  require-root
  let summary = (machine-summary $machine)
  let disk = (machine-disk $machine)
  if $restore != null {
    check-partition $restore --not-on $disk
  }
  if not $yes_wipe_disk {
    fail (
      $"This erases everything on ($disk). Add --yes-wipe-disk to go ahead."
    )
  }

  step "Erase and format the disk" (
    "Creates the layout the machine expects and opens it on " +
    $"($summary.mountPoint)."
  ) {
    ext-run-disk-script $machine destroyFormatMount "--yes-wipe-all-disks"
  }
  # The backup goes back onto the fresh layout, which is what stolon-restore
  # expects, and before the install, so the activation that nixos-install runs
  # already sees what was kept, like the user and group ids in /var/lib/nixos.
  if $restore != null {
    step "Close the disk" "A backup can only be put back onto a closed disk." {
      ext-run-disk-script $machine unmount
    }
    step "Restore the backup" (
      $"Puts the latest backup of ($machine) back onto the disk."
    ) {
      ext-run-disk-script $machine stolonRestore $disk $restore
    }
    step "Open the disk again" "So the system can be installed onto it." {
      ext-run-disk-script $machine mount
    }
  }
  step "Install the system" (
    "Downloads or builds everything the machine needs and installs it. " +
    "This is the long part."
  ) {
    ext-install-system $machine $summary.mountPoint
  }
}

def check-caches [] {
  binary-caches | each { |cache|
    { cache: $cache, reachable: (ext-reachable $cache) }
  }
}

# The binary caches Nix downloads from, with what the user set. Only the ones
# on the web can be checked.
def binary-caches [] {
  ["substituters" "trusted-substituters"] |
  each { |setting| ext-nix-setting $setting | split row " " } |
  flatten |
  where $it =~ '^https?://' |
  each { str trim --right --char "/" } |
  uniq
}

# Whether the binary caches can be reached: online, partly, offline, or none
# when there are no caches to check.
def connection-status [caches: list] {
  let reachable = ($caches | where { |cache| $cache.reachable } | length)
  if ($caches | is-empty) {
    "none"
  } else if $reachable == ($caches | length) {
    "online"
  } else if $reachable > 0 {
    "partly"
  } else {
    "offline"
  }
}

# The machine whose disk is in this computer, when there is exactly one.
def guess-machine [] {
  let here = (list-machines | where { |machine| $machine.here })
  if ($here | length) == 1 { $here | first | get name } else { null }
}

def list-machines [] {
  $machine_summaries | transpose name summary | each { |row|
    {
      name: $row.name
      system: $row.summary.system
      disk: $row.summary.disk
      here: (disk-present $row.summary)
    }
  }
}

def list-partitions [skip_disk?: string] {
  let skip = if $skip_disk == null {
    null
  } else {
    ext-resolve-device $skip_disk
  }
  let devices = (ext-block-devices)
  let disks = ($devices | where type == "disk")

  $devices |
  where { |device|
    (
      $device.type in ["disk" "part"] and
      $device.fstype != null and
      not ($device.fstype in $unusable_filesystems) and
      ($skip == null or ($device.name != $skip and $device.pkname != $skip))
    )
  } |
  each { |device|
    let disk = if $device.type == "disk" {
      $device
    } else {
      $disks | where name == $device.pkname | get --optional 0
    }
    {
      partition: $device.name
      size: $device.size
      filesystem: $device.fstype
      label: $device.label
      model: (if $disk == null { null } else { $disk.model })
      transport: (if $disk == null { null } else { $disk.tran })
    }
  }
}

def machine-summary [name: string] {
  let names = ($machine_summaries | columns)
  if not ($name in $names) {
    fail (
      $"There is no machine called ($name). The machines are: " +
      $"($names | str join ', ')."
    )
  }
  $machine_summaries | get $name
}

# The summary of the machine, after checking that it uses stolon and that
# Nix here can build it.
def check-machine [name: string] {
  let summary = (machine-summary $name)
  if $summary.disk == null {
    fail $"($name) does not use stolon, so it cannot be installed from here."
  }
  let systems = (buildable-systems)
  if not ($summary.system in $systems) {
    fail (
      $"($name) runs on ($summary.system), and Nix here only builds for " +
      $"($systems | str join ', '). To build for it, add it to " +
      "boot.binfmt.emulatedSystems of the NixOS configuration of this " +
      "computer."
    )
  }
  $summary
}

# The disk of the machine, after checking that this computer can install it.
def machine-disk [name: string] {
  let summary = (check-machine $name)
  if (find-device $summary.disk) == null {
    fail (
      $"($name) expects the disk ($summary.disk), and this computer does " +
      "not have it. If the disk is in a USB case, connect it directly " +
      "instead, so it keeps its name. If this is new hardware, save its " +
      "hardware report and update the machine in the flake first."
    )
  }
  $summary.disk
}

# Nix builds for the system it runs on and its extra platforms, which NixOS
# fills from boot.binfmt.emulatedSystems.
def buildable-systems [] {
  ext-nix-setting "extra-platforms" |
  split row " " |
  where $it != "" |
  prepend $this_system |
  uniq
}

# The size and model of a disk, so the user can tell which one is erased.
def describe-disk [disk: string] {
  let device = (find-device $disk)
  if $device == null {
    return "not found"
  }
  [$device.size $device.model] | compact | each { str trim } | str join " "
}

# The block device at the path, after following links like /dev/disk/by-id,
# or null when there is none.
def find-device [path: string] {
  let name = (ext-resolve-device $path)
  ext-block-devices | where name == $name | get --optional 0
}

# A table needs the width of the terminal, and scripts read JSON better.
def for-output [] {
  if (is-terminal --stdout) { $in } else { $in | to json }
}

def disk-present [summary: record] {
  $summary.disk != null and (find-device $summary.disk) != null
}

# Fails unless the partition exists, and with --not-on, unless it is on
# another disk than the given one.
def check-partition [partition: string, --not-on: string] {
  let device = (find-device $partition)
  if $device == null {
    fail $"($partition) is not a partition."
  }
  if $not_on == null {
    return
  }
  let disk = (ext-resolve-device $not_on)
  if $device.name == $disk or $device.pkname == $disk {
    fail (
      $"($partition) is on the disk of the machine. Pick a partition on " +
      "another drive."
    )
  }
}

# Mounts the external drive for the task and unmounts it after, even when the
# task fails.
def with-external [partition: string, task: closure] {
  step "Mount the external drive" "So files can be written to it." {
    ext-mount-external $partition
  }
  let failure = (try { do $task; null } catch { |error| $error.msg })
  step "Unmount the external drive" "So it is safe to unplug." {
    ext-unmount-external
  }
  if $failure != null {
    fail $failure
  }
}

# Explains a step, runs it, and stops the task when it fails.
def step [title: string, why: string, action: closure] {
  print ""
  print $"(ansi magenta_bold)> ($title)(ansi reset) ($why)"
  try {
    do $action
  } catch { |error|
    fail $"($title) did not work: ($error.msg)"
  }
  print $"(ansi green_bold)[ok] ($title)(ansi reset)"
}

# A dry run changes nothing, so it does not need root.
def require-root [] {
  if not $dry_run and not (is-admin) {
    fail "Run this as root: put sudo in front of the command."
  }
}

def fail [message: string] {
  error make --unspanned { msg: $message }
}

# -----------------------------------------------------------------------------
# EXT
#
# Everything that touches this computer. In a dry run, what would change it
# only says what it would run, and in a fake run, what looks at it gets made
# up answers. The menu always runs for real, since it changes nothing.
# -----------------------------------------------------------------------------

def --wrapped ext-gum [...arguments] {
  ^gum ...$arguments
}

def ext-block-devices [] {
  if $fake {
    return $fake_block_devices
  }
  capture lsblk [
    "--json" "--list" "--paths"
    "--output" "NAME,PKNAME,TYPE,SIZE,FSTYPE,LABEL,MODEL,TRAN"
  ] |
  from json |
  get blockdevices
}

def ext-resolve-device [path: string] {
  if $fake { $path } else { $path | path expand }
}

def ext-nix-setting [name: string] {
  if $fake {
    return ($fake_nix_settings | get $name)
  }
  with-env { NIX_CONFIG: (nix-config-env) } {
    capture nix ["config" "show" $name] | str trim
  }
}

# Shows a spinner while it asks the binary cache for its info.
def ext-reachable [cache: string] {
  let title = $"Checking ($cache)"
  if $fake {
    spin $title sleep [$fake_check_seconds]
    return true
  }
  try {
    spin $title curl [
      "--head" "--silent" "--fail" "--output" "/dev/null"
      "--max-time" $cache_timeout_seconds
      $"($cache)/nix-cache-info"
    ]
    true
  } catch {
    false
  }
}

# gum only draws a spinner on a terminal, and fails without one.
def spin [title: string, command: string, arguments: list] {
  if (is-terminal --stdout) {
    ^gum spin --spinner $spinner --title $title -- $command ...$arguments
  } else {
    ^$command ...$arguments
  }
}

def ext-has-wifi-tool [] {
  $fake or (which nmtui | is-not-empty)
}

def ext-mount-external [partition: string] {
  change mkdir ["--parents" $external_mount]
  change mount [$partition $external_mount]
}

def ext-unmount-external [] {
  change umount [$external_mount]
}

def ext-scan-hardware [report: string] {
  let path = $"($external_mount)/($report)"
  change mkdir ["--parents" ($path | path dirname)]
  change nixos-facter ["--output" $path]
}

def ext-run-disk-script [
  machine: string
  script: string
  ...arguments: string
] {
  if $offline {
    change ($offline_builds.scripts | get $script) $arguments
    return
  }
  let script_ref = (
    $"($repository)#nixosConfigurations.($machine)" +
    $".config.system.build.($script)"
  )
  change-with-nix nix ["run" $script_ref "--" ...$arguments]
}

def ext-install-system [machine: string, mount_point: string] {
  if $offline {
    change nixos-install [
      "--root" $mount_point
      "--system" $offline_builds.system
      "--no-root-password"
    ]
    return
  }
  change-with-nix nixos-install [
    "--root" $mount_point
    "--flake" $"($repository)#($machine)"
    "--no-root-password"
  ]
}

# Wi-Fi is often switched off by the hardware switch or the firmware.
def ext-unblock-wifi [] {
  change rfkill ["unblock" "wifi"]
}

def ext-connect-wifi [] {
  change nmtui ["connect"]
}

def ext-reboot [] {
  change systemctl ["reboot"]
}

def ext-update [] {
  if $dry_run {
    would-run nix ["run" "--refresh" $remote_flake_ref]
    return
  }
  $env.NIX_CONFIG = (nix-config-env)
  exec nix run --refresh $remote_flake_ref
}

def change-with-nix [command: string, arguments: list<string>] {
  with-env { NIX_CONFIG: (nix-config-env) } {
    change $command $arguments
  }
}

# The settings of the user, followed by the ones the installer needs.
def nix-config-env [] {
  [($env.NIX_CONFIG? | default "") $nix_config] |
  where $it != "" |
  str join "\n"
}

# Runs a command that changes this computer, or in a dry run only says that
# it would.
def change [command: string, arguments: list<string>] {
  if $dry_run {
    would-run $command $arguments
  } else {
    run $command $arguments
  }
}

def would-run [command: string, arguments: list<string>] {
  let line = ([$command ...$arguments] | str join " ")
  print $"(ansi yellow_bold)Would run:(ansi reset) ($line)"
}

def run [command: string, arguments: list<string>] {
  try {
    ^$command ...$arguments
  } catch {
    fail $"($command) failed, and the messages above say why."
  }
}

def capture [command: string, arguments: list<string>] {
  let result = (^$command ...$arguments | complete)
  if $result.exit_code != 0 {
    fail $"($command) failed: ($result.stderr | str trim)"
  }
  $result.stdout
}
