# Stolon

<!-- ANCHOR: overview -->

NixOS modules that put a whole system on one disk. The disk is encrypted and
compressed, the system starts from a clean slate on every boot and keeps only
what you list, old Nix garbage is collected daily, and two commands move what is
kept to another drive and back. A third backs up a system that does not use
Stolon yet, so it can move onto it. An installer on a USB stick installs, backs
up and restores the machines of your flake.

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

### Installer

The installer comes from an overlay. Make it from your machines, next to
`nixosConfigurations`, and export it as the default package of your flake, with
the image beside it:

```nix
{
  outputs = { self, nixpkgs, stolon, ... }:
    let
      system = "x86_64-linux";

      pkgs = import nixpkgs {
        inherit system;
        overlays = [ stolon.overlays.installer ];
      };

      installer = pkgs.stolonPackages.makeInstaller {
        nixosConfigurations = self.nixosConfigurations;
        repository = self;
        remoteFlakeRef = "github:alice/machines";
      };
    in
    {
      packages.${system} = {
        default = installer.installer;
        installer-image = installer.image;
      };
    };
}
```

`repository` is where the installer reads the machines from, and
`remoteFlakeRef` is where it gets its newest version from. The guides below use
`github:alice/machines` for your flake. `imageModules` adds NixOS modules to the
image, for example a driver for a Wi-Fi stick that the kernel does not support
well:

```nix
installer = pkgs.stolonPackages.makeInstaller {
  # ...
  imageModules = [ ./wifi-stick.nix ];
};
```

For a computer that may have no network while it installs,
`installer.offlineImages.<machine>` is an image that carries the whole built
system of that one machine. It installs, backs up and restores the machine
without the flake or a network, and it takes `imageModules` too, in case it
needs the network after all. It is as big as the system of the machine, so
export only the ones you need:

```nix
packages.${system}.my-machine-image = installer.offlineImages.my-machine;
```

Every machine that uses Stolon and runs on the system of `pkgs` has one.

## Guides

You need:

- a USB stick with the installer image or any NixOS live system
- an external drive with a partition for backups and hardware reports, which go
  into a `stolon` folder on it
- a network connection (a cable is easiest), unless you use the offline image of
  the machine

### Start the installer

Every guide below uses the installer. Either way works:

- **Installer image:** boot the USB stick. The menu starts by itself. No cable?
  Pick **Connect to Wi-Fi** first.
- **Any NixOS live system:** connect to the network, open a terminal and run:

  ```sh
  sudo nix --extra-experimental-features 'nix-command flakes' \
    --accept-flake-config run --refresh github:alice/machines
  ```

The guides say which entries to pick, in order, and the installer explains each
step on screen. Esc goes back, and nothing is erased until you type the name of
the machine.

### Make the installer image

On a computer with Nix:

1. Build the image. On an ARM computer this builds the ARM image.

   ```sh
   nix build github:alice/machines#installer-image
   ```

   For the offline image of one machine, build that one instead, for example
   `github:alice/machines#my-machine-image`.

2. Find the USB stick with `lsblk`, for example `/dev/sdb`. Writing erases it.

3. Write the image and wait until it is done:

   ```sh
   sudo cp result/iso/*.iso /dev/sdb
   sync
   ```

### Reinstall a machine

1. Start the installer on the machine.
2. Pick **Back up this computer to the external drive**.
3. Pick **Install a machine on this computer**, and say yes to the backup.
4. Pick **Restart the computer**.

### Set up a new machine

1. Start the installer on the new computer.
2. Pick **Save this computer's hardware report to the external drive**, and give
   the machine a name.
3. On another computer, in your flake:
   1. Copy `stolon/hardware/<name>.json` from the external drive into the flake,
      and use it for the hardware of the machine, for example with the
      `hardware.facter.reportPath` option of nixos-facter.
   2. Add the machine to `nixosConfigurations`, with `stolon.device` set to its
      disk in `/dev/disk/by-id`. To see the disks, pick **Leave the menu and
      look around myself** on the new computer and run `ls -l /dev/disk/by-id`.
   3. Commit and push.
4. Back on the new computer, start the installer again. On the installer image,
   pick **Get the latest installer** first.
5. Pick **Install a machine on this computer**, and say no to the backup.
6. Pick **Restart the computer**.

### Move a machine to new hardware

1. Start the installer on the old computer.
2. Pick **Back up this computer to the external drive**.
3. Move the external drive to the new computer and start the installer there.
4. Pick **Save this computer's hardware report to the external drive**, with the
   same name as the machine.
5. On another computer, in your flake:
   1. Copy `stolon/hardware/<name>.json` from the external drive over the old
      report of the machine.
   2. Fix what changed in the machine, like `stolon.device`.
   3. Commit and push.
6. Back on the new computer, start the installer again. On the installer image,
   pick **Get the latest installer** first.
7. Pick **Install a machine on this computer**, and say yes to the backup.
8. Pick **Restart the computer**.

### Move a system onto Stolon

For a computer whose system does not use Stolon yet. What the machine keeps in
`stolon.keep` is copied from the old system, as far as the old system has it.

1. Set up the machine in your flake, as in steps 1 to 4 of
   [Set up a new machine](#set-up-a-new-machine).
2. Pick **Leave the menu and look around myself**, and mount the old system, for
   example at `/mnt`, with its other partitions like `/home` in place. Read-only
   is enough. For a system on one partition, like `/dev/nvme0n1p2`:

   ```sh
   mount -o ro /dev/nvme0n1p2 /mnt
   ```

   On an encrypted disk, open it first with
   `cryptsetup open /dev/nvme0n1p2 old`, and mount `/dev/mapper/old` instead.
   Then type `stolon-installer` to open the menu again.

3. Pick **Back up a system that does not use stolon yet**. It says which kept
   folders the old system does not have, and those start empty.
4. Pick **Leave the menu and look around myself** again, and unmount the old
   system with `umount -R /mnt`, and `cryptsetup close old` if you opened it.
5. Pick **Install a machine on this computer**, and say yes to the backup.
6. Pick **Restart the computer**.

### Prepare a disk for another computer

1. Put the disk of the other computer into this one, connected the same way it
   is there: in an M.2 slot, for example, and not in a USB case.
2. Start the installer.
3. Pick **Install a machine onto a disk for another computer**. Say yes to the
   backup if the machine has one on the external drive.
4. Turn this computer off, move the disk into the other computer, and start it.

### Fix things yourself

Pick **Leave the menu and look around myself**. It leaves you in a shell, where
the installer image has the usual disk, hardware and network tools, like
`smartctl`, `cryptsetup`, `btrfs` and `nmtui`. Type `stolon-installer` to open
the menu again.

### Without the menu

Every task of the menu is also a command, which asks for nothing but the
passphrases. `stolon-installer --help` lists them:

```sh
stolon-installer machines
stolon-installer partitions
stolon-installer caches
stolon-installer save-report my-machine /dev/sdb1
stolon-installer back-up my-machine /dev/sdb1
stolon-installer migrate my-machine /mnt /dev/sdb1
stolon-installer install my-machine --yes-wipe-disk --restore /dev/sdb1
```

On a live system without the image, put the command after `--` at the end of the
`nix run` in [Start the installer](#start-the-installer), for example
`-- machines`.

To see what a task would do without changing anything, set
`STOLON_INSTALLER_DRY_RUN=1`. It still looks at the real drives, and every step
only says what it would run.

<!-- ANCHOR_END: guides -->
