# Stolon

<!-- ANCHOR: overview -->

NixOS modules that put a whole system on one disk. The disk is encrypted and
compressed, the system starts from a clean slate on every boot and keeps only
what you list, old Nix garbage is collected daily, and two commands move what is
kept to another drive and back.

<!-- ANCHOR_END: overview -->

The [docs](https://haras-unicorn.github.io/stolon/) explain the
[design](https://haras-unicorn.github.io/stolon/design.html) and list every
[option](https://haras-unicorn.github.io/stolon/options.html).

<!-- ANCHOR: guides -->

## Usage

Add the flake as an input and import its module in a NixOS configuration:

```nix
{
  inputs.stolon.url = "github:haras-unicorn/stolon";

  outputs = { nixpkgs, stolon, ... }: {
    nixosConfigurations.my-machine = nixpkgs.lib.nixosSystem {
      modules = [
        stolon.nixosModules.default
        {
          stolon.enable = true;
          stolon.device = "/dev/disk/by-id/nvme-example";
          stolon.keep.directories = [
            "/home/alice/.ssh"
            "/home/alice/Documents"
          ];
          stolon.keep.databases = [ "/var/lib/postgresql" ];
        }
      ];
    };
  };
}
```

Everything outside of `stolon.keep` is thrown away on every boot. That includes
passwords set with `passwd`, so give every user a `hashedPassword` (made with
`mkpasswd`) in the configuration.

## Guides

These assume your configuration is in a git repository you can clone, and that
you work as root in a live system such as the NixOS installer, with flakes
enabled. The tools refuse a disk that is in use, so they cannot run from the
system on that disk. The commands use `build` for the scripts of your
configuration:

```sh
build=".#nixosConfigurations.my-machine.config.system.build"
```

### Install on a machine

1. Format the disk named in `stolon.device` and mount it on `/mnt`. This erases
   the disk. If `stolon.encryption.passwordFile` is set, create that file first.

   ```sh
   nix run "$build.destroyFormatMount" -- --yes-wipe-all-disks
   ```

2. Install, then reboot. The passphrase is asked on the console.

   ```sh
   nixos-install --root /mnt --flake ".#my-machine" --no-root-password
   ```

### Back up

Give the disk of the machine and a partition for the backup. The partition can
be on any drive, with any filesystem that mounts. The backup goes into a
`stolon` folder on it. You are asked for the disk's passphrase and a backup
password, which is asked twice the first time. Nothing can open the backup
without that password.

```sh
nix run "$build.stolonBackup" -- /dev/disk/by-id/nvme-example /dev/sdb1
```

Only what `stolon.keep` lists is backed up.

### Restore

Restore into a disk that was just formatted with the same configuration.

1. Format the disk and close it again, because it must not be in use.

   ```sh
   nix run "$build.destroyFormatMount" -- --yes-wipe-all-disks
   nix run "$build.unmount"
   ```

2. Restore the latest backup made for this host name.

   ```sh
   nix run "$build.stolonRestore" -- /dev/disk/by-id/nvme-example /dev/sdb1
   ```

3. Mount the disk again, install and reboot.

   ```sh
   nix run "$build.mount"
   nixos-install --root /mnt --flake ".#my-machine" --no-root-password
   ```

<!-- ANCHOR_END: guides -->
