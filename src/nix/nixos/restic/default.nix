{ inputs, selfLib, ... }:

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

        # NixOS tests do not allow overlays on their machines, so haraspkgs is
        # applied to the package set here and not through `nixpkgs.overlays`.
        harasPackages = (pkgs.extend inputs.haraspkgs.overlays.default).harasPackages;

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
          migration = builtins.toJSON (layout.migration cfg.keep);
        };

        mkProgram =
          { program, direction }:
          harasPackages.writeNushellApplication {
            name = program;
            runtimeInputs = [
              pkgs.coreutils
              pkgs.cryptsetup
              pkgs.restic
              pkgs.util-linux
            ];
            text = harasPackages.renderMustacheText {
              name = program;
              text = builtins.readFile ./transfer.nu;
              vars = vars // {
                inherit program direction;
              };
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

        migrate = mkProgram {
          program = "stolon-migrate";
          direction = "migrate";
        };
      in
      {
        config = lib.mkIf cfg.enable {
          system.build.stolonBackup = backup;
          system.build.stolonRestore = restore;
          system.build.stolonMigrate = migrate;

          environment.systemPackages = [
            backup
            restore
            migrate
          ];
        };
      };
  };
}
