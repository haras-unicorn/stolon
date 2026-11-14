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

        migrate = lib.getExe scripts.stolonMigrate;

        formatAndMount = lib.getExe scripts.destroyFormatMount;
      in
      {
        globalTimeout = selfLib.tests.globalTimeout;

        nodes.machine =
          { pkgs, ... }:
          {
            # The target drive is /dev/vdb, the backup partition is /dev/vdc
            # and the old system to migrate is /dev/vdd.
            virtualisation.emptyDiskImages = [
              2048
              1024
              512
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
                  "RESTIC_PASSWORD=backuppw restic --repo /mnt/repo/${selfLib.layout.names.backupRepository} snapshots --json"
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

          with subtest("a migration is refused unless the old system is mounted"):
              machine.succeed("mkdir -p /old")
              machine.succeed(
                  "(printf 'backuppw\\n' | ${migrate} /old /dev/vdc 2>&1 || true)"
                  " | grep -q 'nothing is mounted'"
              )

          with subtest("a migration follows the links of an old system inside it"):
              machine.succeed("mkfs.ext4 /dev/vdd && mount /dev/vdd /old")
              machine.succeed("mkdir -p /old/srv/data /old/var/lib /old/private/etc /old/logs")
              machine.succeed("echo migrated > /old/srv/data/file")
              machine.succeed("chown 1000:100 /old/srv/data/file")
              machine.succeed("ln -s /srv/data /old/var/lib/data")
              # Where the link points on this machine, which must not be what
              # is backed up.
              machine.succeed("mkdir -p /srv/data && echo live > /srv/data/file")
              machine.succeed("ln -s /private/etc /old/etc")
              machine.succeed("echo 0123456789abcdef0123456789abcdef > /old/private/etc/machine-id")
              machine.succeed("echo log > /old/logs/entry")
              machine.succeed("ln -s ../../../../logs /old/var/log")
              machine.succeed("ln -s /var/lib/nixos /old/var/lib/nixos")
              output = machine.succeed("printf 'backuppw\\n' | ${migrate} /old /dev/vdc 2>&1")
              assert "has no /var/lib/db" in output, output
              assert "has no /var/lib/nixos" in output, output
              assert "has no /var/lib/data" not in output, output
              assert "has no /var/log" not in output, output
              assert "has no /etc/machine-id" not in output, output
              machine.fail("mountpoint -q ${selfLib.layout.names.backupMount}/target")
              machine.succeed("umount /old")

          with subtest("the migration is named after the configuration and date"):
              machine.succeed("mkdir -p /repo && mount /dev/vdc /repo")
              machine.succeed(
                  "RESTIC_PASSWORD=backuppw restic --repo /repo/${selfLib.layout.names.backupRepository} snapshots --json"
                  " | jq -e 'max_by(.time) | .hostname == \"alpha\""
                  " and (.tags[0] | test(\"^migrated-alpha-[0-9]{4}-[0-9]{2}-[0-9]{2}$\"))'"
              )
              machine.succeed("umount /repo")

          with subtest("a restore puts the migration onto a new disk"):
              machine.succeed("${lib.getExe scripts.unmount}")
              machine.succeed("${formatAndMount} --yes-wipe-all-disks")
              machine.succeed("${lib.getExe scripts.unmount}")
              machine.succeed("printf 'secretsecret\\nbackuppw\\n' | ${restore} /dev/vdb /dev/vdc")
              machine.succeed("${lib.getExe scripts.mount}")
              machine.succeed("grep -qx migrated /mnt/persist/var/lib/data/file")
              machine.succeed("stat -c %u:%g /mnt/persist/var/lib/data/file | grep -qx 1000:100")
              machine.succeed("grep -qx 0123456789abcdef0123456789abcdef /mnt/persist/etc/machine-id")
              machine.succeed("grep -qx log /mnt/persist/var/log/entry")
              machine.fail("test -e /mnt/persist/var/lib/db/file")
        '';
      };
  };
}
