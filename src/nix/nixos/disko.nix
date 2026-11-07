{ selfLib, ... }:

{
  self.nixosModules.disko = {
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
      in
      lib.mkIf cfg.enable {
        disko.devices = selfLib.layout.devices {
          inherit (cfg)
            device
            bootSize
            compression
            encryption
            trim
            ;
          volumes = selfLib.layout.volumes cfg.keep;
          chattr = lib.getExe' pkgs.e2fsprogs "chattr";
        };
      };
  };
}
