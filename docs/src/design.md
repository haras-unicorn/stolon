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

### Restic

Each NixOS configuration gets a `stolon-backup` and a `stolon-restore` command,
made for moving to another drive by hand. They take a target drive and a backup
partition. The target must have the layout this configuration expects and must
not be in use, so they run from another system, such as a live USB. A backup is
the kept subvolumes, always compressed and encrypted. The backup password is
asked when it is made and when it is restored. Each backup is tagged with the
physical drive ID, the host name and the date. The same `stolon.keep` option
decides what is kept and what is backed up.

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
