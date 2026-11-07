{ inputs, selfLib, ... }:

{
  # Bypasses `self.nixosTests`: the disko test library builds a whole test
  # derivation that installs and boots the system, and `self.nixosTests` only
  # takes a test module. Only x86_64: disko's own boot tests hang on aarch64.
  perSystem =
    { pkgs, system, ... }:
    let
      lib = pkgs.lib;

      layout = selfLib.layout;

      chattr = lib.getExe' pkgs.e2fsprogs "chattr";

      # The disko test library puts the passphrase here in the test machine.
      passphraseFile = "/tmp/secret.key";

      keep = {
        directories = [ "/home/alice/Documents" ];
        files = [ "/home/alice/.notes" ];
        databases = [ "/var/lib/db" ];
        vms = [ ];
      };

      volumes = layout.volumes keep;

      mkTest =
        {
          name,
          disk,
          extraTestScript,
        }:
        (inputs.disko.lib.testLib.makeDiskoTest {
          inherit pkgs name;
          disko-config.disko.devices = layout.devices (
            disk
            // {
              inherit volumes chattr;
            }
          );
          extraSystemConfig = {
            imports = [ selfLib.nixosModules.default ];

            stolon = disk // {
              enable = true;
              inherit keep;
            };

            users.users.alice.isNormalUser = true;

            # The disko test library enables systemd-boot, and stolon uses grub.
            boot.loader.systemd-boot.enable = lib.mkForce false;

            boot.initrd.luks.devices = lib.optionalAttrs disk.encryption.enable {
              ${layout.names.luks}.keyFile = passphraseFile;
            };

            environment.systemPackages = [
              pkgs.cryptsetup
              pkgs.e2fsprogs
            ];
          };
          extraTestScript = ''
            machine.succeed("findmnt --noheadings --output FSTYPE / | grep -qx btrfs")
            machine.succeed("btrfs subvolume list / | grep -q 'path ${layout.names.persist}$'")
            machine.succeed("btrfs subvolume list / | grep -q 'path ${layout.names.nix}$'")
            ${builtins.concatStringsSep "\n" (
              builtins.map (volume: ''machine.succeed("btrfs subvolume list / | grep -q 'path ${volume}$'")'') (
                builtins.attrNames volumes
              )
            )}

            machine_id = machine.succeed("cat /etc/machine-id").strip()
            machine.succeed("touch /ephemeral /var/lib/db/kept /var/log/kept")
            machine.succeed("su alice -c 'touch /home/alice/Documents/kept; echo kept > /home/alice/.notes'")
            machine.succeed("lsattr -d /var/lib/db | cut -d' ' -f1 | grep -q C")
            machine.fail("lsattr -d /var/log | cut -d' ' -f1 | grep -q C")

            machine.shutdown()
            machine.start()
            machine.wait_for_unit("multi-user.target")

            machine.fail("test -e /ephemeral")
            machine.succeed("test -e /var/lib/db/kept")
            machine.succeed("test -e /var/log/kept")
            assert machine.succeed("cat /etc/machine-id").strip() == machine_id
            machine.succeed("test -e /home/alice/Documents/kept")
            machine.succeed("grep -qx kept /home/alice/.notes")
            owners = machine.succeed("stat -c '%n %U' /home/alice /home/alice/Documents /home/alice/.notes")
            assert owners.split() == ["/home/alice", "alice", "/home/alice/Documents", "alice", "/home/alice/.notes", "alice"], owners

            ${extraTestScript}
          '';
        }).extend
          {
            # The disko test library does not take a timeout.
            modules = [ { globalTimeout = selfLib.tests.globalTimeout; } ];
          };
    in
    {
      checks = lib.optionalAttrs (system == "x86_64-linux") {
        boot-encrypted = mkTest {
          name = "stolon-encrypted";
          disk = {
            device = "/dev/vdb";
            bootSize = "1G";
            compression = {
              enable = true;
              level = 3;
            };
            encryption = {
              enable = true;
              passwordFile = passphraseFile;
            };
            trim.enable = true;
          };
          extraTestScript = ''
            machine.succeed("lsblk --noheadings --output FSTYPE /dev/vda | grep -qx crypto_LUKS")
            machine.succeed("cryptsetup status ${layout.names.luks} | grep -q discards")
            machine.succeed("cryptsetup status ${layout.names.luks} | grep -q no_read_workqueue")
            machine.succeed("findmnt --noheadings --output OPTIONS / | grep -q compress=zstd:3")
            machine.succeed("systemctl is-enabled fstrim.timer")
          '';
        };

        boot-plain = mkTest {
          name = "stolon-plain";
          disk = {
            device = "/dev/vdb";
            bootSize = "1G";
            compression = {
              enable = false;
              level = 3;
            };
            encryption = {
              enable = false;
              passwordFile = null;
            };
            trim.enable = false;
          };
          extraTestScript = ''
            machine.fail("lsblk --noheadings --output FSTYPE /dev/vda | grep -qx crypto_LUKS")
            machine.fail("findmnt --noheadings --output OPTIONS / | grep -q compress")
            machine.fail("systemctl is-enabled fstrim.timer")
          '';
        };
      };
    };
}
