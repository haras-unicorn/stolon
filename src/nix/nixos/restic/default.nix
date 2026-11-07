{ selfLib, ... }:

{
  self.nixosModules.restic = {
    flake = true;
    value =
      {
        config,
        lib,
        pkgs,
        ...
      }:
      let
        cfg = config.stolon;

        layout = selfLib.layout;

        partitions = config.disko.devices.disk.${layout.names.disk}.content.partitions;

        vars = {
          hostName = config.networking.hostName;
          compression = if cfg.backup.maximumCompression then "max" else "auto";
          encrypted = builtins.toJSON cfg.encryption.enable;
          mapper = "${layout.names.luks}-transfer";
          targetMount = "${layout.names.backupMount}/target";
          repositoryMount = "${layout.names.backupMount}/backup";
          repositoryName = layout.names.backupRepository;
          rootLabel = partitions.root.label;
          expectedPartitions = builtins.toJSON [
            "${partitions.esp.label}:vfat"
            "${partitions.root.label}:${if cfg.encryption.enable then "crypto_LUKS" else "btrfs"}"
          ];
          volumes = builtins.toJSON (builtins.attrNames (layout.volumes cfg.keep));
        };

        mkProgram =
          { program, direction }:
          selfLib.nushell.writeApplication pkgs {
            name = program;
            runtimeInputs = [
              pkgs.coreutils
              pkgs.cryptsetup
              pkgs.restic
              pkgs.util-linux
            ];
            template = ./transfer.nu;
            vars = vars // {
              inherit program direction;
            };
          };

        backup = mkProgram {
          program = "stolon-backup";
          direction = "backup";
        };

        restore = mkProgram {
          program = "stolon-restore";
          direction = "restore";
        };
      in
      {
        config = lib.mkIf cfg.enable {
          system.build.stolonBackup = backup;
          system.build.stolonRestore = restore;

          environment.systemPackages = [
            backup
            restore
          ];
        };
      };
  };
}
