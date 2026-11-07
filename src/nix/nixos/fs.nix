{ selfLib, ... }:

{
  self.nixosModules.fs = {
    flake = true;
    value =
      { config, lib, ... }:
      let
        cfg = config.stolon;

        volumes = selfLib.layout.volumes cfg.keep;

        neededForBootMounts = [
          "/nix"
        ]
        ++ lib.mapAttrsToList (_: volume: volume.path) volumes;
      in
      lib.mkIf cfg.enable {
        fileSystems = lib.mkIf config.disko.enableConfig (
          lib.genAttrs neededForBootMounts (_: {
            neededForBoot = true;
          })
        );
      };
  };
}
