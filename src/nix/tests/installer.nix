{
  inputs,
  lib,
  self,
  selfLib,
  ...
}:

let
  passphraseFile = "/tmp/secret.key";

  # Every source the flake evaluates from, so Nix in the virtual machine finds
  # them in its store and does not try to download them.
  flakeSources =
    flake:
    [ flake.outPath ]
    ++ builtins.concatMap flakeSources (
      builtins.attrValues (builtins.removeAttrs (flake.inputs or { }) [ "self" ])
    );
in
{
  # The machine the installer installs. The test builds it on the host, and the
  # installer evaluates it again from this flake inside the virtual machine, so
  # both have to get it from the same place for the systems to match.
  self.lib.tests.installerMachine =
    system:
    inputs.nixpkgs.lib.nixosSystem {
      modules = [
        selfLib.nixosModules.default
        {
          nixpkgs.hostPlatform = system;
          system.stateVersion = "26.05";
          networking.hostName = "alpha";

          stolon = {
            enable = true;
            device = "/dev/vdb";
            encryption.passwordFile = passphraseFile;
            keep.directories = [ "/var/lib/data" ];
          };
        }
      ];
    };

  self.nixosTests.installer = {
    flake = true;
    value =
      { hostPkgs, ... }:
      let
        system = hostPkgs.stdenv.hostPlatform.system;

        stolonPackages =
          (hostPkgs.extend selfLib.overlays.overlays.installer).${selfLib.overlays.namespace};

        alpha = selfLib.tests.installerMachine system;

        scripts = alpha.config.system.build;

        # The modules render their mustache templates while the machine is
        # evaluated, so Nix in the virtual machine needs what renders them.
        templateRenderer =
          ((alpha.pkgs.extend inputs.haraspkgs.overlays.default).harasPackages.renderMustache {
            name = "renderer";
            text = "";
          }).inputDerivation;

        repository = hostPkgs.writeTextDir "flake.nix" ''
          {
            inputs.stolon.url = "path:${self}";

            outputs = { stolon, ... }: {
              nixosConfigurations.alpha = stolon.lib.tests.installerMachine "${system}";
            };
          }
        '';

        installer = stolonPackages.makeInstaller {
          nixosConfigurations = { inherit alpha; };
          inherit repository;
          remoteFlakeRef = "github:example/machines";
        };
      in
      {
        globalTimeout = selfLib.tests.installerTimeout;

        nodes.machine =
          { pkgs, ... }:
          {
            imports = [ selfLib.installer.imageModule ];
            stolon.installer.package = installer.installer;

            virtualisation = {
              memorySize = 4096;
              # The disk of the machine is /dev/vdb, the external drive is
              # /dev/vdc and the old system to migrate is /dev/vdd.
              emptyDiskImages = [
                6144
                1024
                512
              ];
              additionalPaths =
                lib.unique (flakeSources self)
                ++ [ templateRenderer ]
                ++ builtins.map (name: scripts.${name}) [
                  "toplevel"
                  "destroyFormatMount"
                  "mount"
                  "unmount"
                  "stolonBackup"
                  "stolonRestore"
                  "stolonMigrate"
                ];
            };

            # Virtual disks have no serial number, and the backup is named
            # after it.
            services.udev.extraRules = ''
              KERNEL=="vdb", ENV{ID_SERIAL_SHORT}="TARGET0001"
            '';

            # The virtual machine has no network, so Nix must not look for
            # anything online. nixos-install copies the system from this store
            # into the new one, and without always-allow-substitutes it builds
            # the parts that are marked to build locally, whose build tools are
            # not here.
            nix.settings = {
              substituters = lib.mkForce [ ];
              flake-registry = "";
              always-allow-substitutes = true;
            };

            # A binary cache that answers, for the check of the caches. It only
            # serves the info file that the check asks for.
            systemd.services.fake-cache = {
              wantedBy = [ "multi-user.target" ];
              serviceConfig.ExecStart = builtins.concatStringsSep " " [
                "${pkgs.python3}/bin/python3 -m http.server"
                "--directory ${pkgs.writeTextDir "nix-cache-info" "StoreDir: /nix/store\n"}"
                "8080"
              ];
            };

            boot.supportedFilesystems.btrfs = true;
            environment.systemPackages = [
              pkgs.e2fsprogs
              pkgs.jq
            ];
          };

        testScript = ''
          import json

          start_all()
          machine.wait_for_unit("multi-user.target")
          machine.succeed("echo -n secretsecret > ${passphraseFile}")
          machine.succeed("mkfs.ext4 /dev/vdc")

          with subtest("the menu opens on the first console and guesses the machine"):
              machine.wait_until_tty_matches("1", "What do you want to do")
              machine.send_key("ret")
              machine.wait_until_tty_matches("1", "What is this machine called")
              machine.wait_until_tty_matches("1", "alpha")
              machine.send_key("esc")

          with subtest("the machines and the partitions are listed"):
              listed = json.loads(machine.succeed("stolon-installer machines"))
              expected = [{"name": "alpha", "system": "${system}", "disk": "/dev/vdb", "here": True}]
              assert listed == expected, listed

              def partitions(arguments):
                  output = machine.succeed(f"stolon-installer partitions {arguments}")
                  return [found["partition"] for found in json.loads(output)]

              assert "/dev/vdc" in partitions(""), partitions("")
              skipped = partitions("--skip-disk /dev/vdc")
              assert "/dev/vdc" not in skipped, skipped

          with subtest("the binary caches of nix are checked"):
              machine.wait_for_open_port(8080)
              output = machine.succeed(
                  "NIX_CONFIG='extra-substituters = http://127.0.0.1:8080/ http://127.0.0.1:9' "
                  "stolon-installer caches"
              )
              caches = {found["cache"]: found["reachable"] for found in json.loads(output)}
              expected = {"http://127.0.0.1:8080": True, "http://127.0.0.1:9": False}
              assert caches == expected, caches

          with subtest("a hardware report is saved in the stolon folder"):
              machine.succeed("stolon-installer save-report alpha /dev/vdc")
              machine.succeed("mkdir -p /external && mount /dev/vdc /external")
              machine.succeed("jq -e 'type == \"object\"' /external/${selfLib.layout.names.hardwareReports}/alpha.json")
              machine.succeed("umount /external")

          with subtest("wrong input is refused before anything is erased"):
              machine.fail("stolon-installer install alpha")
              machine.fail("stolon-installer install beta --yes-wipe-disk")
              machine.fail("stolon-installer install alpha --yes-wipe-disk --restore /dev/missing")
              machine.fail("stolon-installer back-up alpha /dev/vdb")
              machine.fail("stolon-installer save-report Alpha /dev/vdc")

          with subtest("a backup saves what the machine keeps"):
              machine.succeed("${lib.getExe scripts.destroyFormatMount} --yes-wipe-all-disks")
              machine.succeed("echo kept > /mnt/persist/var/lib/data/file")
              machine.succeed("${lib.getExe scripts.unmount}")
              machine.succeed("printf 'secretsecret\\nbackuppw\\nbackuppw\\n' | stolon-installer back-up alpha /dev/vdc")

          with subtest("a migration backs up what the machine keeps from an old system"):
              machine.succeed("mkfs.ext4 /dev/vdd && mkdir -p /old && mount /dev/vdd /old")
              machine.succeed("mkdir -p /old/var/lib/data && echo migrated > /old/var/lib/data/file")
              machine.succeed(
                  "(stolon-installer migrate alpha /old /dev/vdb 2>&1 || true)"
                  " | grep -q 'is on the disk of the machine'"
              )
              machine.succeed("printf 'backuppw\\n' | stolon-installer migrate alpha /old /dev/vdc")
              machine.succeed("umount /old")

          with subtest("an install puts the migration back and installs the system"):
              machine.succeed("printf 'secretsecret\\nbackuppw\\n' | stolon-installer install alpha --yes-wipe-disk --restore /dev/vdc")
              machine.succeed("grep -qx migrated /mnt/persist/var/lib/data/file")
              machine.succeed("test -L /mnt/nix/var/nix/profiles/system")
        '';
      };
  };

  self.nixosTests.offline-installer = {
    flake = true;
    value =
      { hostPkgs, ... }:
      let
        system = hostPkgs.stdenv.hostPlatform.system;

        stolonPackages =
          (hostPkgs.extend selfLib.overlays.overlays.installer).${selfLib.overlays.namespace};

        alpha = selfLib.tests.installerMachine system;

        scripts = alpha.config.system.build;

        installer = stolonPackages.makeInstaller {
          nixosConfigurations = { inherit alpha; };
          repository = self;
          remoteFlakeRef = "github:example/machines";
        };
      in
      {
        globalTimeout = selfLib.tests.installerTimeout;

        nodes.machine =
          { pkgs, ... }:
          {
            imports = [ selfLib.installer.imageModule ];
            stolon.installer.package = installer.offlineInstallers.alpha;

            virtualisation = {
              memorySize = 4096;
              # The disk of the machine is /dev/vdb and the external drive is
              # /dev/vdc.
              emptyDiskImages = [
                6144
                1024
              ];
              # No network at all, and the store only has what the image
              # carries, like on a USB stick.
              vlans = [ ];
            };
            nix.settings.substituters = lib.mkForce [ ];

            # Virtual disks have no serial number, and the backup is named
            # after it.
            services.udev.extraRules = ''
              KERNEL=="vdb", ENV{ID_SERIAL_SHORT}="TARGET0001"
            '';

            boot.supportedFilesystems.btrfs = true;
            environment.systemPackages = [ pkgs.e2fsprogs ];
          };

        testScript = ''
          start_all()
          machine.wait_for_unit("multi-user.target")
          machine.succeed("echo -n secretsecret > ${passphraseFile}")
          machine.succeed("mkfs.ext4 /dev/vdc")

          with subtest("the menu says the installer needs no network"):
              machine.wait_until_tty_matches("1", "Offline installer")
              machine.wait_until_tty_matches("1", "What do you want to do")

          with subtest("an install puts the built system onto the disk"):
              machine.succeed("stolon-installer install alpha --yes-wipe-disk")
              installed = machine.succeed("readlink -f /mnt/nix/var/nix/profiles/system").strip()
              assert installed == "${scripts.toplevel}", installed

          with subtest("a backup and an install with the restore need no network"):
              machine.succeed("echo kept > /mnt/persist/var/lib/data/file")
              machine.succeed("${lib.getExe scripts.unmount}")
              machine.succeed("printf 'secretsecret\\nbackuppw\\nbackuppw\\n' | stolon-installer back-up alpha /dev/vdc")
              machine.succeed("printf 'secretsecret\\nbackuppw\\n' | stolon-installer install alpha --yes-wipe-disk --restore /dev/vdc")
              machine.succeed("grep -qx kept /mnt/persist/var/lib/data/file")
        '';
      };
  };
}
