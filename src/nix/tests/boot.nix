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

      plainDisk = {
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

      # Kept on top of `keep` by the `more` specialisation of the test that
      # changes what is kept: a folder inside a kept one, a folder that is
      # only on the root so far, and new database and virtual machine folders.
      moreKeep = {
        directories = [
          "/home/alice/Documents/sub"
          "/srv/new"
        ];
        files = [ ];
        databases = [ "/var/lib/db2" ];
        vms = [ "/var/lib/vms" ];
      };

      # The disko test library forces the devices of the system it installs,
      # so a specialisation that keeps more forces its own above that, the way
      # the library prepares them for the booted machine.
      devicesKeeping =
        changedKeep:
        (inputs.disko.lib.testLib.prepareDiskoConfig {
          disko.devices = layout.devices (
            plainDisk
            // {
              volumes = layout.volumes changedKeep;
              inherit chattr;
            }
          );
        } inputs.disko.lib.testLib.devices).disko.devices;

      mkTest =
        {
          name,
          disk,
          extraTestScript,
          extraSystemConfig ? { },
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
            imports = [
              selfLib.nixosModules.default
              extraSystemConfig
            ];

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
          disk = plainDisk;
          extraTestScript = ''
            machine.fail("lsblk --noheadings --output FSTYPE /dev/vda | grep -qx crypto_LUKS")
            machine.fail("findmnt --noheadings --output OPTIONS / | grep -q compress")
            machine.fail("systemctl is-enabled fstrim.timer")
          '';
        };

        boot-changed-keep = mkTest {
          name = "stolon-changed-keep";
          disk = plainDisk;
          extraSystemConfig =
            { config, ... }:
            {
              # The refusals that need no boot run the check against made-up
              # systems.
              environment.systemPackages = [ config.system.build.stolonCheckSwitch ];

              specialisation.more.configuration = {
                stolon.keep = moreKeep;
                disko.devices = lib.mkOverride 40 (devicesKeeping {
                  directories = keep.directories ++ moreKeep.directories;
                  files = keep.files;
                  databases = keep.databases ++ moreKeep.databases;
                  vms = keep.vms ++ moreKeep.vms;
                });
              };
            };
          extraTestScript = ''
            # The script of the disko test library already imports shlex, and
            # the linter refuses a second import.
            import json

            more = "/run/current-system/specialisation/more/bin/switch-to-configuration"
            base = "/nix/var/nix/profiles/system/bin/switch-to-configuration"
            running = json.loads(machine.succeed("cat /etc/stolon/system.json"))

            def restart():
                machine.shutdown()
                machine.start()
                machine.wait_for_unit("multi-user.target")

            def top_of_filesystem(command):
                machine.succeed("mkdir -p /top && mount -o subvol=/ /dev/disk/by-partlabel/${layout.names.rootLabel} /top")
                try:
                    return machine.succeed(command)
                finally:
                    machine.succeed("umount /top")

            def check(record, specialisations={}):
                machine.succeed("rm -rf /fake && mkdir -p /fake/etc/stolon")
                systems = {"/fake": record} | {
                    f"/fake/specialisation/{name}": other for name, other in specialisations.items()
                }
                for path, kept in systems.items():
                    if kept is not None:
                        machine.succeed(f"mkdir -p {path}/etc/stolon")
                        machine.succeed(f"echo {shlex.quote(json.dumps(kept))} > {path}/etc/stolon/system.json")
                return machine.execute("stolon-check-switch /fake boot 2>&1")

            def allowed(record, expected=""):
                status, output = check(record)
                assert status == 0 and expected in output, output

            def refused(record, expected, specialisations={}):
                status, output = check(record, specialisations)
                assert status != 0 and expected in output, output

            # The running system with more kept, the way a configuration
            # would record it.
            def keeping(directories=[], files=[], no_cow=[], without=[]):
                kept = json.loads(json.dumps(running))
                for key in ["directories", "files", "noCowDirectories"]:
                    kept[key] = [path for path in kept[key] if path not in without]
                kept["volumes"] = [volume for volume in kept["volumes"] if volume["path"] not in without]
                kept["directories"] += directories + no_cow
                kept["files"] += files
                kept["noCowDirectories"] += no_cow
                kept["volumes"] += [
                    {"path": path, "name": "${layout.names.persist}-" + path[1:].replace("/", "-")}
                    for path in directories + no_cow
                ]
                return kept

            def stale():
                return [entry["name"] for entry in json.loads(machine.succeed("stolon-stale list"))]

            with subtest("a live switch that changes what is kept is refused"):
                for action in ["switch", "test"]:
                    output = machine.fail(f"{more} {action} 2>&1")
                    assert "nixos-rebuild boot" in output, output
                machine.fail("findmnt /persist/srv/new")

            with subtest("what would stop the machine from starting is refused"):
                refused(None, "turns Stolon off")
                refused(running | {"encryption": True}, "turns encryption on")
                refused(running | {"device": "/dev/disk/by-id/elsewhere"}, "not the disk this system runs from")
                allowed(running | {"device": "/dev/vda"})
                allowed(running | {"bootSize": "2G"}, "changes at the next install")
                notes_folder = keeping(directories=["/home/alice/.notes"], without=["/home/alice/.notes"])
                refused(running, "/home/alice/.notes is kept as a file", {"other": notes_folder})

            with subtest("what would copy, delete or bring back data at boot is refused"):
                refused(notes_folder, "/home/alice/.notes changes from a kept file")
                documents_vm = keeping(no_cow=["/home/alice/Documents"], without=["/home/alice/Documents"])
                refused(documents_vm, "/home/alice/Documents changes from a kept normal folder")

                machine.succeed("mkdir -p /srv/full && touch /srv/full/data")
                refused(keeping(no_cow=["/srv/full"]), "the boot would have to copy all of it")
                machine.succeed("rm -rf /srv/full")
                allowed(keeping(no_cow=["/srv/full"]))

                machine.succeed("touch /srv/file")
                refused(keeping(directories=["/srv/file"]), "/srv/file is not a folder")

                machine.succeed("mkdir -p /srv/mix /persist/srv/mix && touch /srv/mix/now /persist/srv/mix/before")
                refused(keeping(directories=["/srv/mix"]), "/persist/srv/mix still holds an old copy")
                machine.succeed("rm -rf /srv/mix")
                allowed(keeping(directories=["/srv/mix"]), "comes back with what is in /persist/srv/mix")
                machine.succeed("rm -rf /persist/srv/mix")

                moved_down = keeping(directories=["/home/alice/Documents/inner"], without=["/home/alice/Documents"])
                refused(moved_down, "Keep /home/alice/Documents/inner first")

            with subtest("newly kept folders get their volumes at the next boot"):
                machine.succeed("mkdir -p /home/alice/Documents/sub /srv/new")
                machine.succeed("echo nested > /home/alice/Documents/sub/kept")
                machine.succeed("echo root > /srv/new/kept")
                output = machine.succeed(f"{more} boot 2>&1")
                assert "newly kept: /srv/new" in output, output
                restart()

                for volume in ["@persist-home-alice-Documents-sub", "@persist-srv-new", "@persist-var-lib-db2", "@persist-var-lib-vms"]:
                    machine.succeed(f"btrfs subvolume list / | grep -q 'path {volume}$'")
                machine.succeed("findmnt /persist/home/alice/Documents/sub")
                machine.succeed("grep -qx nested /home/alice/Documents/sub/kept")
                machine.succeed("grep -qx root /srv/new/kept")
                for folder in ["/var/lib/db2", "/var/lib/vms"]:
                    machine.succeed(f"lsattr -d {folder} | cut -d' ' -f1 | grep -q C")
                machine.fail("lsattr -d /home/alice/Documents | cut -d' ' -f1 | grep -q C")
                machine.succeed("test -e /home/alice/Documents/kept")
                machine.succeed("test -e /var/lib/db/kept")
                machine.succeed("grep -qx kept /home/alice/.notes")
                assert "${layout.names.staging}" not in top_of_filesystem("ls -A /top")
                assert "nested" in top_of_filesystem("cat /top/@persist-home-alice-Documents/sub/kept")

            with subtest("a folder that would leave a hole where it was kept is refused"):
                output = machine.fail(f"{base} boot 2>&1")
                assert "/home/alice/Documents/sub is no longer kept on its own" in output, output
                old_copy = "@persist-home-alice-Documents/sub"
                assert old_copy in stale(), stale()
                machine.fail(f"stolon-stale delete {old_copy}")
                machine.succeed(f"stolon-stale delete {old_copy} --yes-lose-data")
                assert old_copy not in stale(), stale()
                machine.succeed("rm /home/alice/Documents/sub/kept")

            with subtest("folders that are no longer kept keep their volumes"):
                output = machine.fail(f"{base} switch 2>&1")
                assert "no longer kept: /srv/new" in output, output
                machine.succeed(f"{base} boot")
                restart()

                machine.fail("grep -q /srv/new /etc/stolon/system.json")
                machine.fail("findmnt /persist/srv/new")
                machine.succeed("btrfs subvolume list / | grep -q 'path @persist-srv-new$'")
                machine.succeed("test -e /home/alice/Documents/kept")
                assert "root" in top_of_filesystem("cat /top/@persist-srv-new/kept")

            with subtest("an old volume never comes back over what is there now"):
                machine.succeed("mkdir -p /srv/new && touch /srv/new/now")
                refused(keeping(directories=["/srv/new"]), "its old subvolume @persist-srv-new")
                machine.succeed("rm -rf /srv/new")
                allowed(keeping(directories=["/srv/new"]), "comes back with its old subvolume")

            with subtest("stale volumes are deleted only on request"):
                assert "@persist-srv-new" in stale(), stale()
                machine.succeed("stolon-stale delete @persist-srv-new --yes-lose-data")
                machine.fail("btrfs subvolume list / | grep -q 'path @persist-srv-new$'")
          '';
        };
      };
    };
}
