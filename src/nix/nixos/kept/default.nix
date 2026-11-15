{ inputs, selfLib, ... }:

{
  self.nixosModules.kept = {
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

        harasPackages = (pkgs.extend inputs.haraspkgs.overlays.default).harasPackages;

        # Under `/etc`, so the check reads it from the running system and from
        # the one it switches to.
        record = "stolon/system.json";

        vars = {
          inherit record;
          persistMount = layout.names.persistMount;
          persist = layout.names.persist;
          rootSubvolume = layout.names.root;
          nixSubvolume = layout.names.nix;
          rootLabel = layout.names.rootLabel;
          # A system without Stolon may not have a root device, and its check
          # never mounts one.
          rootDevice = if cfg.enable then config.fileSystems."/".device else "";
        };

        common = pkgs.writeTextDir "common.nu" (
          harasPackages.renderMustacheText {
            inherit vars;
            name = "stolon-kept-common";
            text = builtins.readFile ./common.nu;
          }
        );

        # The programs use common.nu as a module. Nushell looks for it next to
        # the program first, where an editor finds it, and then in the folders
        # the program names, where the built program finds it.
        mkProgram =
          {
            name,
            file,
            runtimeInputs,
          }:
          harasPackages.writeNushellApplication {
            inherit name runtimeInputs;
            text = harasPackages.renderMustacheText {
              inherit name;
              vars.lib = "${common}";
              text = builtins.readFile file;
            };
          };

        checkSwitch = mkProgram {
          name = "stolon-check-switch";
          file = ./check-switch.nu;
          runtimeInputs = [
            pkgs.coreutils
            pkgs.e2fsprogs
            pkgs.util-linux
          ];
        };

        stale = mkProgram {
          name = "stolon-stale";
          file = ./stale.nu;
          runtimeInputs = [
            pkgs.btrfs-progs
            pkgs.coreutils
            pkgs.gum
            pkgs.util-linux
          ];
        };
      in
      {
        config = lib.mkMerge [
          {
            # Also without Stolon, so that turning it off is refused.
            system.preSwitchChecks.stolon = ''${lib.getExe checkSwitch} "$1" "$2"'';
            system.build.stolonCheckSwitch = checkSwitch;
          }
          (lib.mkIf cfg.enable {
            environment.etc.${record}.text = builtins.toJSON (
              layout.record {
                inherit (cfg) keep device bootSize;
                encryption = cfg.encryption.enable;
              }
            );

            environment.systemPackages = [ stale ];
            system.build.stolonStale = stale;
          })
        ];
      };
  };
}
