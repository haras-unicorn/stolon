{ lib, ... }:

# The drive layout, as pure functions. The modules and the boot tests all build
# on it, so the names that identify a layout and what is kept cannot drift
# apart.

let
  # These names are the contract between a formatted drive and the backup
  # tools, which use them to check that a drive has the expected layout. The
  # backup mount is part of it because restic stores absolute paths, and a
  # restore writes them back to the same place. Everything the tools put on an
  # external drive goes under one `stolon` folder.
  names = {
    disk = "main";
    espLabel = "stolon-esp";
    rootLabel = "stolon-root";
    luks = "stolon";
    root = "@root";
    nix = "@nix";
    persist = "@persist";
    persistMount = "/persist";
    backupMount = "/run/stolon";
    backupRepository = "stolon/backups";
    hardwareReports = "stolon/hardware";
  };

  essentials = {
    directories = [
      "/var/lib/nixos"
      "/var/log"
    ];
    files = [ "/etc/machine-id" ];
  };

  # What `stolon.keep` asks for, together with what the system needs.
  kept = keep: {
    directories = lib.unique (essentials.directories ++ keep.directories ++ keep.databases ++ keep.vms);
    files = lib.unique (essentials.files ++ keep.files);
    noCowDirectories = lib.unique (keep.databases ++ keep.vms);
  };

  volumeName =
    path: "${names.persist}-${lib.replaceStrings [ "/" ] [ "-" ] (lib.removePrefix "/" path)}";

  volumes =
    keep:
    let
      wanted = kept keep;
    in
    {
      ${names.persist} = {
        path = names.persistMount;
        noCow = false;
      };
    }
    // builtins.listToAttrs (
      builtins.map (
        path:
        lib.nameValuePair (volumeName path) {
          path = "${names.persistMount}${path}";
          noCow = builtins.elem path wanted.noCowDirectories;
        }
      ) wanted.directories
    );

  # Where a migration puts each kept path of an old system, from the top of
  # the btrfs filesystem: a kept directory becomes its own volume, and a kept
  # file goes into the persist volume, like on a Stolon disk.
  migration =
    keep:
    let
      wanted = kept keep;
    in
    builtins.map (path: {
      source = path;
      destination = volumeName path;
      type = "dir";
    }) wanted.directories
    ++ builtins.map (path: {
      source = path;
      destination = "${names.persist}${path}";
      type = "file";
    }) wanted.files;

  # Two kept directories can end up with the same volume name, for example
  # `/var/lib/a-b` and `/var/lib/a/b`.
  volumesCollide =
    keep:
    builtins.length (builtins.attrNames (volumes keep)) != builtins.length (kept keep).directories + 1;

  # The homes of the normal users, from the `users.users` of a system.
  homes =
    users:
    lib.mapAttrs (_: user: { inherit (user) home group homeMode; }) (
      lib.filterAttrs (_: user: user.isNormalUser) users
    );

  # The user whose home holds the path, if any, with that home.
  owner =
    homes: path:
    let
      holders = lib.mapAttrsToList (user: home: home // { inherit user; }) (
        lib.filterAttrs (_: home: path == home.home || lib.hasPrefix "${home.home}/" path) homes
      );
      deepestFirst = lib.sort (
        left: right: builtins.stringLength left.home > builtins.stringLength right.home
      ) holders;
    in
    if deepestFirst == [ ] then null else builtins.head deepestFirst;

  # What goes to impermanence, so that what is kept in a home belongs to its
  # owner.
  persistence =
    { wanted, homes }:
    {
      directories = builtins.map (
        path:
        let
          holder = owner homes path;
        in
        if holder == null then
          path
        else
          {
            directory = path;
            inherit (holder) user group;
          }
      ) wanted.directories;
      files = builtins.map (
        path:
        let
          holder = owner homes path;
        in
        if holder == null then
          path
        else
          {
            file = path;
            parentDirectory = { inherit (holder) user group; };
          }
      ) wanted.files;
    };

  # Impermanence creates what is kept as root, and mounts it before the homes
  # exist, so the kept paths in a home and the homes themselves are handed to
  # their owners afterwards.
  tmpfiles =
    { wanted, homes }:
    let
      ownedBy =
        type: paths:
        lib.concatMap (
          path:
          let
            holder = owner homes path;
          in
          lib.optional (
            holder != null
          ) "${type} ${names.persistMount}${path} - ${holder.user} ${holder.group} -"
        ) paths;

      holders = builtins.filter (holder: holder != null) (
        builtins.map (owner homes) (wanted.directories ++ wanted.files)
      );

      homeRules = builtins.map (
        holder: "d ${holder.home} 0${holder.homeMode} ${holder.user} ${holder.group} -"
      ) (lib.unique holders);
    in
    homeRules ++ ownedBy "d" wanted.directories ++ ownedBy "f" wanted.files;

  devices =
    {
      device,
      bootSize,
      compression,
      encryption,
      trim,
      volumes,
      chattr,
    }:
    let
      mountOptions = lib.optional compression.enable "compress=zstd:${toString compression.level}" ++ [
        "noatime"
      ];

      subvolume = mountpoint: { inherit mountpoint mountOptions; };

      noCowNames = builtins.attrNames (lib.filterAttrs (_: volume: volume.noCow) volumes);

      btrfsDevice =
        if encryption.enable then
          "/dev/mapper/${names.luks}"
        else
          "/dev/disk/by-partlabel/${names.rootLabel}";

      btrfs = {
        type = "btrfs";
        extraArgs = [ "--force" ];
        subvolumes = {
          "/${names.root}" = subvolume "/";
          "/${names.nix}" = subvolume "/nix";
        }
        // lib.mapAttrs' (name: volume: lib.nameValuePair "/${name}" (subvolume volume.path)) volumes;
        # Bash on purpose: disko pastes hooks into its own bash scripts. Runs
        # after the subvolumes are made, outside of disko's own mounts, so it
        # mounts the filesystem itself.
        postCreateHook = lib.optionalString (noCowNames != [ ]) ''
          (
            nocow_mount="$(mktemp -d)"
            mount "${btrfsDevice}" "$nocow_mount" -o subvol=/
            trap 'umount "$nocow_mount"; rm -rf "$nocow_mount"' EXIT
            ${lib.concatMapStringsSep "\n" (name: ''${chattr} +C "$nocow_mount/${name}"'') noCowNames}
          )
        '';
      };

      root =
        if encryption.enable then
          {
            type = "luks";
            name = names.luks;
            passwordFile = encryption.passwordFile;
            settings = {
              allowDiscards = trim.enable;
              bypassWorkqueues = true;
            };
            content = btrfs;
          }
        else
          btrfs;
    in
    {
      disk.${names.disk} = {
        type = "disk";
        inherit device;
        content = {
          type = "gpt";
          partitions = {
            esp = {
              label = names.espLabel;
              size = bootSize;
              type = "EF00";
              content = {
                type = "filesystem";
                format = "vfat";
                mountpoint = "/boot";
                mountOptions = [ "umask=0077" ];
              };
            };
            root = {
              label = names.rootLabel;
              size = "100%";
              content = root;
            };
          };
        };
      };
    };

  nothing = {
    directories = [ ];
    files = [ ];
    databases = [ ];
    vms = [ ];
  };

  exampleHomes.alice = {
    home = "/home/alice";
    group = "users";
    homeMode = "700";
  };
in
{
  self.lib.layout = {
    inherit
      names
      kept
      volumeName
      volumes
      migration
      volumesCollide
      homes
      owner
      persistence
      tmpfiles
      devices
      ;
  };

  self.unitTests.layout = {
    volume-name = {
      expr = volumeName "/var/lib/postgresql";
      expected = "@persist-var-lib-postgresql";
    };

    kept-always-has-what-the-system-needs = {
      expr = kept nothing;
      expected = {
        directories = [
          "/var/lib/nixos"
          "/var/log"
        ];
        files = [ "/etc/machine-id" ];
        noCowDirectories = [ ];
      };
    };

    kept-merges-databases-and-vms-into-directories = {
      expr = kept (
        nothing
        // {
          directories = [ "/srv" ];
          databases = [ "/var/lib/db" ];
          vms = [ "/var/lib/vm" ];
        }
      );
      expected = {
        directories = [
          "/var/lib/nixos"
          "/var/log"
          "/srv"
          "/var/lib/db"
          "/var/lib/vm"
        ];
        files = [ "/etc/machine-id" ];
        noCowDirectories = [
          "/var/lib/db"
          "/var/lib/vm"
        ];
      };
    };

    kept-has-no-duplicates = {
      expr =
        (kept (
          nothing
          // {
            directories = [ "/var/log" ];
            databases = [ "/var/log" ];
          }
        )).directories;
      expected = [
        "/var/lib/nixos"
        "/var/log"
      ];
    };

    volumes-have-a-base-and-one-per-directory = {
      expr = builtins.attrNames (volumes nothing);
      expected = [
        "@persist"
        "@persist-var-lib-nixos"
        "@persist-var-log"
      ];
    };

    volumes-mount-under-the-persist-mount = {
      expr = (volumes nothing)."@persist-var-log".path;
      expected = "/persist/var/log";
    };

    volumes-mark-databases-and-vms-as-no-cow = {
      expr =
        let
          result = volumes (
            nothing
            // {
              databases = [ "/var/lib/db" ];
              vms = [ "/var/lib/vm" ];
            }
          );
        in
        builtins.map (name: result.${name}.noCow) [
          "@persist-var-lib-db"
          "@persist-var-lib-vm"
          "@persist-var-log"
        ];
      expected = [
        true
        true
        false
      ];
    };

    migration-puts-directories-in-their-volumes-and-files-in-persist = {
      expr = migration nothing;
      expected = [
        {
          source = "/var/lib/nixos";
          destination = "@persist-var-lib-nixos";
          type = "dir";
        }
        {
          source = "/var/log";
          destination = "@persist-var-log";
          type = "dir";
        }
        {
          source = "/etc/machine-id";
          destination = "@persist/etc/machine-id";
          type = "file";
        }
      ];
    };

    migration-takes-databases-and-vms-like-directories = {
      expr = builtins.map (entry: entry.destination) (
        migration (
          nothing
          // {
            databases = [ "/var/lib/db" ];
            vms = [ "/var/lib/vm" ];
          }
        )
      );
      expected = [
        "@persist-var-lib-nixos"
        "@persist-var-log"
        "@persist-var-lib-db"
        "@persist-var-lib-vm"
        "@persist/etc/machine-id"
      ];
    };

    volumes-collide-when-two-directories-share-a-name = {
      expr = builtins.map volumesCollide [
        nothing
        (
          nothing
          // {
            directories = [
              "/var/lib/a-b"
              "/var/lib/a/b"
            ];
          }
        )
      ];
      expected = [
        false
        true
      ];
    };

    homes-are-the-homes-of-normal-users = {
      expr = homes {
        alice = {
          isNormalUser = true;
          home = "/home/alice";
          group = "users";
          homeMode = "700";
          shell = "ignored";
        };
        daemon = {
          isNormalUser = false;
          home = "/var/lib/daemon";
          group = "daemon";
          homeMode = "755";
        };
      };
      expected = exampleHomes;
    };

    owner-is-the-user-whose-home-holds-the-path = {
      expr = owner exampleHomes "/home/alice/Documents";
      expected = {
        user = "alice";
        group = "users";
        home = "/home/alice";
        homeMode = "700";
      };
    };

    owner-is-the-user-of-the-deepest-home = {
      expr =
        (owner (
          exampleHomes
          // {
            sub = {
              home = "/home/alice/sub";
              group = "sub";
              homeMode = "700";
            };
          }
        ) "/home/alice/sub/x").user;
      expected = "sub";
    };

    owner-is-nobody-outside-of-homes = {
      expr = owner exampleHomes "/home/alicia/Documents";
      expected = null;
    };

    persistence-gives-homes-to-their-owners = {
      expr = persistence {
        wanted = {
          directories = [
            "/var/log"
            "/home/alice/.ssh"
          ];
          files = [ "/home/alice/.history" ];
        };
        homes = exampleHomes;
      };
      expected = {
        directories = [
          "/var/log"
          {
            directory = "/home/alice/.ssh";
            user = "alice";
            group = "users";
          }
        ];
        files = [
          {
            file = "/home/alice/.history";
            parentDirectory = {
              user = "alice";
              group = "users";
            };
          }
        ];
      };
    };

    tmpfiles-hand-homes-and-what-is-kept-in-them-to-their-owners = {
      expr = tmpfiles {
        wanted = {
          directories = [
            "/var/log"
            "/home/alice/.ssh"
            "/home/alice/Documents"
          ];
          files = [ "/home/alice/.history" ];
        };
        homes = exampleHomes;
      };
      expected = [
        "d /home/alice 0700 alice users -"
        "d /persist/home/alice/.ssh - alice users -"
        "d /persist/home/alice/Documents - alice users -"
        "f /persist/home/alice/.history - alice users -"
      ];
    };

    tmpfiles-leave-the-rest-alone = {
      expr = tmpfiles {
        wanted = {
          directories = [ "/var/log" ];
          files = [ "/etc/machine-id" ];
        };
        homes = exampleHomes;
      };
      expected = [ ];
    };
  };
}
