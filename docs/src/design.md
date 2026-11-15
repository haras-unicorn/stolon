# Design

## Invariants

These hold for every change.

- **One disk per system.** No RAID and no ZFS pools. Redundancy comes from
  replicating over the network, and Stolon assumes you do that.
- **Encrypted and compressed by default,** and so are the backups.
- **Fast.** Anything that costs speed is optional.
- **Few options.** Fewer options leave fewer ways to make a mistake.
- **Tested.** Every scenario that can happen in real life is a NixOS VM test.

## Decisions

### Disko

One command sets up a NixOS machine on one disk. The layout is a boot partition
and a LUKS container holding one btrfs filesystem. The names that identify the
layout live in `src/nix/lib/layout.nix`, so the modules, the backup tools and
the tests cannot drift apart.

### Btrfs

Its built-in `zstd` compression is fast enough on most hardware, and it can be
turned off where it is not. Databases and virtual machine disks get folders that
are not copy-on-write, because many small writes fragment a copy-on-write file.
The price is that those folders are not compressed.

### LUKS

Encrypts the disk. It can be turned off where it makes the disk too slow. The
passphrase is asked on the console at boot. Unlocking over the network on a
machine without a screen is not built yet.

### Impermanence

The root is thrown away and made again on every boot, by a small script that
runs in the initrd before the system starts. What you want to keep is listed in
`stolon.keep`, and each of those folders gets its own btrfs subvolume under
`/persist`. The `impermanence` module bind-mounts them back to where they
belong. Because the folders are separate subvolumes, they can be backed up one
by one, and databases and virtual machines can be set up without copy-on-write.

What is kept changes only at boot. A switch would unmount and mount kept folders
under programs that may be using them, so a pre-switch check refuses it and asks
for a boot. Each system records what it keeps and how its disk is set up in
`/etc/stolon/system.json` for that check. Three rules hold:

- **What is missing is made at boot.** A script in the initrd runs before the
  root is wiped. It makes the subvolume of each newly kept folder and copies in
  what was at its path, from the old root and from the folder that held it, with
  reflinks that share the data. A newly kept file is copied from the old root
  the same way. Each subvolume is built in a staging folder and renamed into
  place once it is whole, so a boot that stops halfway leaves nothing that looks
  finished, and the root is only wiped once all of it worked.
- **Nothing is deleted.** Neither the subvolume of a folder that is no longer
  kept nor the copy a folder leaves behind when it gets its own subvolume: a
  folder dropped from the configuration by mistake would take its data along,
  and a generation you roll back to may still need it. `stolon-stale` lists what
  the running system neither mounts nor binds, and deletes it on request.
- **The check refuses what would copy, delete or bring back data at boot,**
  while the user can still decide. A reflink cannot share data between a
  copy-on-write folder and one without, so such a copy would write all of it at
  boot, with no way to know beforehand whether it fits. Old data that shows up
  over what is there now is as surprising as data that disappears. The check
  compares the new system and its specialisations with the running one, and the
  specialisations with each other, since the boot menu starts any of them
  without a check.

Turning Stolon off and turning encryption on or off are always refused, because
the system would look for its root where it is not. `stolon.device` may only
change to the disk the system runs from, since the installer erases the disk it
names.

### Restic

Each NixOS configuration gets a `stolon-backup` and a `stolon-restore` command,
made for moving to another drive by hand. They take a target drive and a backup
partition. The target must have the layout this configuration expects and must
not be in use, so they run from another system, such as a live USB. A backup is
the kept subvolumes, always compressed and encrypted. The backup password is
asked when it is made and when it is restored. Each backup is tagged with the
physical drive ID, the host name and the date. The same `stolon.keep` option
decides what is kept and what is backed up. Backups go into `stolon/backups` on
the backup partition, and everything else the tools put on an external drive
goes under the same `stolon` folder.

A third command, `stolon-migrate`, backs up a system that does not use Stolon
yet, so that `stolon-restore` puts it onto a Stolon disk like any other backup.
The layout of an old system can be anything, so it is mounted by hand, and the
one thing the command checks is that something is mounted there. It mounts each
kept path of the old system read-only where that volume sits at the top of a
Stolon disk, inside an empty tmpfs, and backs up the same paths a backup does.
It follows the links of the old system the way the old system would: an absolute
link starts again at its root, and `..` never leaves it. It is best effort: what
the old system does not have stays empty, and the command lists it. A migration
is tagged with `migrated` instead of a drive ID, since the old system can be
spread over any number of drives.

### Installer

The `installer` overlay gives `stolonPackages.makeInstaller`, which makes the
installer of the machines of a flake and an image for a USB stick. It is a
command line and a menu in one Nushell script. The commands hold all the logic
and ask for nothing but the passphrases, so they are what the tests run. The
menu only asks questions, explains the steps and calls the commands, so when it
breaks, the commands still work. Everything that touches the computer sits
apart, so a dry run can skip what changes it and a fake run can make up what it
finds. The `testInstaller` package of this flake is a fake run with made-up
machines, for trying out the menu anywhere, and `testImage` is the image with
it, for trying it out from a USB stick.

The network is what most often breaks an install, so `makeInstaller` also makes
an offline installer and image for each machine of its system. It carries the
built system of that one machine and the programs of its scripts, and runs them
from its own store: `nixos-install --system` installs the built system as it is,
so nothing is evaluated or downloaded. It has no flake, and the menu has no
update, since the image only knows the system it was built with.

Only the name, system and disk of each machine are built into the installer, so
the image stays small and lists the machines offline. The machines themselves
are evaluated from the flake when they are installed. A machine's disk is always
the `stolon.device` it names, so a disk prepared in another computer keeps its
`/dev/disk/by-id` path, and Stolon assumes one Stolon disk per computer.

### Garbage collection

Nix garbage is collected daily, with the retention set by `stolon.gc`. A second
daily service removes the gcroots of `direnv` projects whose git `HEAD` has not
moved for as long as that retention, so old project environments do not pile up
on a drive with no spare room.

### Trim

Tells an SSD which parts are free. It is on by default, since most drives are
SSDs, and can be turned off for hard drives.

### GRUB

The boot loader is GRUB, installed as a removable EFI entry, so it does not
touch the firmware's boot variables.
