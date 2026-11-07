{ inputs, selfLib, ... }:

{
  self.nixosTests.backup-restore = {
    flake = true;
    value =
      { hostPkgs, lib, ... }:
      let
        passphraseFile = "/tmp/secret.key";

        stolon = inputs.nixpkgs.lib.nixosSystem {
          modules = [
            selfLib.nixosModules.default
            {
              nixpkgs.hostPlatform = hostPkgs.stdenv.hostPlatform.system;
              system.stateVersion = "26.05";
              networking.hostName = "alpha";

              stolon = {
                enable = true;
                device = "/dev/vdb";
                encryption.passwordFile = passphraseFile;
                keep.directories = [ "/var/lib/data" ];
                keep.databases = [ "/var/lib/db" ];
              };
            }
          ];
        };

        scripts = stolon.config.system.build;

        backup = lib.getExe scripts.stolonBackup;

        restore = lib.getExe scripts.stolonRestore;

        formatAndMount = lib.getExe scripts.destroyFormatMount;
      in
      {
        globalTimeout = selfLib.tests.globalTimeout;

        nodes.machine =
          { pkgs, ... }:
          {
            # The target drive is /dev/vdb and the backup partition is /dev/vdc.
            virtualisation.emptyDiskImages = [
              2048
              1024
            ];
            # Virtual disks have no serial number, and the backup is named after it.
            services.udev.extraRules = ''
              KERNEL=="vdb", ENV{ID_SERIAL_SHORT}="TARGET0001"
            '';
            boot.supportedFilesystems.btrfs = true;
            environment.systemPackages = [
              pkgs.e2fsprogs
              pkgs.jq
              pkgs.restic
            ];
          };

        testScript = ''
          start_all()
          machine.wait_for_unit("multi-user.target")
          machine.succeed("echo -n secretsecret > ${passphraseFile}")
          machine.succeed("mkfs.ext4 /dev/vdc")

          with subtest("a drive without the layout is refused"):
              machine.fail("${backup} /dev/vdc /dev/vdc")
              machine.fail("${restore} /dev/vdc /dev/vdc")

          with subtest("a drive that is in use is refused"):
              machine.succeed("${formatAndMount} --yes-wipe-all-disks")
              machine.succeed(
                  "(printf 'secretsecret\\nbackuppw\\n' | ${restore} /dev/vdb /dev/vdc 2>&1 || true)"
                  " | grep -q 'is in use'"
              )

          with subtest("a backup saves what is kept"):
              machine.succeed("echo kept > /mnt/persist/var/lib/data/file")
              machine.succeed("echo kept > /mnt/persist/var/lib/db/file")
              machine.succeed("echo lost > /mnt/file")
              machine.succeed("${lib.getExe scripts.unmount}")
              machine.succeed("printf 'secretsecret\\nbackuppw\\nbackuppw\\n' | ${backup} /dev/vdb /dev/vdc")

          with subtest("the backup is named after the drive, configuration and date"):
              machine.succeed("mkdir -p /mnt/repo && mount /dev/vdc /mnt/repo")
              machine.succeed(
                  "RESTIC_PASSWORD=backuppw restic --repo /mnt/repo/stolon snapshots --json"
                  " | jq -e '.[0] | .hostname == \"alpha\""
                  " and (.tags[0] | test(\"^TARGET0001-alpha-[0-9]{4}-[0-9]{2}-[0-9]{2}$\"))'"
              )
              machine.succeed("umount /mnt/repo")

          with subtest("a restore brings back what was kept"):
              machine.succeed("${formatAndMount} --yes-wipe-all-disks")
              machine.fail("test -e /mnt/persist/var/lib/data/file")
              machine.succeed("${lib.getExe scripts.unmount}")
              machine.succeed("printf 'secretsecret\\nbackuppw\\n' | ${restore} /dev/vdb /dev/vdc")
              machine.succeed("${lib.getExe scripts.mount}")
              machine.succeed("grep -qx kept /mnt/persist/var/lib/data/file")
              machine.succeed("grep -qx kept /mnt/persist/var/lib/db/file")
              machine.fail("test -e /mnt/file")
              machine.succeed("lsattr -d /mnt/persist/var/lib/db | cut -d' ' -f1 | grep -q C")
        '';
      };
  };
}
