{ lib, ... }:

let
  # What the installer knows about a machine without evaluating it again: its
  # system, and its disk and where that is mounted when it uses stolon.
  machineSummary =
    machine:
    let
      usesStolon = machine.config.stolon.enable or false;
    in
    {
      system = machine.config.nixpkgs.hostPlatform.system;
      disk = if usesStolon then machine.config.stolon.device else null;
      mountPoint = if usesStolon then machine.config.disko.rootMountPoint else null;
    };

  # What an offline installer carries of its machine and runs from its store,
  # so it installs the machine without evaluating the flake or downloading
  # anything: the built system, and the programs of the scripts it runs.
  offlineBuilds =
    machine:
    let
      build = machine.config.system.build;
    in
    {
      system = build.toplevel;
      scripts = builtins.mapAttrs (_: lib.getExe) {
        inherit (build)
          destroyFormatMount
          mount
          unmount
          stolonBackup
          stolonRestore
          stolonMigrate
          ;
      };
    };

  # Made-up machines for the test installer, which also makes up the drives it
  # finds. The laptop's disk is the disk of that fake computer, so the menu
  # guesses it, and the others show what the installer refuses.
  fakes = {
    system = "x86_64-linux";
    machines = {
      laptop = {
        system = "x86_64-linux";
        disk = "/dev/nvme0n1";
        mountPoint = "/mnt";
      };
      desktop = {
        system = "x86_64-linux";
        disk = "/dev/disk/by-id/nvme-fake-desktop";
        mountPoint = "/mnt";
      };
      pi = {
        system = "aarch64-linux";
        disk = "/dev/mmcblk0";
        mountPoint = "/mnt";
      };
      router = {
        system = "x86_64-linux";
        disk = null;
        mountPoint = null;
      };
    };
  };

  # The installer image without what makes it an image, so a NixOS test can
  # boot it in a virtual machine.
  imageModule =
    {
      lib,
      pkgs,
      config,
      ...
    }:
    {
      options.stolon.installer.package = lib.mkOption {
        type = lib.types.package;
        description = "The installer from `makeInstaller` that the image opens on start.";
      };

      config = {
        nix.settings.experimental-features = [
          "nix-command"
          "flakes"
        ];

        # The menu starts as root on the first console instead of a login, and
        # leaving it leaves a root shell there.
        services.getty.autologinUser = lib.mkForce "root";
        services.getty.helpLine = lib.mkForce "Type stolon-installer to open the menu again.";
        programs.bash.loginShellInit = ''
          if [ "$(tty)" = /dev/tty1 ]; then
            stolon-installer
          fi
        '';

        # The installation image turns on wpa_supplicant, and nmtui is easier to
        # use from the menu.
        networking.networkmanager.enable = true;
        networking.wireless.enable = lib.mkForce false;

        # The most common tools for checking and fixing disks, hardware and
        # networks, so they work before there is a network. Anything else is a
        # `nix run` away.
        environment.systemPackages = [
          config.stolon.installer.package
          pkgs.btop
          pkgs.btrfs-progs
          pkgs.cryptsetup
          pkgs.curl
          pkgs.ddrescue
          pkgs.dmidecode
          pkgs.dnsutils
          pkgs.dosfstools
          pkgs.e2fsprogs
          pkgs.efibootmgr
          pkgs.ethtool
          pkgs.exfatprogs
          pkgs.fio
          pkgs.gptfdisk
          pkgs.hdparm
          pkgs.helix
          pkgs.inxi
          pkgs.iw
          pkgs.lm_sensors
          pkgs.lshw
          pkgs.memtester
          pkgs.mtr
          pkgs.nixos-facter
          pkgs.ntfs3g
          pkgs.nvme-cli
          pkgs.parted
          pkgs.pciutils
          pkgs.smartmontools
          pkgs.stress-ng
          pkgs.testdisk
          pkgs.tmux
          pkgs.usbutils
        ];
      };
    };
in
{
  self.lib.installer = {
    inherit
      machineSummary
      offlineBuilds
      fakes
      imageModule
      ;
  };

  self.unitTests.installer = {
    machine-summary-of-a-stolon-machine = {
      expr = machineSummary {
        config = {
          nixpkgs.hostPlatform.system = "x86_64-linux";
          stolon = {
            enable = true;
            device = "/dev/disk/by-id/nvme-example";
          };
          disko.rootMountPoint = "/mnt";
        };
      };
      expected = {
        system = "x86_64-linux";
        disk = "/dev/disk/by-id/nvme-example";
        mountPoint = "/mnt";
      };
    };

    offline-builds-are-the-system-and-the-programs-of-the-scripts = {
      expr =
        let
          script = name: {
            type = "derivation";
            outPath = "/nix/store/${name}";
            meta.mainProgram = name;
          };
        in
        offlineBuilds {
          config.system.build = {
            toplevel = "/nix/store/system";
            destroyFormatMount = script "format";
            mount = script "mount";
            unmount = script "unmount";
            stolonBackup = script "backup";
            stolonRestore = script "restore";
            stolonMigrate = script "migrate";
            other = script "other";
          };
        };
      expected = {
        system = "/nix/store/system";
        scripts = {
          destroyFormatMount = "/nix/store/format/bin/format";
          mount = "/nix/store/mount/bin/mount";
          unmount = "/nix/store/unmount/bin/unmount";
          stolonBackup = "/nix/store/backup/bin/backup";
          stolonRestore = "/nix/store/restore/bin/restore";
          stolonMigrate = "/nix/store/migrate/bin/migrate";
        };
      };
    };

    machine-summary-of-a-machine-without-stolon = {
      expr = machineSummary {
        config.nixpkgs.hostPlatform.system = "aarch64-linux";
      };
      expected = {
        system = "aarch64-linux";
        disk = null;
        mountPoint = null;
      };
    };
  };
}
