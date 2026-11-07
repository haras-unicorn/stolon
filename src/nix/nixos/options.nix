{ inputs, ... }:

{
  self.nixosModules.options = {
    flake = true;
    value =
      { lib, ... }:
      let
        absolutePath = lib.types.strMatching "/([^/]+/)*[^/]+" // {
          description = "absolute path without a trailing slash";
        };

        paths = lib.types.listOf absolutePath;
      in
      {
        # The modules that declare the `disko` and `environment.persistence`
        # options the other modules set.
        imports = [
          inputs.disko.nixosModules.disko
          inputs.impermanence.nixosModules.impermanence
        ];

        options.stolon = {
          enable = lib.mkOption {
            type = lib.types.bool;
            default = false;
            description = ''
              Put the whole system on one disk. The disk is encrypted and
              compressed, the system starts from a clean slate on every boot
              and only keeps what is listed under `stolon.keep`, old Nix
              garbage is collected daily, and `stolon-backup` and
              `stolon-restore` are installed to move what is kept to another
              drive.

              The disk is set up with the `disko` scripts in
              `config.system.build`. Decide what to keep before that, because
              every kept directory gets its own place on the disk when it is
              set up.
            '';
          };

          device = lib.mkOption {
            type = lib.types.str;
            example = "/dev/disk/by-id/nvme-Samsung_SSD_980_PRO_1TB_S5GXNX0T000000";
            description = ''
              The disk to put the system on. Everything on it is erased when it
              is set up. Use a path from `/dev/disk/by-id`, because it does not
              change when disks are plugged in a different order.
            '';
          };

          bootSize = lib.mkOption {
            type = lib.types.str;
            default = "1G";
            description = ''
              How much room the boot partition gets. The default is plenty. A
              bigger one only helps if you keep many generations of kernels.
            '';
          };

          keep = {
            directories = lib.mkOption {
              type = paths;
              default = [ ];
              example = [
                "/home/alice/Documents"
                "/home/alice/.ssh"
                "/srv/photos"
              ];
              description = ''
                Folders to keep. Everything outside of the kept folders is
                thrown away on every boot, so list everything you would be sad
                to lose, such as your documents, your SSH keys and the data of
                your services. Folders in a home keep the owner of that home.

                The system's own folders (`/var/lib/nixos`, `/var/log`) are
                always kept, and so is `/etc/machine-id`.
              '';
            };

            files = lib.mkOption {
              type = paths;
              default = [ ];
              example = [ "/home/alice/.bash_history" ];
              description = ''
                Single files to keep. Use `stolon.keep.directories` for
                folders.
              '';
            };

            databases = lib.mkOption {
              type = paths;
              default = [ ];
              example = [
                "/var/lib/postgresql"
                "/var/lib/mysql"
              ];
              description = ''
                Folders of databases. They are kept like
                `stolon.keep.directories`, and are also set up so that they do
                not slow down as the many small writes of a database fragment
                them. The price is that the files in them are not compressed.
              '';
            };

            vms = lib.mkOption {
              type = paths;
              default = [ ];
              example = [ "/var/lib/libvirt/images" ];
              description = ''
                Folders of virtual machine disks. They are kept like
                `stolon.keep.directories`, and are also set up so that they do
                not slow down as the many small writes of a virtual machine
                fragment them. The price is that the files in them are not
                compressed.
              '';
            };
          };

          encryption = {
            enable = lib.mkOption {
              type = lib.types.bool;
              default = true;
              description = ''
                Encrypt the disk, so nobody can read it without the passphrase.
                Turn this off only if encryption makes your disk too slow.
              '';
            };

            passwordFile = lib.mkOption {
              type = lib.types.nullOr lib.types.str;
              default = null;
              example = "/run/password";
              description = ''
                A file with the passphrase to set the disk up with, so that
                setting it up does not stop to ask. It is not used to unlock the
                disk when the system starts. Leave it empty to be asked.

                The file holds the passphrase itself, so keep it out of git. Make
                it right before setting the disk up, in `/run`, which is gone
                after a reboot. This command asks for the passphrase without
                showing it or saving it in the shell history, and leaves out the
                newline that would otherwise become part of the passphrase:

                ```sh
                (umask 077; read -rsp 'Passphrase: ' p && printf '%s' "$p" > /run/password)
                ```
              '';
            };
          };

          compression = {
            enable = lib.mkOption {
              type = lib.types.bool;
              default = true;
              description = ''
                Make files take less room on the disk. It costs very little
                speed. Turn this off only if your disk or processor is slow.
              '';
            };

            level = lib.mkOption {
              type = lib.types.ints.between 1 15;
              default = 3;
              description = ''
                How hard to compress, from 1 to 15. A higher number saves more
                room and is slower.
              '';
            };
          };

          trim.enable = lib.mkOption {
            type = lib.types.bool;
            default = true;
            description = ''
              Tell the disk regularly which parts are free, so an SSD stays
              fast. Someone who gets hold of the disk can see which parts are
              free, but not what is in the rest. Turn this off on hard drives.
            '';
          };

          backup.maximumCompression = lib.mkOption {
            type = lib.types.bool;
            default = false;
            description = ''
              Make backups as small as possible. It takes longer. Backups are
              always compressed and encrypted, and this only decides how hard
              they are compressed.
            '';
          };

          gc = {
            enable = lib.mkOption {
              type = lib.types.bool;
              default = true;
              description = ''
                Free the room taken by old Nix generations and by projects you
                stopped working on, once a day.
              '';
            };

            retentionDays = lib.mkOption {
              type = lib.types.ints.positive;
              default = 14;
              description = ''
                How many days to keep old generations. The direnv environments
                of a project are also removed once its git history has not
                moved for this many days.
              '';
            };
          };
        };
      };
  };
}
